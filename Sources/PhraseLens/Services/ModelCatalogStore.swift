import Combine
import Foundation

struct ModelCatalogSnapshot: Codable, Equatable, Sendable {
  var models: [String]
  var fetchedAt: Date
}

/// Remembers each provider's model catalog.
///
/// The list used to live in the settings pane's own state, so it was thrown
/// away every time the pane was left and had to be fetched again by hand before
/// a model could be picked. It belongs to the app instead: fetched once,
/// written to disk, refreshed in the background when it goes stale, and kept
/// when a refresh fails — a network blip is not a reason to make the user
/// retype a model id.
@MainActor
final class ModelCatalogStore: ObservableObject {
  /// Providers publish new models often enough that a day-old list is worth
  /// replacing, and rarely enough that doing it per app launch is waste.
  static let staleAfter: TimeInterval = 60 * 60 * 24
  private static let storageKey = "model-catalog-v1"
  private static let maximumCatalogs = 24

  @Published private(set) var snapshots: [String: ModelCatalogSnapshot] = [:]
  @Published private(set) var fetching: Set<String> = []
  @Published private(set) var errors: [String: String] = [:]

  private let defaults: UserDefaults
  private var tasks: [String: Task<Void, Never>] = [:]
  /// Identifies the fetch that currently owns a key, so a cancelled fetch
  /// cannot tear down the state of the one that replaced it.
  private var generations: [String: UUID] = [:]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.storageKey),
      let decoded = try? JSONDecoder.catalog.decode(
        [String: ModelCatalogSnapshot].self,
        from: data
      )
    {
      snapshots = decoded
    }
  }

  /// One catalog per thing that can serve a different list: the provider, the
  /// authentication mode (a ChatGPT subscription and a platform key see
  /// different models), and the endpoint (every OpenAI-compatible gateway is
  /// its own catalog).
  nonisolated static func key(for configuration: ProviderConfiguration) -> String {
    if configuration.provider.supportsOAuth && configuration.authMode == .oauthCodex {
      return "\(configuration.provider.rawValue)|oauth"
    }
    let endpoint = configuration.endpoint
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return "\(configuration.provider.rawValue)|\(endpoint)"
  }

  func snapshot(for configuration: ProviderConfiguration) -> ModelCatalogSnapshot? {
    snapshots[Self.key(for: configuration)]
  }

  func models(for configuration: ProviderConfiguration) -> [String] {
    snapshot(for: configuration)?.models ?? []
  }

  func isFetching(_ configuration: ProviderConfiguration) -> Bool {
    fetching.contains(Self.key(for: configuration))
  }

  func error(for configuration: ProviderConfiguration) -> String? {
    errors[Self.key(for: configuration)]
  }

  func isStale(_ configuration: ProviderConfiguration) -> Bool {
    guard let snapshot = snapshot(for: configuration) else { return true }
    return Date().timeIntervalSince(snapshot.fetchedAt) > Self.staleAfter
  }

  /// Fetches only what is missing or old. The settings pane calls this on
  /// appearance, so it must stay silent: no spinner-blocking, no error banner
  /// for a refresh the user did not ask for.
  func refreshIfStale(
    configuration: ProviderConfiguration,
    proxy: ProxySettings,
    token: @escaping @Sendable () async throws -> String
  ) {
    guard isStale(configuration) else { return }
    fetch(configuration: configuration, proxy: proxy, reportsErrors: false, token: token)
  }

  func refresh(
    configuration: ProviderConfiguration,
    proxy: ProxySettings,
    token: @escaping @Sendable () async throws -> String
  ) {
    fetch(configuration: configuration, proxy: proxy, reportsErrors: true, token: token)
  }

  func cancelFetch(for configuration: ProviderConfiguration) {
    let key = Self.key(for: configuration)
    tasks[key]?.cancel()
    finish(key, generation: generations[key])
  }

  private func fetch(
    configuration: ProviderConfiguration,
    proxy: ProxySettings,
    reportsErrors: Bool,
    token: @escaping @Sendable () async throws -> String
  ) {
    let key = Self.key(for: configuration)
    guard tasks[key] == nil else { return }
    let generation = UUID()
    generations[key] = generation
    fetching.insert(key)
    errors[key] = nil

    tasks[key] = Task { [weak self] in
      defer { self?.finish(key, generation: generation) }
      do {
        let credential = try await token()
        let models = try await ModelCatalogClient().fetchModels(
          configuration: configuration,
          apiKey: credential,
          proxy: proxy
        )
        try Task.checkCancellation()
        self?.store(models, for: key)
      } catch is CancellationError {
        return
      } catch {
        // A failed refresh leaves the last good catalog in place; only a
        // refresh the user asked for gets to say so on screen.
        if reportsErrors {
          self?.errors[key] = error.localizedDescription
        }
      }
    }
  }

  private func finish(_ key: String, generation: UUID?) {
    guard let generation, generations[key] == generation else { return }
    generations[key] = nil
    tasks[key] = nil
    fetching.remove(key)
  }

  private func store(_ models: [String], for key: String) {
    snapshots[key] = ModelCatalogSnapshot(models: models, fetchedAt: Date())
    if snapshots.count > Self.maximumCatalogs {
      let surplus = snapshots
        .sorted { $0.value.fetchedAt < $1.value.fetchedAt }
        .prefix(snapshots.count - Self.maximumCatalogs)
      for entry in surplus {
        snapshots.removeValue(forKey: entry.key)
      }
    }
    guard let data = try? JSONEncoder.catalog.encode(snapshots) else { return }
    defaults.set(data, forKey: Self.storageKey)
  }
}

extension JSONEncoder {
  fileprivate static var catalog: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var catalog: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
