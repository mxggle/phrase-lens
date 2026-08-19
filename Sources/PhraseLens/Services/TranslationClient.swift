import Foundation

struct TranslationClient: Sendable {
  private static let directSession = configuredSession(proxy: nil)

  func stream(
    prompt: TranslationPrompt,
    configuration: ProviderConfiguration,
    apiKey: String,
    accountId: String? = nil,
    proxy: ProxySettings
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        // Whether the user is already looking at part of an answer. It decides
        // how a failure reads: nothing on screen is a connection that never
        // delivered, text on screen is one that stopped partway.
        var emitted = false
        do {
          if configuration.provider.supportsOAuth && configuration.authMode == .oauthCodex {
            if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              throw TranslationError.missingOAuthCredentials
            }
          } else if configuration.provider.usesAPIKey,
            apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            throw TranslationError.missingAPIKey
          }
          let request = try makeRequest(
            prompt: prompt,
            configuration: configuration,
            apiKey: apiKey,
            accountId: accountId
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

          var truncation: String?
          for try await line in bytes.lines {
            try Task.checkCancellation()
            let event =
              (configuration.provider.supportsOAuth && configuration.authMode == .oauthCodex)
              ? StreamDecoder.responsesEvent(from: line)
              : StreamDecoder.event(from: line, provider: configuration.provider)
            if let chunk = event.text, !chunk.isEmpty {
              emitted = true
              continuation.yield(chunk)
            }
            if let reason = event.truncation {
              truncation = reason
            }
          }
          // A provider that says why it stopped early explains more than the
          // empty-stream fallback, so it is preferred even when nothing came.
          if let truncation {
            throw TranslationError.streamInterrupted(truncation)
          }
          if !emitted {
            throw TranslationError.invalidResponse
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish(throwing: TranslationError.cancelled)
        } catch let error as URLError where error.code == .cancelled {
          // Stopping the request tears the connection down; that is the user's
          // own doing, not a network failure to report as one.
          continuation.finish(throwing: TranslationError.cancelled)
        } catch let error as URLError {
          continuation.finish(
            throwing: emitted
              ? TranslationError.streamInterrupted(error.localizedDescription)
              : TranslationError.network(error.localizedDescription)
          )
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
    apiKey: String,
    accountId: String? = nil
  ) throws -> URLRequest {
    if configuration.provider.supportsOAuth && configuration.authMode == .oauthCodex {
      return try codexResponsesRequest(
        prompt: prompt,
        configuration: configuration,
        accessToken: apiKey,
        accountId: accountId
      )
    }
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

  /// ChatGPT-subscription tokens only work against the Codex backend, which
  /// speaks the Responses API and routes by account id — the user-editable
  /// endpoint and any Platform-API fields (organization, temperature) do not
  /// apply here.
  private func codexResponsesRequest(
    prompt: TranslationPrompt,
    configuration: ProviderConfiguration,
    accessToken: String,
    accountId: String?
  ) throws -> URLRequest {
    guard let url = URL(string: CodexBackend.responsesEndpoint) else {
      throw TranslationError.invalidEndpoint("the Codex backend URL is invalid")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    if let accountId, !accountId.isEmpty {
      request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
    }
    request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
    request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")

    let input: [[String: Any]] = prompt.messages.map { turn in
      let contentType = turn.role == .assistant ? "output_text" : "input_text"
      return [
        "type": "message",
        "role": turn.role.rawValue,
        "content": [["type": contentType, "text": turn.content]],
      ]
    }
    let body: [String: Any] = [
      "model": configuration.model,
      "instructions": prompt.system,
      "input": input,
      "tools": [],
      "tool_choice": "auto",
      "parallel_tool_calls": false,
      // Translation is latency-sensitive, so the model gets the lightest
      // reasoning effort the backend accepts.
      "reasoning": ["effort": "low"],
      "store": false,
      "stream": true,
      "include": ["reasoning.encrypted_content"],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
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
      "messages": [["role": "system", "content": prompt.system]] + Self.chatMessages(prompt),
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
    // Anthropic bills thinking tokens against max_tokens, so a shared cap leaves
    // the visible answer whatever thinking did not spend. Budget them apart.
    let thinkingBudget = 4_000
    let answerBudget = 4_096
    var body: [String: Any] = [
      "model": configuration.model,
      "max_tokens": configuration.extendedThinking
        ? thinkingBudget + answerBudget : answerBudget,
      "stream": true,
      "system": prompt.system,
      "messages": Self.chatMessages(prompt),
    ]
    if configuration.extendedThinking {
      body["thinking"] = ["type": "enabled", "budget_tokens": thinkingBudget]
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
      // Gemini names the model's own turns "model" rather than "assistant".
      "contents": prompt.messages.map { turn in
        [
          "role": turn.role == .assistant ? "model" : "user",
          "parts": [["text": turn.content]],
        ]
      },
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
      "messages": [["role": "system", "content": prompt.system]] + Self.chatMessages(prompt),
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
      "messages": [["role": "system", "content": prompt.system]] + Self.chatMessages(prompt),
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  /// The exchange in the shape every OpenAI-style API takes it in. The system
  /// prompt is not included: each provider carries that its own way.
  private static func chatMessages(_ prompt: TranslationPrompt) -> [[String: String]] {
    prompt.messages.map { ["role": $0.role.rawValue, "content": $0.content] }
  }

  private func makeSession(proxy: ProxySettings) -> URLSession {
    guard proxy.enabled, !proxy.host.isEmpty else {
      return Self.directSession
    }
    return Self.configuredSession(proxy: proxy)
  }

  private static func configuredSession(proxy: ProxySettings?) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    // Waiting for connectivity takes timeoutIntervalForRequest out of play, and
    // timeoutIntervalForResource then defaults to a week: an offline user would
    // watch the spinner forever. A translation the user just asked for should
    // fail fast enough to say why, with a backstop for the whole stream.
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForResource = 600
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
    guard let data = body.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return "Provider error \(status)."
    }
    if let error = object["error"] as? [String: Any],
      let message = error["message"] as? String
    {
      return "Provider error \(status): \(message)"
    }
    // The ChatGPT backend reports failures in a `detail` field instead.
    if let detail = object["detail"] as? String {
      return "Provider error \(status): \(detail)"
    }
    return "Provider error \(status)."
  }
}

/// What one server-sent line carried.
struct StreamEvent {
  /// Text to show. `nil` for keep-alives, control frames, and the private
  /// reasoning the user must never see.
  var text: String?
  /// The provider's own statement that it stopped early, in plain language.
  /// A truncated stream still ends cleanly on the wire, so without this the
  /// user is handed a half-answer that looks finished.
  var truncation: String?
}

enum StreamDecoder {
  static func content(from rawLine: String, provider: ProviderKind) -> String? {
    event(from: rawLine, provider: provider).text
  }

  /// Decodes SSE lines from the OpenAI Responses API (ChatGPT Codex backend).
  static func responsesEvent(from rawLine: String) -> StreamEvent {
    var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty, !line.hasPrefix("event:") else { return StreamEvent() }
    if line.hasPrefix("data:") {
      line = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }
    guard line != "[DONE]", let data = line.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return StreamEvent()
    }

    let type = json["type"] as? String

    var truncation: String?
    if let responseObj = json["response"] as? [String: Any] {
      if let status = responseObj["status"] as? String, status == "incomplete" {
        if let details = responseObj["status_details"] as? [String: Any],
          let reason = details["reason"] as? String
        {
          truncation = describe(openAI: reason) ?? "the model stopped early (\(reason))"
        } else {
          truncation = lengthLimit
        }
      }
    }

    if type == "response.text.delta" {
      let text = json["delta"] as? String
      return StreamEvent(text: text, truncation: truncation)
    }

    if type == "response.output_item.delta" {
      if let deltaStr = json["delta"] as? String {
        return StreamEvent(text: deltaStr, truncation: truncation)
      }
      if let deltaObj = json["delta"] as? [String: Any] {
        if let text = deltaObj["text"] as? String {
          return StreamEvent(text: text, truncation: truncation)
        }
        if let contentList = deltaObj["content"] as? [[String: Any]],
          let first = contentList.first,
          let text = first["text"] as? String
        {
          return StreamEvent(text: text, truncation: truncation)
        }
      }
    }

    if type == "response.content_part.delta" {
      if let deltaStr = json["delta"] as? String {
        return StreamEvent(text: deltaStr, truncation: truncation)
      }
      if let deltaObj = json["delta"] as? [String: Any],
        let text = deltaObj["text"] as? String
      {
        return StreamEvent(text: text, truncation: truncation)
      }
    }

    if let delta = json["delta"] as? String {
      return StreamEvent(text: delta, truncation: truncation)
    }
    if json["text"] as? String != nil, type == "response.text.done" {
      return StreamEvent(text: nil, truncation: truncation)
    }

    if let choices = json["choices"] as? [[String: Any]],
      let first = choices.first
    {
      let openAITrunc = describe(openAI: first["finish_reason"] as? String)
      if let delta = first["delta"] as? [String: Any] {
        return StreamEvent(text: delta["content"] as? String, truncation: openAITrunc ?? truncation)
      }
      return StreamEvent(
        text: (first["message"] as? [String: Any])?["content"] as? String,
        truncation: openAITrunc ?? truncation
      )
    }

    return StreamEvent(truncation: truncation)
  }

  /// Decodes a line once. Text and stop reason arrive on the same frames for
  /// most providers, and this runs on every line of every stream, so they are
  /// read together rather than by parsing the JSON twice.
  static func event(from rawLine: String, provider: ProviderKind) -> StreamEvent {
    var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty, !line.hasPrefix("event:") else { return StreamEvent() }
    if line.hasPrefix("data:") {
      line = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }
    guard line != "[DONE]", let data = line.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return StreamEvent()
    }

    switch provider {
    case .anthropic:
      let delta = json["delta"] as? [String: Any]
      return StreamEvent(
        text: delta?["text"] as? String,
        // The stop reason for the whole message rides on `message_delta`.
        truncation: describe(
          anthropic: delta?["stop_reason"] as? String ?? json["stop_reason"] as? String
        )
      )

    case .gemini:
      guard let candidates = json["candidates"] as? [[String: Any]],
        let candidate = candidates.first
      else { return StreamEvent() }
      let finish = describe(gemini: candidate["finishReason"] as? String)
      guard let content = candidate["content"] as? [String: Any],
        let parts = content["parts"] as? [[String: Any]]
      else { return StreamEvent(truncation: finish) }
      let finalText = parts.compactMap { part -> String? in
        // Gemini thinking models mark internal thought parts explicitly. They are
        // model working state, not user-visible translation output.
        guard part["thought"] as? Bool != true else { return nil }
        return part["text"] as? String
      }.joined()
      return StreamEvent(text: finalText.isEmpty ? nil : finalText, truncation: finish)

    case .ollama:
      let truncation = json["done_reason"] as? String == "length" ? lengthLimit : nil
      if let message = json["message"] as? [String: Any] {
        let content = message["content"] as? String
        return StreamEvent(
          text: (content?.isEmpty ?? true) ? nil : content,
          truncation: truncation
        )
      }
      return StreamEvent(text: json["response"] as? String, truncation: truncation)

    case .cohere:
      let delta = json["delta"] as? [String: Any]
      let text = ((delta?["message"] as? [String: Any])?["content"] as? [String: Any])?["text"]
      return StreamEvent(
        text: text as? String,
        truncation: describe(cohere: delta?["finish_reason"] as? String)
      )

    default:
      guard let choices = json["choices"] as? [[String: Any]],
        let first = choices.first
      else { return StreamEvent() }
      let truncation = describe(openAI: first["finish_reason"] as? String)
      if let delta = first["delta"] as? [String: Any] {
        // OpenAI-compatible reasoning models commonly stream private chain-of-
        // thought separately in `reasoning_content` before the final `content`.
        // Never merge that field into the text shown to the user.
        return StreamEvent(text: delta["content"] as? String, truncation: truncation)
      }
      return StreamEvent(
        text: (first["message"] as? [String: Any])?["content"] as? String,
        truncation: truncation
      )
    }
  }

  // MARK: - Stop reasons

  private static let lengthLimit = "the answer reached the model's length limit"
  private static let filtered = "the provider's content filter stopped it"

  private static func describe(openAI reason: String?) -> String? {
    switch reason {
    case "length": lengthLimit
    case "content_filter": filtered
    default: nil
    }
  }

  private static func describe(anthropic reason: String?) -> String? {
    switch reason {
    case "max_tokens": lengthLimit
    case "refusal": "the model declined to continue"
    default: nil
    }
  }

  private static func describe(cohere reason: String?) -> String? {
    switch reason {
    case "MAX_TOKENS": lengthLimit
    case "ERROR": "the provider ended the stream with an error"
    default: nil
    }
  }

  private static func describe(gemini reason: String?) -> String? {
    switch reason {
    // A finished answer and an absent field both mean nothing went wrong.
    case nil, "STOP", "FINISH_REASON_UNSPECIFIED": nil
    case "MAX_TOKENS": lengthLimit
    case "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII": filtered
    case "RECITATION": "the provider stopped it for reproducing training data"
    case .some(let other): "the provider ended it early (\(other))"
    }
  }
}
