import Foundation

struct ModelCatalogClient: Sendable {
  func fetchModels(
    configuration: ProviderConfiguration,
    apiKey: String,
    proxy: ProxySettings
  ) async throws -> [String] {
    if configuration.provider.usesAPIKey,
      apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw ModelCatalogError.missingAPIKey
    }

    var request = URLRequest(url: try modelListURL(for: configuration))
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    applyAuthentication(
      to: &request,
      provider: configuration.provider,
      apiKey: apiKey,
      organization: configuration.organization
    )

    let (data, response) = try await makeSession(proxy: proxy).data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ModelCatalogError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw ModelCatalogError.requestFailed(status: http.statusCode)
    }

    let models = try Self.parseModels(data, provider: configuration.provider)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let uniqueModels = Array(Set(models)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    guard !uniqueModels.isEmpty else { throw ModelCatalogError.noModels }
    return uniqueModels
  }

  static func parseModels(_ data: Data, provider: ProviderKind) throws -> [String] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ModelCatalogError.invalidResponse
    }
    let rows: [[String: Any]]
    if provider == .gemini {
      rows = object["models"] as? [[String: Any]] ?? []
      return rows.compactMap { row in
        let methods = row["supportedGenerationMethods"] as? [String]
        guard methods?.contains("generateContent") != false else { return nil }
        return (row["name"] as? String)?.replacingOccurrences(of: "models/", with: "")
      }
    }
    if provider == .ollama {
      rows = object["models"] as? [[String: Any]] ?? []
      return rows.compactMap { ($0["name"] ?? $0["model"]) as? String }
    }
    rows = (object["data"] ?? object["models"]) as? [[String: Any]] ?? []
    return rows.compactMap { ($0["id"] ?? $0["name"] ?? $0["model"]) as? String }
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
  case unsupportedProvider(String)
  case invalidEndpoint
  case invalidResponse
  case requestFailed(status: Int)
  case noModels

  var errorDescription: String? {
    switch self {
    case .missingAPIKey: "Save an API key for this provider before fetching models."
    case .unsupportedProvider(let message): message
    case .invalidEndpoint: "The model catalog endpoint could not be created."
    case .invalidResponse: "The provider returned an invalid model catalog response."
    case .requestFailed(let status): "Fetching models failed with HTTP \(status)."
    case .noModels: "The provider returned no selectable models."
    }
  }
}
