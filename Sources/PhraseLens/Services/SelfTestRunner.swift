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
    // Every built-in ships an editable template, and `PromptBuilder` fills the
    // same template in at send time. A variable typo would otherwise reach a
    // provider as literal `${targetLang}`, and an action that never names the
    // reader's language is how an answer comes back in the wrong one.
    for builtIn in TranslationAction.builtIns {
      let filled = PromptBuilder.build(
        text: "sample phrase",
        source: .english,
        target: .simplifiedChinese,
        action: builtIn,
        selectionContext: "A paragraph that contains the sample phrase and continues."
      )
      check(
        !filled.system.contains("${") && !filled.user.contains("${"),
        "\(builtIn.name) prompt left a template variable unsubstituted",
        failures: &failures
      )
      check(
        // Polish deliberately works in the language of the text itself.
        builtIn.mode == .polishing
          || filled.system.contains("简体中文") || filled.user.contains("简体中文"),
        "\(builtIn.name) prompt never names the language to answer in",
        failures: &failures
      )
      // These three end their command prompt with the material itself, and a
      // model that reads a wall of source-language text last answers in that
      // language. The closing line naming the target keeps the instruction
      // the answer has to follow in view after the quoted text.
      if let mode = builtIn.mode,
        [ActionMode.explainContext, .summarize, .analyze].contains(mode)
      {
        check(
          String(filled.user.suffix(200)).contains("简体中文"),
          "\(builtIn.name) prompt ends on source material instead of the answer language",
          failures: &failures
        )
      }
    }
    let compareAction = TranslationAction.builtIns.first { $0.mode == .compareSynonyms }!
    let comparePrompt = PromptBuilder.build(
      text: "brave",
      source: .english,
      target: .simplifiedChinese,
      action: compareAction
    )
    check(
      comparePrompt.user.contains("`brave`") && comparePrompt.user.contains("Example:"),
      "Compare Synonyms lost the headword or its mandatory example line",
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
    // Translate keeps its Markdown switch off because a translation is plain
    // text, but a single word takes the dictionary branch and answers in
    // Markdown. Rendering that literally is what shows a reader raw `**`.
    check(
      PromptBuilder.expectsMarkdown(translateAction, text: "設定")
        && !PromptBuilder.expectsMarkdown(translateAction, text: "設定を開く必要がある。")
        && !PromptBuilder.expectsMarkdown(translateAction, text: "設定", writing: true)
        && !PromptBuilder.expectsMarkdown(overriddenTranslate, text: "設定")
        && PromptBuilder.expectsMarkdown(contextAction, text: "A short sentence."),
      "Markdown rendering did not follow what the request asked the model for",
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

    // OAuth / Codex authentication invariants
    let verifier = OpenAIOAuthService.shared.generateCodeVerifier()
    let challenge = OpenAIOAuthService.shared.generateCodeChallenge(from: verifier)
    check(
      !verifier.isEmpty && !challenge.isEmpty && verifier != challenge,
      "PKCE code verifier and challenge generation failed",
      failures: &failures
    )
    check(
      ProviderKind.openAI.supportsOAuth && ProviderKind.chatGPT.supportsOAuth
        && !ProviderKind.anthropic.supportsOAuth && !ProviderKind.gemini.supportsOAuth,
      "ProviderKind OAuth capability flags failed",
      failures: &failures
    )
    let expiredCreds = OAuthCredentials(
      accessToken: "test-token",
      refreshToken: "test-refresh",
      expiresAt: Date().addingTimeInterval(-100)
    )
    let validCreds = OAuthCredentials(
      accessToken: "test-token",
      refreshToken: "test-refresh",
      expiresAt: Date().addingTimeInterval(3600)
    )
    check(
      expiredCreds.isExpired && !validCreds.isExpired,
      "OAuthCredentials expiration check failed",
      failures: &failures
    )
    let oauthConfig = ProviderConfiguration(
      provider: .openAI,
      authMode: .oauthCodex
    )
    if let encoded = try? JSONEncoder().encode(oauthConfig),
      let decoded = try? JSONDecoder().decode(ProviderConfiguration.self, from: encoded)
    {
      check(
        decoded.authMode == .oauthCodex,
        "ProviderConfiguration authMode serialization failed",
        failures: &failures
      )
    } else {
      check(false, "ProviderConfiguration encoding/decoding threw error", failures: &failures)
    }

    // Codex Responses API streaming tests
    let responsesDeltaLine = #"data: {"type":"response.text.delta","delta":"translated text"}"#
    let responsesDeltaEvent = StreamDecoder.responsesEvent(from: responsesDeltaLine)
    check(
      responsesDeltaEvent.text == "translated text" && responsesDeltaEvent.truncation == nil,
      "Responses API text delta decoding failed",
      failures: &failures
    )

    let responsesItemDeltaLine = #"data: {"type":"response.output_item.delta","delta":{"content":[{"type":"text","text":"chunk"}]}}"#
    let responsesItemDeltaEvent = StreamDecoder.responsesEvent(from: responsesItemDeltaLine)
    check(
      responsesItemDeltaEvent.text == "chunk" && responsesItemDeltaEvent.truncation == nil,
      "Responses API output item delta decoding failed",
      failures: &failures
    )

    let responsesDoneLine = #"data: {"type":"response.done","response":{"status":"completed"}}"#
    let responsesDoneEvent = StreamDecoder.responsesEvent(from: responsesDoneLine)
    check(
      responsesDoneEvent.text == nil && responsesDoneEvent.truncation == nil,
      "Responses API completed done event failed",
      failures: &failures
    )

    let responsesIncompleteLine = #"data: {"type":"response.done","response":{"status":"incomplete","status_details":{"reason":"length"}}}"#
    let responsesIncompleteEvent = StreamDecoder.responsesEvent(from: responsesIncompleteLine)
    check(
      responsesIncompleteEvent.truncation != nil,
      "Responses API incomplete truncation detection failed",
      failures: &failures
    )

    // Codex model parsing follows the backend's own ordering and visibility:
    // `priority` ranks the list, `visibility` hides internals such as
    // codex-auto-review, and the older boolean spellings still work.
    do {
      let codexModelsJSON = Data(
        #"""
        {"models":[
          {"slug":"gpt-5.4","visibility":"list","priority":16},
          {"slug":"gpt-5.6-sol","visibility":"list","priority":1},
          {"slug":"codex-auto-review","visibility":"hide","priority":43},
          {"slug":"gpt-5.4-mini","visibility":"list","priority":23},
          {"slug":"gpt-5.9-internal","hidden":true}
        ]}
        """#
          .utf8
      )
      let parsedCodexModels = try ModelCatalogClient.parseCodexModels(codexModelsJSON)
      check(
        parsedCodexModels == ["gpt-5.6-sol", "gpt-5.4", "gpt-5.4-mini"],
        "Codex model catalog parsing, ordering or filtering failed",
        failures: &failures
      )

      // A row with no priority sorts last rather than first, so an unfamiliar
      // catalog shape cannot push an unknown model to the top of the picker.
      check(
        ModelCatalogClient.orderedCodexSlugs([
          ("gpt-later", Int.max), ("gpt-first", 2), ("gpt-first", 9),
        ]) == ["gpt-first", "gpt-later"],
        "Codex slug ordering did not rank by priority or drop duplicates",
        failures: &failures
      )
    } catch {
      failures.append("Codex model catalog parsing threw: \(error)")
    }

    // Credentials round-trip through the app's own encrypted file rather than
    // the Keychain, so a provider switch never asks for a password.
    do {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("phraselens-selftest-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = CredentialStore(directory: directory, filename: "credentials.json")
      let secret = "sk-selftest-\(UUID().uuidString)"
      try store.setAPIKey(secret, for: .openAI)
      try store.setAPIKey("  \(secret)-anthropic  ", for: .anthropic)
      let expiry = Date().addingTimeInterval(3600)
      try store.setOAuthCredentials(
        OAuthCredentials(
          accessToken: "access",
          refreshToken: "refresh",
          expiresAt: expiry,
          email: "user@example.com",
          accountId: "account"
        ),
        for: .openAI
      )

      // A second instance reads what the first wrote, which is what an app
      // relaunch does.
      let reopened = CredentialStore(directory: directory, filename: "credentials.json")
      check(
        reopened.apiKey(for: .openAI) == secret
          && reopened.apiKey(for: .anthropic) == "\(secret)-anthropic"
          && reopened.apiKey(for: .gemini).isEmpty
          && reopened.oauthCredentials(for: .openAI)?.email == "user@example.com"
          && reopened.oauthCredentials(for: .anthropic) == nil,
        "credential store did not persist credentials per provider",
        failures: &failures
      )

      let fileURL = directory.appendingPathComponent("credentials.json")
      let raw = (try? Data(contentsOf: fileURL)) ?? Data()
      let permissions =
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.posixPermissions]
        as? NSNumber
      check(
        !(String(data: raw, encoding: .utf8) ?? "").contains(secret)
          && permissions?.int16Value == 0o600,
        "credential file stored a key in the clear or with loose permissions",
        failures: &failures
      )

      try store.setAPIKey("", for: .openAI)
      check(
        CredentialStore(directory: directory, filename: "credentials.json")
          .apiKey(for: .openAI).isEmpty,
        "clearing an API key did not remove it from the credential file",
        failures: &failures
      )

      // A provider that has already been dealt with is never offered the
      // Keychain import again, which is what keeps the password panel away
      // from ordinary provider switching.
      let migrationDefaults = UserDefaults(
        suiteName: "phraselens-selftest-\(UUID().uuidString)"
      )!
      migrationDefaults.set(true, forKey: "credential-keychain-migration-v1.OpenAI")
      let migrated = CredentialStore(
        directory: directory,
        filename: "credentials.json",
        defaults: migrationDefaults
      )
      check(
        !migrated.hasImportableLegacyCredentials(for: .openAI)
          && migrated.importLegacyKeychainCredentials(for: .openAI) == .none,
        "a migrated provider was offered the Keychain import again",
        failures: &failures
      )
    } catch {
      failures.append("credential store threw: \(error)")
    }

    // Catalogs are cached per thing that can serve a different list.
    let openAIKeyed = ModelCatalogStore.key(
      for: ProviderConfiguration(provider: .openAI, authMode: .apiKey)
    )
    let openAIOAuthKeyed = ModelCatalogStore.key(
      for: ProviderConfiguration(provider: .openAI, authMode: .oauthCodex)
    )
    let gatewayA = ModelCatalogStore.key(
      for: ProviderConfiguration(provider: .custom, endpoint: "https://a.example/v1/chat/completions")
    )
    let gatewayB = ModelCatalogStore.key(
      for: ProviderConfiguration(provider: .custom, endpoint: "https://b.example/v1/chat/completions")
    )
    check(
      openAIKeyed != openAIOAuthKeyed && gatewayA != gatewayB
        && gatewayA
          == ModelCatalogStore.key(
            for: ProviderConfiguration(
              provider: .custom,
              endpoint: " https://A.example/v1/chat/completions "
            )
          ),
      "model catalog cache keys do not separate providers, auth modes and endpoints",
      failures: &failures
    )

    do {
      // Gemini pages its catalog; only following the page token lists more than
      // the first page's worth of models.
      let firstPage = Data(
        #"{"models":[{"name":"models/gemini-3.1-flash","supportedGenerationMethods":["generateContent"]}],"nextPageToken":"page-2"}"#
          .utf8
      )
      let lastPage = Data(
        #"{"models":[{"name":"models/gemini-3.1-pro","supportedGenerationMethods":["generateContent"]}]}"#
          .utf8
      )
      let merged = ModelCatalogClient.deduplicated(
        try ModelCatalogClient.parseModels(firstPage, provider: .gemini)
          + ModelCatalogClient.parseModels(lastPage, provider: .gemini)
      )
      check(
        ModelCatalogClient.parseNextPageToken(firstPage) == "page-2"
          && ModelCatalogClient.parseNextPageToken(lastPage) == nil
          && merged == ["gemini-3.1-flash", "gemini-3.1-pro"],
        "Gemini catalog pagination handling failed",
        failures: &failures
      )

      // Dated catalogs lead with the newest model; undated ones keep the order
      // the provider chose.
      let dated = try ModelCatalogClient.parseModels(
        Data(
          #"{"data":[{"id":"old-model","created":1600000000},{"id":"new-model","created":1700000000}]}"#
            .utf8
        ),
        provider: .groq
      )
      let undated = try ModelCatalogClient.parseModels(
        Data(#"{"data":[{"id":"b-model"},{"id":"a-model"}]}"#.utf8),
        provider: .custom
      )
      check(
        dated == ["new-model", "old-model"] && undated == ["b-model", "a-model"],
        "model catalog ordering failed",
        failures: &failures
      )

      // Providers list models no chat request can use next to the usable ones.
      let mixed = try ModelCatalogClient.parseModels(
        Data(
          #"{"data":[{"id":"llama-3.3-70b"},{"id":"text-embedding-3-large"},{"id":"whisper-large-v3"},{"id":"rerank-v3.5"},{"id":"ft:custom-model"}]}"#
            .utf8
        ),
        provider: .groq
      )
      check(
        mixed == ["llama-3.3-70b"],
        "non-chat models were not filtered out of the catalog",
        failures: &failures
      )
    } catch {
      failures.append("model catalog parsing threw: \(error)")
    }

    // TranslationClient OAuth request creation test
    do {
      let client = TranslationClient()
      let testPrompt = TranslationPrompt(system: "Translate.", user: "Hello")
      let codexReq = try client.makeRequest(
        prompt: testPrompt,
        configuration: ProviderConfiguration(provider: .openAI, authMode: .oauthCodex),
        apiKey: "mock-access-token",
        accountId: "mock-account-123"
      )
      check(
        codexReq.url?.absoluteString == CodexBackend.responsesEndpoint
          && codexReq.value(forHTTPHeaderField: "originator") == "codex_cli_rs"
          && codexReq.value(forHTTPHeaderField: "chatgpt-account-id") == "mock-account-123"
          && codexReq.value(forHTTPHeaderField: "Authorization") == "Bearer mock-access-token",
        "TranslationClient Codex OAuth request creation failed",
        failures: &failures
      )
    } catch {
      failures.append("TranslationClient Codex OAuth request creation threw: \(error)")
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
