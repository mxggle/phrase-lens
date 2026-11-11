import Foundation

/// Everything the iOS app and its Action extension share: one model
/// connection, the language answers are written in, and the actions on offer.
///
/// The provider, action, and language types are the macOS app's own, so a
/// prompt or a provider fix made there reaches the phone unchanged.
struct MobileSettings: Codable, Equatable, Sendable {
  var provider = ProviderConfiguration()
  var targetLanguage: LanguageCode = .simplifiedChinese
  /// Every action, in the order the result sheet lists them. Built-ins keep
  /// their factory IDs so `PromptBuilder` still recognizes an untouched one.
  var actions: [TranslationAction] = MobileActions.starter
  var defaultActionID: UUID = TranslationAction.builtIn(for: .translate).id

  init() {}

  private enum CodingKeys: String, CodingKey {
    case provider, targetLanguage, actions, defaultActionID
  }

  /// Fields added later decode to their defaults, so an older save still opens.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = MobileSettings()
    provider = try container.decodeIfPresent(ProviderConfiguration.self, forKey: .provider)
      ?? defaults.provider
    targetLanguage = try container.decodeIfPresent(LanguageCode.self, forKey: .targetLanguage)
      ?? defaults.targetLanguage
    actions = try container.decodeIfPresent([TranslationAction].self, forKey: .actions)
      ?? defaults.actions
    defaultActionID = try container.decodeIfPresent(UUID.self, forKey: .defaultActionID)
      ?? defaults.defaultActionID
  }

  /// The action a new lookup starts with: the chosen default while it still
  /// exists, otherwise the first one listed.
  var defaultAction: TranslationAction? {
    actions.first { $0.id == defaultActionID } ?? actions.first
  }

  /// The configuration a request for `action` is sent with. Only the model
  /// can differ per action; the provider and its key are shared.
  func configuration(for action: TranslationAction) -> ProviderConfiguration {
    action.resolvedConfiguration(from: provider)
  }
}

/// Reads and writes `MobileSettings` in the App Group both processes can see.
///
/// The extension is a fresh process each time it is opened, so it reads the
/// latest save on launch; the app re-reads when it comes back to the
/// foreground in case the two were open at once.
@MainActor
final class MobileSettingsStore: ObservableObject {
  nonisolated static let appGroup = "group.com.harry.phraselens"

  /// Whether this build is signed into the App Group. A free Personal Team
  /// cannot sign one, and then the app and the extension each keep their own
  /// settings and key instead of sharing them.
  nonisolated static var isAppGroupAvailable: Bool {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil
  }
  private static let key = "mobile-settings.v1"

  @Published var settings: MobileSettings {
    didSet {
      guard settings != oldValue else { return }
      save()
    }
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults? = nil) {
    let shared = Self.isAppGroupAvailable ? UserDefaults(suiteName: Self.appGroup) : nil
    let defaults = defaults ?? shared ?? .standard
    self.defaults = defaults
    settings = Self.load(from: defaults)
  }

  func reload() {
    let latest = Self.load(from: defaults)
    if latest != settings { settings = latest }
  }

  private static func load(from defaults: UserDefaults) -> MobileSettings {
    guard let data = defaults.data(forKey: key),
      let settings = try? JSONDecoder().decode(MobileSettings.self, from: data)
    else { return MobileSettings() }
    return settings
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: Self.key)
  }
}
