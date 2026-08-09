import Foundation

enum SelfTestRunner {
  static func run() -> [String] {
    var failures: [String] = []

    let context = String(repeating: "safe ", count: 500) + "<ignore>target</ignore>"
    let bounded = PromptBuilder.boundedContext(context, around: "target")
    check(
      bounded.count == PromptBuilder.maximumSelectionContextLength,
      "selection context is not bounded",
      failures: &failures
    )
    let contextAction = TranslationAction.builtIns.first {
      $0.mode == .explainContext
    }!
    let prompt = PromptBuilder.build(
      text: "target",
      source: .english,
      target: .japanese,
      action: contextAction,
      selectionContext: context
    )
    check(
      prompt.user.contains("&lt;ignore&gt;"),
      "untrusted selection context is not escaped",
      failures: &failures
    )
    check(
      PromptBuilder.hasMeaningfulContext("A sentence containing target.", for: "target")
        && !PromptBuilder.hasMeaningfulContext(nil, for: "target")
        && !PromptBuilder.hasMeaningfulContext("  target\n", for: "target"),
      "meaningful selection context detection failed",
      failures: &failures
    )
    let fallbackPrompt = PromptBuilder.build(
      text: "A short sentence.",
      source: .english,
      target: .japanese,
      action: contextAction,
      selectionContext: nil
    )
    check(
      fallbackPrompt.system.contains("translation engine")
        && !fallbackPrompt.user.contains("<untrusted-context>"),
      "missing context did not fall back to translation",
      failures: &failures
    )

    do {
      _ = try EndpointValidator.validate(
        "http://127.0.0.1:11434/api/chat",
        provider: .ollama
      )
    } catch {
      failures.append("loopback Ollama endpoint was rejected: \(error)")
    }
    do {
      _ = try EndpointValidator.validate("http://api.openai.com/v1", provider: .openAI)
      failures.append("insecure remote HTTP endpoint was accepted")
    } catch {
      // Expected.
    }
    do {
      _ = try EndpointValidator.validate(
        "https://169.254.169.254/latest/meta-data",
        provider: .custom
      )
      failures.append("private metadata endpoint was accepted")
    } catch {
      // Expected.
    }

    let openAI = #"data: {"choices":[{"delta":{"content":"hello"}}]}"#
    check(
      StreamDecoder.content(from: openAI, provider: .openAI) == "hello",
      "OpenAI stream decoding failed",
      failures: &failures
    )
    let openAIReasoning = #"data: {"choices":[{"delta":{"reasoning_content":"private analysis"}}]}"#
    check(
      StreamDecoder.content(from: openAIReasoning, provider: .custom) == nil,
      "OpenAI-compatible reasoning content leaked into visible output",
      failures: &failures
    )
    let geminiThought =
      #"data: {"candidates":[{"content":{"parts":[{"text":"private analysis","thought":true},{"text":"最终答案"}]}}]}"#
    check(
      StreamDecoder.content(from: geminiThought, provider: .gemini) == "最终答案",
      "Gemini thought content leaked into visible output",
      failures: &failures
    )
    do {
      let client = TranslationClient()
      let testPrompt = TranslationPrompt(system: "Return only the answer.", user: "Hello")
      var configuration = ProviderConfiguration(
        provider: .custom,
        endpoint: "https://opencode.ai/zen/go/v1/chat/completions",
        model: "deepseek-v4-flash"
      )
      let disabledRequest = try client.makeRequest(
        prompt: testPrompt,
        configuration: configuration,
        apiKey: "test-key"
      )
      let disabledBody = try JSONSerialization.jsonObject(
        with: disabledRequest.httpBody ?? Data()
      ) as? [String: Any]
      let disabledThinking = disabledBody?["thinking"] as? [String: Any]
      check(
        disabledBody?["reasoning_effort"] as? String == "none"
          && disabledThinking?["type"] as? String == "disabled",
        "OpenCode Go request did not disable model reasoning",
        failures: &failures
      )

      configuration.reasoningEnabled = true
      let enabledRequest = try client.makeRequest(
        prompt: testPrompt,
        configuration: configuration,
        apiKey: "test-key"
      )
      let enabledBody = try JSONSerialization.jsonObject(
        with: enabledRequest.httpBody ?? Data()
      ) as? [String: Any]
      let enabledThinking = enabledBody?["thinking"] as? [String: Any]
      check(
        enabledBody?["reasoning_effort"] as? String == "high"
          && enabledThinking?["type"] as? String == "enabled",
        "OpenCode Go request did not enable model reasoning",
        failures: &failures
      )
    } catch {
      failures.append("OpenCode Go reasoning request test failed: \(error)")
    }
    do {
      let legacyConfiguration = try JSONDecoder().decode(
        ProviderConfiguration.self,
        from: Data(
          #"{"provider":"OpenAI-compatible","endpoint":"https://example.com/v1/chat/completions","model":"example-model","organization":"","apiVersion":"2024-10-21","extendedThinking":false}"#.utf8
        )
      )
      check(
        legacyConfiguration.model == "example-model" && !legacyConfiguration.reasoningEnabled,
        "legacy provider settings did not default reasoning to off",
        failures: &failures
      )
    } catch {
      failures.append("legacy provider settings failed to decode: \(error)")
    }
    let anthropic = #"data: {"delta":{"text":"world"}}"#
    check(
      StreamDecoder.content(from: anthropic, provider: .anthropic) == "world",
      "Anthropic stream decoding failed",
      failures: &failures
    )
    do {
      let openAIModels = try ModelCatalogClient.parseModels(
        Data(#"{"data":[{"id":"gpt-4.1-mini"},{"id":"gpt-4o-mini"}]}"#.utf8),
        provider: .openAI
      )
      let geminiModels = try ModelCatalogClient.parseModels(
        Data(
          #"{"models":[{"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent"]},{"name":"models/embedding-001","supportedGenerationMethods":["embedContent"]}]}"#.utf8
        ),
        provider: .gemini
      )
      let ollamaModels = try ModelCatalogClient.parseModels(
        Data(#"{"models":[{"name":"qwen3:8b"}]}"#.utf8),
        provider: .ollama
      )
      check(
        openAIModels == ["gpt-4.1-mini", "gpt-4o-mini"]
          && geminiModels == ["gemini-2.5-flash"]
          && ollamaModels == ["qwen3:8b"],
        "provider model catalog parsing failed",
        failures: &failures
      )
    } catch {
      failures.append("provider model catalog parsing threw: \(error)")
    }
    do {
      let parsed = try HotKeyParser.parse("⌥⇧F")
      check(
        parsed.keyCode == 3 && parsed.modifiers != 0,
        "shortcut parsing failed",
        failures: &failures
      )
    } catch {
      failures.append("shortcut parsing threw: \(error)")
    }

    let markdown = """
      # Analysis

      **Summary** with `code`.

      - First
      - Second

      | Name | Value |
      | --- | --- |
      | Safe | Yes |

      ```swift
      let value = 1
      ```
      """
    let markdownBlocks = MarkdownParser.parse(markdown)
    check(
      markdownBlocks == [
        .heading(level: 1, text: "Analysis"),
        .paragraph("**Summary** with `code`."),
        .unorderedList(["First", "Second"]),
        .table(headers: ["Name", "Value"], rows: [["Safe", "Yes"]]),
        .code(language: "swift", text: "let value = 1"),
      ],
      "Markdown block parsing failed",
      failures: &failures
    )
    check(
      MarkdownParser.looksLikeMarkdown(markdown)
        && MarkdownParser.looksLikeMarkdown("A **bold** result")
        && !MarkdownParser.looksLikeMarkdown("A plain translated sentence."),
      "Markdown detection failed",
      failures: &failures
    )

    let escapedSpeech = EdgeTTSProtocol.escapedChunks("A&B <C> \"D\" 'E'")
    check(
      escapedSpeech == ["A&amp;B &lt;C&gt; &quot;D&quot; &apos;E&apos;"],
      "Edge TTS SSML escaping failed",
      failures: &failures
    )
    let longSpeech = String(repeating: "日本語 & text ", count: 500)
    let speechChunks = EdgeTTSProtocol.escapedChunks(longSpeech)
    check(
      speechChunks.count > 1
        && speechChunks.allSatisfy { $0.utf8.count <= EdgeTTSProtocol.maximumChunkBytes }
        && speechChunks.allSatisfy { !$0.hasSuffix("&") },
      "Edge TTS safe chunking failed",
      failures: &failures
    )
    let audioHeaders = Data("Content-Type:audio/mpeg\r\nPath:audio\r\n".utf8)
    var audioMessage = Data([UInt8(audioHeaders.count >> 8), UInt8(audioHeaders.count & 0xff)])
    audioMessage.append(audioHeaders)
    audioMessage.append(Data("audio".utf8))
    do {
      let payload = try EdgeTTSProtocol.audioPayload(from: audioMessage)
      check(
        payload == Data("audio".utf8),
        "Edge TTS audio payload parsing failed",
        failures: &failures
      )
    } catch {
      failures.append("Edge TTS audio payload parsing threw: \(error)")
    }
    check(
      LanguageCode.japanese.edgeVoiceIdentifier == "ja-JP-NanamiNeural"
        && LanguageCode.simplifiedChinese.edgeVoiceIdentifier == "zh-CN-XiaoxiaoNeural"
        && AppSettings().resolvedTTSProvider == .edge,
      "Edge TTS defaults are incorrect",
      failures: &failures
    )
    check(
      LanguageDetector.detect("東京") == .japanese
        && LanguageDetector.detect("日本語を勉強する") == .japanese
        && LanguageDetector.detect("設定") == .japanese
        && LanguageDetector.detect("Hello world") == .english
        && LanguageDetector.detect("API response") == .english
        && LanguageDetector.detect("안녕하세요") == .korean,
      "English/Japanese-first language detection failed",
      failures: &failures
    )

    for (section, columns) in AppMetrics.splitColumnMinimums {
      check(
        columns.reduce(0, +) <= AppMetrics.splitColumnBudget,
        "\(section) columns need \(columns.reduce(0, +))pt of a "
          + "\(AppMetrics.splitColumnBudget)pt budget and would be clipped at the "
          + "window's minimum width",
        failures: &failures
      )
    }

    return failures
  }

  private static func check(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    failures: inout [String]
  ) {
    if !condition() {
      failures.append(message)
    }
  }
}
