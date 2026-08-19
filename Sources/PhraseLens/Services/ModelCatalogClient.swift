import Foundation

struct ModelCatalogClient: Sendable {
  /// Gemini pages its catalog and defaults to a small page, so a single
  /// request silently hides most of the models. Everything else returns one
  /// list.
  private static let geminiPageSize = 200
  private static let geminiPageLimit = 10

  func fetchModels(
    configuration: ProviderConfiguration,
    apiKey: String,
    proxy: ProxySettings
  ) async throws -> [String] {
    if configuration.provider.supportsOAuth && configuration.authMode == .oauthCodex {
      return try await fetchCodexModels(apiKey: apiKey, proxy: proxy)
    }

    let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if configuration.provider.usesAPIKey, token.isEmpty {
      throw ModelCatalogError.missingAPIKey
    }

    let baseURL = try modelListURL(for: configuration)
    let session = makeSession(proxy: proxy)
    var collected: [String] = []
    var pageToken: String?
    var page = 0

    repeat {
      try Task.checkCancellation()
      let url = try pagedURL(baseURL, provider: configuration.provider, pageToken: pageToken)
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.timeoutInterval = 30
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      applyAuthentication(
        to: &request,
        provider: configuration.provider,
        apiKey: apiKey,
        organization: configuration.organization
      )

      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw ModelCatalogError.invalidResponse
      }
      guard (200..<300).contains(http.statusCode) else {
        throw ModelCatalogError.requestFailed(status: http.statusCode)
      }
      collected += try Self.parseModels(data, provider: configuration.provider)
      pageToken =
        configuration.provider == .gemini ? Self.parseNextPageToken(data) : nil
      page += 1
    } while pageToken != nil && page < Self.geminiPageLimit

    let models = Self.deduplicated(collected)
    guard !models.isEmpty else { throw ModelCatalogError.noModels }
    return models
  }

  private func fetchCodexModels(apiKey: String, proxy: ProxySettings) async throws -> [String] {
    let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if token.isEmpty {
      throw ModelCatalogError.missingOAuthCredentials
    }
    guard var components = URLComponents(string: CodexBackend.modelsEndpoint) else {
      throw ModelCatalogError.invalidEndpoint
    }
    components.queryItems = [
      URLQueryItem(name: "client_version", value: CodexBackend.clientVersion)
    ]
    guard let url = components.url else {
      throw ModelCatalogError.invalidEndpoint
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")

    do {
      let (data, response) = try await makeSession(proxy: proxy).data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        return CodexBackend.fallbackModels
      }
      let parsed = try Self.parseCodexModels(data)
      return parsed.isEmpty ? CodexBackend.fallbackModels : parsed
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return CodexBackend.fallbackModels
    }
  }

  /// A model catalog row, kept with its publication date so the newest models
  /// can lead the list instead of whichever id happens to sort first.
  struct CatalogEntry: Sendable {
    var id: String
    var created: Date?
  }

  static func parseModels(_ data: Data, provider: ProviderKind) throws -> [String] {
    deduplicated(ordered(try parseEntries(data, provider: provider)).map(\.id))
  }

  static func parseEntries(_ data: Data, provider: ProviderKind) throws -> [CatalogEntry] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ModelCatalogError.invalidResponse
    }
    let rows: [[String: Any]]
    if provider == .gemini {
      rows = object["models"] as? [[String: Any]] ?? []
      return rows.compactMap { row in
        let methods = row["supportedGenerationMethods"] as? [String]
        guard methods?.contains("generateContent") != false else { return nil }
        guard let name = (row["name"] as? String)?.replacingOccurrences(of: "models/", with: "")
        else { return nil }
        return CatalogEntry(id: name, created: nil)
      }
    }
    if provider == .ollama {
      rows = object["models"] as? [[String: Any]] ?? []
      return rows.compactMap { row in
        guard let name = (row["name"] ?? row["model"]) as? String else { return nil }
        guard isChatCapable(name) else { return nil }
        return CatalogEntry(id: name, created: date(from: row["modified_at"]))
      }
    }
    rows = (object["data"] ?? object["models"]) as? [[String: Any]] ?? []
    return rows.compactMap { row in
      guard let id = (row["id"] ?? row["name"] ?? row["model"]) as? String else { return nil }
      guard isChatCapable(id) else { return nil }
      return CatalogEntry(id: id, created: date(from: row["created"] ?? row["created_at"]))
    }
  }

  static func parseNextPageToken(_ data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let token = object["nextPageToken"] as? String,
      !token.isEmpty
    else { return nil }
    return token
  }

  /// Model ids that no chat request can use. Providers list them alongside the
  /// chat models, and a translation sent to an embedding model fails with an
  /// error that reads like a bad key.
  static func isChatCapable(_ id: String) -> Bool {
    let lower = id.lowercased()
    if lower.hasPrefix("ft:") { return false }
    let excluded = [
      "embed", "rerank", "whisper", "tts", "text-to-speech", "dall-e", "moderation",
      "canary", "audio", "realtime", "transcribe", "stable-diffusion", "image-generation",
      "sora", "veo", "imagen", "-image", "clip-", "guard",
    ]
    return !excluded.contains { lower.contains($0) }
  }

  /// Newest first, but only when the provider dated every row. Mixing dated and
  /// undated rows has no consistent answer, and reshuffling a catalog the
  /// provider already ordered sensibly is worse than leaving it alone.
  static func ordered(_ entries: [CatalogEntry]) -> [CatalogEntry] {
    guard entries.allSatisfy({ $0.created != nil }) else { return entries }
    return entries.enumerated()
      .sorted { lhs, rhs in
        guard let left = lhs.element.created, let right = rhs.element.created, left != right else {
          return lhs.offset < rhs.offset
        }
        return left > right
      }
      .map(\.element)
  }

  static func deduplicated(_ ids: [String]) -> [String] {
    var seen = Set<String>()
    return ids.compactMap { id in
      let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
      return trimmed
    }
  }

  private static func date(from value: Any?) -> Date? {
    if let seconds = value as? Double, seconds > 0 {
      return Date(timeIntervalSince1970: seconds)
    }
    if let text = value as? String {
      return ISO8601DateFormatter().date(from: text)
    }
    return nil
  }

  private func pagedURL(_ url: URL, provider: ProviderKind, pageToken: String?) throws -> URL {
    guard provider == .gemini else { return url }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw ModelCatalogError.invalidEndpoint
    }
    var items = [URLQueryItem(name: "pageSize", value: String(Self.geminiPageSize))]
    if let pageToken {
      items.append(URLQueryItem(name: "pageToken", value: pageToken))
    }
    components.queryItems = items
    guard let paged = components.url else { throw ModelCatalogError.invalidEndpoint }
    return paged
  }

  /// The Codex catalog is a list of rows, each carrying the backend's own
  /// visibility and ordering. Both are used as given: the backend already knows
  /// which models this account and client version may use, so guessing from the
  /// slug — as this used to — only ever removed models it had just offered.
  static func parseCodexModels(_ data: Data) throws -> [String] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return []
    }
    let rows = (object["models"] ?? object["data"]) as? [[String: Any]] ?? []
    return orderedCodexSlugs(
      rows.compactMap { row in
        guard isListed(row) else { return nil }
        guard let slug = (row["slug"] ?? row["id"] ?? row["name"] ?? row["model"]) as? String
        else { return nil }
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed, row["priority"] as? Int ?? Int.max)
      }
    )
  }

  /// `visibility` is the field the backend actually sets — "list" for a model
  /// meant to be offered, "hide" for internals such as `codex-auto-review`. The
  /// older boolean spellings are still honoured in case a deployment uses them.
  private static func isListed(_ row: [String: Any]) -> Bool {
    if let visibility = row["visibility"] as? String { return visibility == "list" }
    if let hidden = row["hidden"] as? Bool, hidden { return false }
    if let enabled = row["enabled"] as? Bool, !enabled { return false }
    return true
  }

  /// Lowest `priority` first, which is how the backend ranks its own list —
  /// newest and most capable at the top. Rows without one sort last, by name.
  static func orderedCodexSlugs(_ rows: [(slug: String, priority: Int)]) -> [String] {
    var seen = Set<String>()
    return
      rows
      .sorted { a, b in
        if a.priority != b.priority { return a.priority < b.priority }
        return a.slug.localizedStandardCompare(b.slug) == .orderedAscending
      }
      .filter { seen.insert($0.slug).inserted }
      .map(\.slug)
  }

  private func modelListURL(for configuration: ProviderConfiguration) throws -> URL {
    let endpoint = try EndpointValidator.validate(
      configuration.endpoint,
      provider: configuration.provider
    )
    if configuration.provider == .azure {
      throw ModelCatalogError.unsupportedProvider(
        "Azure uses deployment names; enter the deployment configured in Azure Portal."
      )
    }

    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
    components?.query = nil
    components?.fragment = nil
    let path = endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let segments = path.split(separator: "/").map(String.init)
    let catalogSegments: [String]
    switch configuration.provider {
    case .gemini:
      catalogSegments = replacingTerminalSegments(segments, terminal: ["models"], with: ["models"])
    case .ollama:
      catalogSegments = replacingTerminalSegments(segments, terminal: ["api", "chat"], with: ["api", "tags"])
    case .anthropic:
      catalogSegments = replacingTerminalSegments(segments, terminal: ["v1", "messages"], with: ["v1", "models"])
    case .cohere:
      catalogSegments = replacingTerminalSegments(segments, terminal: ["v2", "chat"], with: ["v1", "models"])
    default:
      catalogSegments = replacingTerminalSegments(segments, terminal: ["chat", "completions"], with: ["models"])
    }
    components?.path = "/" + catalogSegments.joined(separator: "/")
    guard let url = components?.url else { throw ModelCatalogError.invalidEndpoint }
    return url
  }

  private func replacingTerminalSegments(
    _ source: [String],
    terminal: [String],
    with replacement: [String]
  ) -> [String] {
    guard source.count >= terminal.count,
      Array(source.suffix(terminal.count)) == terminal
    else {
      return source + replacement
    }
    return Array(source.dropLast(terminal.count)) + replacement
  }

  private func applyAuthentication(
    to request: inout URLRequest,
    provider: ProviderKind,
    apiKey: String,
    organization: String
  ) {
    switch provider {
    case .anthropic:
      request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    case .gemini:
      request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    case .ollama:
      break
    default:
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      if provider == .openAI, !organization.isEmpty {
        request.setValue(organization, forHTTPHeaderField: "OpenAI-Organization")
      }
    }
  }

  private func makeSession(proxy: ProxySettings) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    if proxy.enabled, !proxy.host.isEmpty {
      configuration.connectionProxyDictionary = [
        kCFNetworkProxiesHTTPEnable as String: proxy.scheme == "http",
        kCFNetworkProxiesHTTPProxy as String: proxy.host,
        kCFNetworkProxiesHTTPPort as String: proxy.port,
        kCFNetworkProxiesHTTPSEnable as String: proxy.scheme == "https",
        kCFNetworkProxiesHTTPSProxy as String: proxy.host,
        kCFNetworkProxiesHTTPSPort as String: proxy.port,
      ]
    }
    return URLSession(configuration: configuration)
  }
}

enum ModelCatalogError: LocalizedError {
  case missingAPIKey
  case missingOAuthCredentials
  case unsupportedProvider(String)
  case invalidEndpoint
  case invalidResponse
  case requestFailed(status: Int)
  case noModels

  var errorDescription: String? {
    switch self {
    case .missingAPIKey: "Save an API key for this provider before fetching models."
    case .missingOAuthCredentials: "Sign in with ChatGPT before fetching models."
    case .unsupportedProvider(let message): message
    case .invalidEndpoint: "The model catalog endpoint could not be created."
    case .invalidResponse: "The provider returned an invalid model catalog response."
    case .requestFailed(let status): "Fetching models failed with HTTP \(status)."
    case .noModels: "The provider returned no selectable models."
    }
  }
}
