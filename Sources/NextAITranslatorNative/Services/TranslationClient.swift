import Foundation

struct TranslationClient: Sendable {
  private static let directSession = configuredSession(proxy: nil)

  func stream(
    prompt: TranslationPrompt,
    configuration: ProviderConfiguration,
    apiKey: String,
    proxy: ProxySettings
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          if configuration.provider.usesAPIKey,
            apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            throw TranslationError.missingAPIKey
          }
          let request = try makeRequest(
            prompt: prompt,
            configuration: configuration,
            apiKey: apiKey
          )
          let session = makeSession(proxy: proxy)
          let (bytes, response) = try await session.bytes(for: request)
          guard let http = response as? HTTPURLResponse else {
            throw TranslationError.invalidResponse
          }
          guard (200..<300).contains(http.statusCode) else {
            var bodyData = Data()
            for try await byte in bytes {
              if bodyData.count >= 16_384 { break }
              bodyData.append(byte)
            }
            throw TranslationError.provider(
              providerError(
                status: http.statusCode,
                body: String(decoding: bodyData, as: UTF8.self)
              )
            )
          }

          var emitted = false
          for try await line in bytes.lines {
            try Task.checkCancellation()
            if let chunk = StreamDecoder.content(
              from: line,
              provider: configuration.provider
            ), !chunk.isEmpty {
              emitted = true
              continuation.yield(chunk)
            }
          }
          if !emitted {
            throw TranslationError.invalidResponse
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish(throwing: TranslationError.cancelled)
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func makeRequest(
    prompt: TranslationPrompt,
    configuration: ProviderConfiguration,
    apiKey: String
  ) throws -> URLRequest {
    switch configuration.provider {
    case .anthropic:
      return try anthropicRequest(
        prompt: prompt,
        configuration: configuration,
        apiKey: apiKey
      )
    case .gemini:
      return try geminiRequest(
        prompt: prompt,
        configuration: configuration,
        apiKey: apiKey
      )
    case .ollama:
      return try ollamaRequest(prompt: prompt, configuration: configuration)
    case .cohere:
      return try cohereRequest(
        prompt: prompt,
        configuration: configuration,
        apiKey: apiKey
      )
    default:
      return try openAICompatibleRequest(
        prompt: prompt,
        configuration: configuration,
        apiKey: apiKey
      )
    }
  }

  private func openAICompatibleRequest(
    prompt: TranslationPrompt,
    configuration: ProviderConfiguration,
    apiKey: String
  ) throws -> URLRequest {
    var url = try EndpointValidator.validate(
      configuration.endpoint,
      provider: configuration.provider
    )
    if configuration.provider == .azure {
      guard !configuration.model.isEmpty else {
        throw TranslationError.invalidEndpoint("Azure deployment name is required")
      }
      if !url.path.contains("/chat/completions") {
        url.append(path: "openai/deployments/\(configuration.model)/chat/completions")
      }
      url = url.appending(
        queryItems: [URLQueryItem(name: "api-version", value: configuration.apiVersion)]
      )
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if configuration.provider == .azure {
      request.setValue(apiKey, forHTTPHeaderField: "api-key")
    } else {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      if !configuration.organization.isEmpty {
        request.setValue(configuration.organization, forHTTPHeaderField: "OpenAI-Organization")
      }
    }

    var body: [String: Any] = [
      "model": configuration.model,
      "stream": true,
      "temperature": 0.2,
      "messages": [
        ["role": "system", "content": prompt.system],
        ["role": "user", "content": prompt.user],
      ],
    ]
    if configuration.provider == .miniMax {
      body["tokens_to_generate"] = 4_096
    }
    if configuration.supportsReasoningControl {
      body["reasoning_effort"] = configuration.reasoningEnabled ? "high" : "none"
      body["thinking"] = [
        "type": configuration.reasoningEnabled ? "enabled" : "disabled"
      ]
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  private func anthropicRequest(
    prompt: TranslationPrompt,
    configuration: ProviderConfiguration,
    apiKey: String
  ) throws -> URLRequest {
    let url = try EndpointValidator.validate(configuration.endpoint, provider: .anthropic)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    var body: [String: Any] = [
      "model": configuration.model,
      "max_tokens": 4_096,
      "stream": true,
      "system": prompt.system,
      "messages": [["role": "user", "content": prompt.user]],
    ]
    if configuration.extendedThinking {
      body["thinking"] = ["type": "enabled", "budget_tokens": 4_000]
      body["temperature"] = 1
    } else {
      body["temperature"] = 0.2
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  private func geminiRequest(
    prompt: TranslationPrompt,
    configuration: ProviderConfiguration,
    apiKey: String
  ) throws -> URLRequest {
    var base = try EndpointValidator.validate(configuration.endpoint, provider: .gemini)
    base.append(path: "models/\(configuration.model):streamGenerateContent")
    let url = base.appending(queryItems: [
      URLQueryItem(name: "alt", value: "sse"),
      URLQueryItem(name: "key", value: apiKey),
    ])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = [
      "systemInstruction": ["parts": [["text": prompt.system]]],
      "contents": [["role": "user", "parts": [["text": prompt.user]]]],
      "generationConfig": ["temperature": 0.2],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  private func ollamaRequest(
    prompt: TranslationPrompt,
    configuration: ProviderConfiguration
  ) throws -> URLRequest {
    let url = try EndpointValidator.validate(configuration.endpoint, provider: .ollama)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 300
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = [
      "model": configuration.model,
      "stream": true,
      "messages": [
        ["role": "system", "content": prompt.system],
        ["role": "user", "content": prompt.user],
      ],
      "options": ["temperature": 0.2],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  private func cohereRequest(
    prompt: TranslationPrompt,
    configuration: ProviderConfiguration,
    apiKey: String
  ) throws -> URLRequest {
    let url = try EndpointValidator.validate(configuration.endpoint, provider: .cohere)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    let body: [String: Any] = [
      "model": configuration.model,
      "stream": true,
      "temperature": 0.2,
      "messages": [
        ["role": "system", "content": prompt.system],
        ["role": "user", "content": prompt.user],
      ],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  private func makeSession(proxy: ProxySettings) -> URLSession {
    guard proxy.enabled, !proxy.host.isEmpty else {
      return Self.directSession
    }
    return Self.configuredSession(proxy: proxy)
  }

  private static func configuredSession(proxy: ProxySettings?) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.waitsForConnectivity = true
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    if let proxy {
      configuration.connectionProxyDictionary = [
        kCFNetworkProxiesHTTPEnable as String: proxy.scheme == "http",
        kCFNetworkProxiesHTTPProxy as String: proxy.host,
        kCFNetworkProxiesHTTPPort as String: proxy.port,
        kCFNetworkProxiesHTTPSEnable as String: proxy.scheme == "https",
        kCFNetworkProxiesHTTPSProxy as String: proxy.host,
        kCFNetworkProxiesHTTPSPort as String: proxy.port,
        kCFNetworkProxiesExceptionsList as String: proxy.noProxy
          .split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespaces) },
      ]
    }
    return URLSession(configuration: configuration)
  }

  private func providerError(status: Int, body: String) -> String {
    if let data = body.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = object["error"] as? [String: Any],
      let message = error["message"] as? String
    {
      return "Provider error \(status): \(message)"
    }
    return "Provider error \(status)."
  }
}

enum StreamDecoder {
  static func content(from rawLine: String, provider: ProviderKind) -> String? {
    var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty, !line.hasPrefix("event:") else { return nil }
    if line.hasPrefix("data:") {
      line = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }
    guard line != "[DONE]", let data = line.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }

    switch provider {
    case .anthropic:
      if let delta = json["delta"] as? [String: Any],
        let text = delta["text"] as? String
      {
        return text
      }
      return nil

    case .gemini:
      guard let candidates = json["candidates"] as? [[String: Any]],
        let content = candidates.first?["content"] as? [String: Any],
        let parts = content["parts"] as? [[String: Any]]
      else { return nil }
      let finalText = parts.compactMap { part -> String? in
        // Gemini thinking models mark internal thought parts explicitly. They are
        // model working state, not user-visible translation output.
        guard part["thought"] as? Bool != true else { return nil }
        return part["text"] as? String
      }.joined()
      return finalText.isEmpty ? nil : finalText

    case .ollama:
      if let message = json["message"] as? [String: Any] {
        if let content = message["content"] as? String, !content.isEmpty { return content }
        return nil
      }
      return json["response"] as? String

    case .cohere:
      if let delta = json["delta"] as? [String: Any],
        let message = delta["message"] as? [String: Any],
        let content = message["content"] as? [String: Any],
        let text = content["text"] as? String
      {
        return text
      }
      return nil

    default:
      guard let choices = json["choices"] as? [[String: Any]],
        let first = choices.first
      else { return nil }
      if let delta = first["delta"] as? [String: Any] {
        if let text = delta["content"] as? String { return text }
        // OpenAI-compatible reasoning models commonly stream private chain-of-
        // thought separately in `reasoning_content` before the final `content`.
        // Never merge that field into the text shown to the user.
      }
      return (first["message"] as? [String: Any])?["content"] as? String
    }
  }
}
