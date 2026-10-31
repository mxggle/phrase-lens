import Foundation

/// A tool the study assistant can call, described the way every provider
/// takes it: a name, what it is for, and a JSON Schema for its arguments.
struct AgentTool: Sendable, Equatable {
  var name: String
  var description: String
  /// The arguments' JSON Schema, as JSON text.
  var parameters: String

  var schema: [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(parameters.utf8))) as? [String: Any]
      ?? ["type": "object", "properties": [String: Any]()]
  }
}

struct AgentToolCall: Sendable, Equatable {
  var id: String
  var name: String
  /// The arguments as JSON text.
  var arguments: String

  var argumentObject: [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
  }
}

/// One message in a tool-using exchange.
enum AgentMessage: Sendable, Equatable {
  case user(String)
  /// What the model said and asked for. `raw` is the provider's own form of
  /// the turn, echoed back verbatim where the provider requires it — Claude's
  /// thinking blocks must return exactly as they came.
  case assistant(text: String, toolCalls: [AgentToolCall], raw: String?)
  case toolResult(callID: String, name: String, content: String)
}

struct AgentReply: Sendable, Equatable {
  var text: String
  var toolCalls: [AgentToolCall]
  var raw: String?
}

/// How a connection is asked to use tools.
enum AgentProtocol: Sendable, Equatable {
  /// Anthropic Messages `tools`.
  case anthropic
  /// OpenAI Chat Completions `tools`, which most compatible gateways accept.
  case openAI
  /// Everything else: the tools are described in the prompt and the model
  /// answers with a JSON object when it wants one. Slower and less reliable,
  /// but it works over any connection the app can already stream from.
  case textJSON

  static func of(_ configuration: ProviderConfiguration) -> AgentProtocol {
    if configuration.provider.supportsOAuth && configuration.authMode == .oauthCodex { return .textJSON }
    switch configuration.provider {
    case .anthropic: return .anthropic
    case .gemini, .ollama, .cohere: return .textJSON
    default: return .openAI
    }
  }
}

/// One turn of a tool-using exchange, over whichever protocol the connection
/// speaks.
///
/// Native requests are built by the same builders translation uses, so every
/// provider quirk they handle — Azure deployments, reasoning models that
/// reject a temperature, Claude's thinking budget — applies here unchanged;
/// only the body's messages, tools, and streaming flag are rewritten.
struct AgentClient: Sendable {
  private let client = TranslationClient()

  func turn(
    system: String,
    messages: [AgentMessage],
    tools: [AgentTool],
    configuration: ProviderConfiguration,
    apiKey: String,
    accountId: String?,
    proxy: ProxySettings
  ) async throws -> AgentReply {
    let kind = AgentProtocol.of(configuration)
    if kind == .textJSON {
      var reply = ""
      for try await chunk in client.stream(
        prompt: Self.textPrompt(system: system, messages: messages, tools: tools),
        configuration: configuration, apiKey: apiKey, accountId: accountId, proxy: proxy
      ) {
        try Task.checkCancellation()
        reply.append(chunk)
      }
      return Self.textReply(reply)
    }

    if configuration.provider.usesAPIKey, apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw TranslationError.missingAPIKey
    }
    let request = try Self.request(
      system: system, messages: messages, tools: tools, protocol: kind,
      configuration: configuration, apiKey: apiKey, accountId: accountId
    )
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await client.makeSession(proxy: proxy).data(for: request)
    } catch is CancellationError {
      throw TranslationError.cancelled
    } catch let error as URLError where error.code == .cancelled {
      throw TranslationError.cancelled
    } catch let error as URLError {
      throw TranslationError.network(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else { throw TranslationError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      throw TranslationError.provider(
        client.providerError(status: http.statusCode, body: String(decoding: data.prefix(16_384), as: UTF8.self))
      )
    }
    guard let reply = kind == .anthropic ? Self.anthropicReply(data) : Self.openAIReply(data) else {
      throw TranslationError.invalidResponse
    }
    return reply
  }

  // MARK: - Native requests

  static func request(
    system: String,
    messages: [AgentMessage],
    tools: [AgentTool],
    protocol kind: AgentProtocol,
    configuration: ProviderConfiguration,
    apiKey: String,
    accountId: String?
  ) throws -> URLRequest {
    var request = try TranslationClient().makeRequest(
      prompt: TranslationPrompt(system: system, user: ""),
      configuration: configuration,
      apiKey: apiKey,
      accountId: accountId
    )
    guard let original = request.httpBody,
      var body = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any]
    else { throw TranslationError.invalidResponse }
    body["stream"] = false
    switch kind {
    case .anthropic:
      body["messages"] = anthropicMessages(messages)
      body["tools"] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] }
    case .openAI, .textJSON:
      body["messages"] = [["role": "system", "content": system]] + openAIMessages(messages)
      body["tools"] = tools.map {
        ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]]
      }
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  static func anthropicMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
    var result: [[String: Any]] = []
    // Results for one assistant turn travel together in a single user turn.
    var pendingResults: [[String: Any]] = []
    func flush() {
      guard !pendingResults.isEmpty else { return }
      result.append(["role": "user", "content": pendingResults])
      pendingResults = []
    }
    for message in messages {
      switch message {
      case .user(let text):
        flush()
        result.append(["role": "user", "content": text])
      case .assistant(let text, let calls, let raw):
        flush()
        if let raw, let content = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [Any] {
          result.append(["role": "assistant", "content": content])
        } else {
          var content: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
          content += calls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": $0.argumentObject] }
          result.append(["role": "assistant", "content": content])
        }
      case .toolResult(let id, _, let content):
        pendingResults.append(["type": "tool_result", "tool_use_id": id, "content": content])
      }
    }
    flush()
    return result
  }

  static func openAIMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
    messages.map { message -> [String: Any] in
      switch message {
      case .user(let text):
        return ["role": "user", "content": text]
      case .assistant(let text, let calls, let raw):
        var turn: [String: Any] = ["role": "assistant", "content": text.isEmpty && !calls.isEmpty ? NSNull() : text]
        if !calls.isEmpty {
          turn["tool_calls"] = calls.map {
            ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
          }
        }
        // Reasoning models that think between tool calls want their
        // reasoning back within the same question.
        if let raw, let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
          let reasoning = object["reasoning_content"] as? String
        {
          turn["reasoning_content"] = reasoning
        }
        return turn
      case .toolResult(let id, _, let content):
        return ["role": "tool", "tool_call_id": id, "content": content]
      }
    }
  }

  static func anthropicReply(_ data: Data) -> AgentReply? {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let content = object["content"] as? [[String: Any]]
    else { return nil }
    var text = ""
    var calls: [AgentToolCall] = []
    for block in content {
      switch block["type"] as? String {
      case "text":
        text += block["text"] as? String ?? ""
      case "tool_use":
        guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
        let input = block["input"] ?? [String: Any]()
        let arguments = (try? JSONSerialization.data(withJSONObject: input)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        calls.append(AgentToolCall(id: id, name: name, arguments: arguments))
      default:
        continue
      }
    }
    let raw = (try? JSONSerialization.data(withJSONObject: content)).map { String(decoding: $0, as: UTF8.self) }
    return AgentReply(text: text, toolCalls: calls, raw: raw)
  }

  static func openAIReply(_ data: Data) -> AgentReply? {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let choices = object["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any]
    else { return nil }
    let text = message["content"] as? String ?? ""
    let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { call -> AgentToolCall? in
      guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
      let arguments: String
      if let string = function["arguments"] as? String {
        arguments = string
      } else if let object = function["arguments"],
        let data = try? JSONSerialization.data(withJSONObject: object)
      {
        arguments = String(decoding: data, as: UTF8.self)
      } else {
        arguments = "{}"
      }
      return AgentToolCall(id: call["id"] as? String ?? "call_\(name)", name: name, arguments: arguments)
    }
    let raw = (try? JSONSerialization.data(withJSONObject: message)).map { String(decoding: $0, as: UTF8.self) }
    return AgentReply(text: text, toolCalls: calls, raw: raw)
  }

  // MARK: - Tools described in the prompt

  static func textPrompt(system: String, messages: [AgentMessage], tools: [AgentTool]) -> TranslationPrompt {
    let catalog = tools.map { "- \($0.name): \($0.description) Arguments schema: \($0.parameters)" }
      .joined(separator: "\n")
    let instructions = """
      \(system)

      You can call these tools:
      \(catalog)

      To call tools, reply with only a JSON object and nothing else, in this shape:
      {"tool_calls":[{"name":"tool_name","arguments":{}}]}
      Tool results come back inside <tool-results>. When you have what you need, reply with \
      the answer itself in Markdown, with no JSON.
      """
    var turns: [PromptTurn] = []
    var pendingResults: [String] = []
    func flush() {
      guard !pendingResults.isEmpty else { return }
      turns.append(PromptTurn(role: .user, content: "<tool-results>\n\(pendingResults.joined(separator: "\n"))\n</tool-results>"))
      pendingResults = []
    }
    for message in messages {
      switch message {
      case .user(let text):
        flush()
        turns.append(PromptTurn(role: .user, content: text))
      case .assistant(let text, let calls, _):
        flush()
        if calls.isEmpty {
          turns.append(PromptTurn(role: .assistant, content: text))
        } else {
          let list = calls.map { "{\"name\":\"\($0.name)\",\"arguments\":\($0.arguments)}" }.joined(separator: ",")
          turns.append(PromptTurn(role: .assistant, content: "{\"tool_calls\":[\(list)]}"))
        }
      case .toolResult(_, let name, let content):
        pendingResults.append("[\(name)] \(content)")
      }
    }
    flush()
    guard let last = turns.popLast() else {
      return TranslationPrompt(system: instructions, user: "")
    }
    return TranslationPrompt(system: instructions, user: last.content, priorTurns: turns)
  }

  /// A reply that is a tool request is a JSON object with `tool_calls`; any
  /// other reply is the answer.
  static func textReply(_ reply: String) -> AgentReply {
    let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    if let object = LearningCoach.jsonObject(in: trimmed),
      let list = object["tool_calls"] as? [[String: Any]], !list.isEmpty
    {
      let calls = list.enumerated().compactMap { offset, item -> AgentToolCall? in
        guard let name = item["name"] as? String else { return nil }
        let arguments = (item["arguments"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
          .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return AgentToolCall(id: "call_\(offset)", name: name, arguments: arguments)
      }
      if !calls.isEmpty { return AgentReply(text: "", toolCalls: calls, raw: nil) }
    }
    return AgentReply(text: trimmed, toolCalls: [], raw: nil)
  }
}
