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
    let translateAction = TranslationAction.builtIns.first { $0.mode == .translate }!
    let japanesePhrasePrompt = PromptBuilder.build(
      text: "モバイル版は、",
      source: .japanese,
      target: .simplifiedChinese,
      action: translateAction
    )
    let japaneseWordPrompt = PromptBuilder.build(
      text: "設定",
      source: .japanese,
      target: .simplifiedChinese,
      action: translateAction
    )
    check(
      !japanesePhrasePrompt.system.contains("dictionary")
        && japanesePhrasePrompt.user.contains("Translate from 日本語")
        && japaneseWordPrompt.system.contains("dictionary"),
      "Japanese phrase and word prompt classification failed",
      failures: &failures
    )
    var overriddenTranslate = translateAction
    overriddenTranslate.rolePrompt = "Translate carefully into ${targetLang}."
    overriddenTranslate.commandPrompt = "Process ${text} from ${sourceLang}."
    let overriddenPrompt = PromptBuilder.build(
      text: "Hello",
      source: .english,
      target: .japanese,
      action: overriddenTranslate
    )
    check(
      overriddenPrompt.system == "Translate carefully into 日本語."
        && overriddenPrompt.user == "Process Hello from English.",
      "built-in action prompt overrides were ignored",
      failures: &failures
    )
    let basePrompt = PromptBuilder.build(
      text: "設定",
      source: .japanese,
      target: .simplifiedChinese,
      action: translateAction
    )
    let followUpPrompt = PromptBuilder.followUp(
      question: "Give me one more example.",
      base: basePrompt,
      answer: "The first answer.",
      turns: [FollowUpTurn(question: "Where is it used?", answer: "Everywhere.")],
      target: .simplifiedChinese
    )
    check(
      followUpPrompt.messages.map(\.role) == [.user, .assistant, .user, .assistant, .user]
        && followUpPrompt.messages.first?.content == basePrompt.user
        && followUpPrompt.messages.last?.content == "Give me one more example."
        && followUpPrompt.system.hasPrefix(basePrompt.system),
      "a follow-up did not carry the exchange it asks about",
      failures: &failures
    )
    let unansweredFollowUp = PromptBuilder.followUp(
      question: "Why?",
      base: basePrompt,
      answer: "The first answer.",
      // The turn currently streaming has no answer yet, and half a turn would
      // read to the model as a question the assistant refused.
      turns: [FollowUpTurn(question: "Where is it used?", answer: "")],
      target: .simplifiedChinese
    )
    check(
      unansweredFollowUp.messages.count == 3,
      "an unanswered follow-up turn was sent as context",
      failures: &failures
    )

    do {
      let client = TranslationClient()
      let openAIBody =
        try JSONSerialization.jsonObject(
          with: client.makeRequest(
            prompt: followUpPrompt,
            configuration: ProviderConfiguration(provider: .openAI),
            apiKey: "test-key"
          ).httpBody ?? Data()
        ) as? [String: Any]
      let openAIMessages = openAIBody?["messages"] as? [[String: String]]
      check(
        openAIMessages?.map({ $0["role"] ?? "" })
          == ["system", "user", "assistant", "user", "assistant", "user"],
        "an OpenAI-compatible request dropped the follow-up exchange",
        failures: &failures
      )

      let anthropicBody =
        try JSONSerialization.jsonObject(
          with: client.makeRequest(
            prompt: followUpPrompt,
            configuration: ProviderConfiguration(
              provider: .anthropic,
              endpoint: ProviderKind.anthropic.defaultEndpoint,
              model: ProviderKind.anthropic.defaultModel
            ),
            apiKey: "test-key"
          ).httpBody ?? Data()
        ) as? [String: Any]
      check(
        (anthropicBody?["messages"] as? [[String: String]])?.count == 5
          && anthropicBody?["system"] as? String == followUpPrompt.system,
        "an Anthropic request dropped the follow-up exchange",
        failures: &failures
      )

      let geminiBody =
        try JSONSerialization.jsonObject(
          with: client.makeRequest(
            prompt: followUpPrompt,
            configuration: ProviderConfiguration(
              provider: .gemini,
              endpoint: ProviderKind.gemini.defaultEndpoint,
              model: ProviderKind.gemini.defaultModel
            ),
            apiKey: "test-key"
          ).httpBody ?? Data()
        ) as? [String: Any]
      let geminiRoles = (geminiBody?["contents"] as? [[String: Any]])?
        .compactMap { $0["role"] as? String }
      check(
        geminiRoles == ["user", "model", "user", "model", "user"],
        "a Gemini request did not map assistant turns to the model role",
        failures: &failures
      )
    } catch {
      failures.append("follow-up request test failed: \(error)")
    }

    do {
      // History written before follow-ups existed has no such field, and one
      // undecodable row fails the whole library load.
      let legacyHistory = Data(
        """
        [{
          "id": "20000000-0000-4000-8000-000000000001",
          "createdAt": "2025-01-01T00:00:00Z",
          "sourceText": "Hello",
          "translatedText": "你好",
          "sourceLanguage": "en",
          "targetLanguage": "zh-Hans",
          "actionName": "Translate",
          "provider": "OpenAI",
          "model": "gpt-4o-mini",
          "favorite": false
        }]
        """.utf8
      )
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let entries = try decoder.decode([HistoryEntry].self, from: legacyHistory)
      check(
        entries.first?.followUps == nil,
        "history saved before follow-ups existed did not decode",
        failures: &failures
      )
    } catch {
      failures.append("legacy history decoding failed: \(error)")
    }

    let customAction = TranslationAction(
      id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
      name: "Custom"
    )
    var actionSettings = AppSettings()
    actionSettings.actionOrder = [customAction.id, translateAction.id]
    actionSettings.hiddenActionIDs = [customAction.id]
    actionSettings.defaultActionID = customAction.id
    actionSettings.setBuiltInOverride(overriddenTranslate)
    let configuredActions = actionSettings.orderedActions(customActions: [customAction])
    check(
      configuredActions.map(\.id).prefix(2) == [customAction.id, translateAction.id],
      "persisted action ordering was not resolved",
      failures: &failures
    )
    check(
      !actionSettings.orderedActions(customActions: [customAction], includingHidden: false)
        .contains(where: { $0.id == customAction.id }),
      "hidden action was exposed on a translation surface",
      failures: &failures
    )
    check(
      actionSettings.resolvedDefaultAction(customActions: [customAction])?.id
        == translateAction.id,
      "hidden default action did not fall back to the first visible action",
      failures: &failures
    )
    check(
      actionSettings.resolvedBuiltInActions.first(where: { $0.id == translateAction.id })?
        .rolePrompt == overriddenTranslate.rolePrompt,
      "built-in action override was not resolved",
      failures: &failures
    )
    actionSettings.setDefaultAction(customAction.id)
    check(
      actionSettings.defaultActionID == customAction.id
        && !actionSettings.hiddenActionIDs.contains(customAction.id),
      "setting a default action did not atomically make it visible",
      failures: &failures
    )

    do {
      let legacyCustomID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
      let legacySettings = Data(
        """
        {
          "sourceLanguage": "en",
          "targetLanguage": "ja",
          "defaultActionID": "\(legacyCustomID.uuidString)",
          "autoTranslate": false,
          "theme": "dark"
        }
        """.utf8
      )
      let migrated = try JSONDecoder().decode(AppSettings.self, from: legacySettings)
      let legacyCustom = TranslationAction(id: legacyCustomID, name: "Legacy Custom")
      check(
        migrated.sourceLanguage == .english
          && migrated.targetLanguage == .japanese
          && !migrated.autoTranslate
          && migrated.theme == .dark,
        "legacy settings values changed during action-settings migration",
        failures: &failures
      )
      check(
        migrated.actionOrder == TranslationAction.defaultOrder
          && migrated.hiddenActionIDs.isEmpty
          && migrated.builtInActionOverrides.isEmpty
          && migrated.selectionPanelPlacement == .nearPointer
          && migrated.selectionPanelPosition == nil,
        "legacy settings did not receive safe action-presentation defaults",
        failures: &failures
      )
      check(
        migrated.defaultActionID == legacyCustomID
          && migrated.resolvedDefaultAction(customActions: [legacyCustom])?.id == legacyCustomID,
        "legacy custom default was not preserved until custom actions loaded",
        failures: &failures
      )

      var persisted = migrated
      persisted.selectionPanelPlacement = .fixed
      persisted.selectionPanelPosition = SelectionPanelPosition(x: 320, y: 180)
      persisted.actionOrder = [legacyCustomID, translateAction.id]
      persisted.hiddenActionIDs = [
        TranslationAction.builtIns.first { $0.mode == .polishing }!.id
      ]
      persisted.setBuiltInOverride(overriddenTranslate)
      let roundTripped = try JSONDecoder().decode(
        AppSettings.self,
        from: JSONEncoder().encode(persisted)
      )
      check(
        roundTripped == persisted,
        "action settings changed during serialized persistence round trip",
        failures: &failures
      )
      check(
        roundTripped.orderedActions(customActions: [legacyCustom]).map(\.id).prefix(2)
          == [legacyCustomID, translateAction.id]
          && roundTripped.resolvedBuiltInActions.first(where: {
            $0.id == translateAction.id
          })?.commandPrompt == overriddenTranslate.commandPrompt,
        "persisted order or built-in override was not restored after decoding",
        failures: &failures
      )
    } catch {
      failures.append("action settings migration or round trip threw: \(error)")
    }
    let visibleFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    let panelSize = CGSize(width: 480, height: 440)
    let pointerFrame = SelectionPanelGeometry.frameNearPointer(
      size: panelSize,
      pointer: CGPoint(x: 1_430, y: 890),
      visibleFrame: visibleFrame
    )
    let restoredFrame = SelectionPanelGeometry.frameAtRememberedOrigin(
      size: panelSize,
      origin: CGPoint(x: 2_000, y: -500),
      visibleFrame: visibleFrame
    )
    check(
      visibleFrame.insetBy(dx: 10, dy: 10).contains(pointerFrame)
        && visibleFrame.insetBy(dx: 10, dy: 10).contains(restoredFrame),
      "selection pop-up placement escaped the visible display",
      failures: &failures
    )
    let fragmentedContext = SelectionContextMatcher.context(
      matching: "selected phrase",
      in: ["The paragraph starts before the selected", "phrase and continues after it."]
    )
    check(
      fragmentedContext?.contains("before the selected phrase and continues") == true,
      "fragmented accessibility text was not reconstructed around the selection",
      failures: &failures
    )
    check(
      SelectionContextMatcher.context(
        matching: "repeated",
        in: ["The repeated word appears here.", "Another repeated word appears later."]
      ) == nil,
      "ambiguous accessibility context did not fail closed",
      failures: &failures
    )
    let conflictingSelection = SelectionEvidenceResolver.resolve(
      accessibilityText: "nst anyo",
      copiedText: "first"
    )
    check(
      conflictingSelection.text == "first"
        && !conflictingSelection.accessibilityMatches,
      "clipboard selection did not override conflicting accessibility evidence",
      failures: &failures
    )
    let matchingSelection = SelectionEvidenceResolver.resolve(
      accessibilityText: "  selected\nphrase ",
      copiedText: "selected phrase"
    )
    check(
      matchingSelection.text == "selected phrase"
        && matchingSelection.accessibilityMatches,
      "equivalent clipboard and accessibility evidence did not reconcile",
      failures: &failures
    )
    let accessibilityOnlySelection = SelectionEvidenceResolver.resolve(
      accessibilityText: "native selection",
      copiedText: nil
    )
    check(
      accessibilityOnlySelection.text == "native selection"
        && accessibilityOnlySelection.accessibilityMatches,
      "accessibility selection did not survive an unavailable copy fallback",
      failures: &failures
    )
    let booksContext = SelectionContextMatcher.context(
      matching: conflictingSelection.text,
      in: [
        "We are not measuring you against anyone.",
        "You should feel free to read it on your own first. Many people think differently.",
      ]
    )
    check(
      booksContext?.contains("own first. Many people") == true,
      "reconciled selection did not locate the correct accessibility context",
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
    // A stream that stops early still ends cleanly on the wire, so the only
    // evidence the answer is a fragment is the provider's own stop reason.
    let openAITruncated =
      #"data: {"choices":[{"delta":{"content":"half"},"finish_reason":"length"}]}"#
    let openAITruncatedEvent = StreamDecoder.event(from: openAITruncated, provider: .openAI)
    check(
      openAITruncatedEvent.text == "half" && openAITruncatedEvent.truncation != nil,
      "OpenAI truncated stream was not detected",
      failures: &failures
    )
    check(
      StreamDecoder.event(from: openAI, provider: .openAI).truncation == nil
        && StreamDecoder.event(
          from: #"data: {"choices":[{"delta":{"content":"done"},"finish_reason":"stop"}]}"#,
          provider: .openAI
        ).truncation == nil,
      "a completed OpenAI stream was reported as truncated",
      failures: &failures
    )
    check(
      StreamDecoder.event(
        from: #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#,
        provider: .anthropic
      ).truncation != nil,
      "Anthropic truncated stream was not detected",
      failures: &failures
    )
    check(
      StreamDecoder.event(
        from: #"data: {"candidates":[{"finishReason":"MAX_TOKENS"}]}"#,
        provider: .gemini
      ).truncation != nil
        && StreamDecoder.event(from: geminiThought, provider: .gemini).truncation == nil,
      "Gemini truncated stream detection failed",
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
      let disabledBody =
        try JSONSerialization.jsonObject(
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
      let enabledBody =
        try JSONSerialization.jsonObject(
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
          #"{"provider":"OpenAI-compatible","endpoint":"https://example.com/v1/chat/completions","model":"example-model","organization":"","apiVersion":"2024-10-21","extendedThinking":false}"#
            .utf8
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
          #"{"models":[{"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent"]},{"name":"models/embedding-001","supportedGenerationMethods":["embedContent"]}]}"#
            .utf8
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
    check(
      TranslationSourceResolver.resolve(
        "モバイル版は、",
        configuredSource: .english,
        inputSource: .selection
      ) == .japanese
        && TranslationSourceResolver.resolve(
          "日本語を勉強する",
          configuredSource: .english,
          inputSource: .ocr
        ) == .japanese
        && TranslationSourceResolver.resolve(
          "日本語",
          configuredSource: .english,
          inputSource: .manual
        ) == .english
        && TranslationSourceResolver.resolve(
          "Hello",
          configuredSource: .english,
          inputSource: .history,
          restoredSource: .japanese
        ) == .japanese,
      "translation source policy failed",
      failures: &failures
    )

    // A side-by-side section stops stacking at `AppBreakpoints.regular`. If its
    // columns need more than that, the layout would be clipped in the band
    // between the breakpoint and the width the columns actually require —
    // which reads as content cut off at both edges rather than as a too-small
    // window. Raising a column minimum without raising the breakpoint fails
    // here instead of shipping.
    let splitBudget = AppBreakpoints.regular - AppMetrics.splitHandleWidth
    for (section, columns) in AppMetrics.splitColumnMinimums {
      check(
        columns.reduce(0, +) <= splitBudget,
        "\(section) columns need \(columns.reduce(0, +))pt of a "
          + "\(splitBudget)pt budget and would be clipped between the stacking "
          + "breakpoint and the width they need",
        failures: &failures
      )
    }

    // The narrowest window must still leave the detail column enough room for
    // a section's single-column layout.
    check(
      AppMetrics.windowMinWidth - AppMetrics.sidebarRailWidth >= AppMetrics.paneMinWidth,
      "the detail column is narrower than one pane at the window's minimum width",
      failures: &failures
    )

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
