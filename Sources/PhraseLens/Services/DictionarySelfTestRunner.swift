import Foundation

/// Async regression checks using the app's existing standalone self-test pattern.
/// AppModel integration uses isolated stores and disables system integrations;
/// these checks do not register hotkeys, read credentials, or save user data.
enum DictionarySelfTestRunner {
  static func run() async -> [String] {
    var failures: [String] = []
    func check(_ passed: Bool, _ message: String) { if !passed { failures.append(message) } }
    check(DictionaryLanguageResolver.candidates(text: "食べる", context: nil, override: "auto") == ["ja"], "Kana detection")
    check(DictionaryLanguageResolver.candidates(text: "한국어", context: nil, override: "auto") == ["ko"], "Hangul detection")
    let han = DictionaryLanguageResolver.candidates(text: "手紙", context: nil, override: "auto")
    check(han.contains("ja") && han.contains("zh"), "Han ambiguity lost")
    check(DictionaryLanguageResolver.candidates(text: "手紙", context: "彼は手紙を書いた。", override: "zh") == ["zh"], "Explicit source override ignored")
    check(DictionaryLanguageResolver.candidates(text: "bonjour", context: "Bonjour, je suis très heureux de vous rencontrer.", override: "auto").contains("fr"), "French detection")
    check(DictionaryLanguageResolver.candidates(text: "😀", context: nil, override: "auto").isEmpty, "Emoji guessed as language")
    check(!ExactLexicalProcessor().candidates(for: "côté").contains { $0.text == "cote" }, "Diacritics erased")
    check(JapaneseLexicalProcessor().candidates(for: "食べました").contains { $0.text == "食べます" }, "Polite form normalization")
    check(JapaneseLexicalProcessor().candidates(for: "ｶﾀｶﾅ").contains { $0.text == "カタカナ" }, "Width normalization")
    for word in ["hello", "bank", "食べる", "見どころ", "图书馆", "東京", "côté", "ｶﾀｶﾅ"] {
      check(DictionaryLanguageResolver.isLookupCandidate(word), "Single word rejected: \(word)")
    }
    for sentence in ["", "😀", "1234", "これは文です。", "これは文です", "資料館の展示と見どころ", "今天很好", "take it easy", "hello world", "hello.", "hello\nworld"] {
      check(!DictionaryLanguageResolver.isLookupCandidate(sentence), "Sentence/non-word exposed dictionary tab: \(sentence)")
    }
    check(DictionaryLanguageResolver.canProbeLexicalEntry("食べました"), "Inflection cannot be verified by dictionary")
    check(DictionaryLanguageResolver.canProbeLexicalEntry("資料館"), "Compound cannot be verified by dictionary")
    do {
      let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
      check(settings.dictionaryEnabled && settings.dictionaryDefinitionLanguage == "zh", "Legacy settings migration")
      let original = VocabularyEntry(word: "bank", explanation: "old AI", sourceLanguage: .english, targetLanguage: .simplifiedChinese)
      let restored = try JSONDecoder().decode(VocabularyEntry.self, from: JSONEncoder().encode(original))
      check(restored.id == original.id && restored.dictionarySnapshot == nil, "Legacy vocabulary migration")
      let history = HistoryEntry(sourceText: "bank", translatedText: "old", sourceLanguage: .english,
        targetLanguage: .simplifiedChinese, actionName: "Translate", provider: .openAI, model: "test")
      let decoded = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(history))
      check(decoded.provider == .openAI && decoded.dictionarySnapshot == nil, "Legacy history migration")

      let fixture = DictionaryFixtureProvider()
      let registry = DictionaryRegistry(providers: [fixture])
      let result = try await registry.lookup(.init(text: "bonjour", sourceOverride: "fr", definitionLanguage: "en"))
      check(result.matches.first?.entry.senses.first?.glosses == ["hello"], "Extensible French-English fixture")
      let german = try await registry.lookup(.init(text: "bonjour", sourceOverride: "fr", definitionLanguage: "de"))
      check(german.matches.first?.entry.senses.first?.glosses == ["hallo"], "Provider did not receive requested definition language")
      let unsupported = try await registry.lookup(.init(text: "bonjour", sourceOverride: "fr", definitionLanguage: "zh"))
      check(!unsupported.supportsPair && unsupported.matches.isEmpty, "Wrong definition language silently substituted")
      let missing = SQLiteDictionaryProvider(databaseURL: URL(fileURLWithPath: "/nonexistent/phraselens.sqlite"), descriptor: fixture.descriptor)
      let partial = try await DictionaryRegistry(providers: [missing, fixture]).lookup(.init(text: "bonjour", sourceOverride: "fr", definitionLanguage: "en"))
      check(partial.matches.count == 1 && partial.notices.count == 1, "Provider failure hid valid results")
      let slow = DictionarySlowFixtureProvider()
      let task = Task { try await DictionaryRegistry(providers: [slow]).lookup(.init(text: "bonjour", sourceOverride: "fr", definitionLanguage: "en")) }
      // Wait until the request is inside the provider, then cancel it.
      while !(await slow.started) { await Task.yield() }
      task.cancel()
      do { _ = try await task.value; failures.append("Cancelled provider returned results") }
      catch is CancellationError { }

      if let match = result.matches.first {
        let snapshot = DictionarySnapshot(query: "bonjour", definitionLanguage: "en", matches: [match])
        let entry = VocabularyEntry(word: "bonjour", explanation: match.plainText, sourceLanguage: .french, targetLanguage: .english, dictionarySnapshot: snapshot)
        let ai = VocabularyEntry(word: "bonjour", explanation: "AI", sourceLanguage: .french, targetLanguage: .english)
        check(!entry.matchesIdentity(of: ai), "Dictionary overwrote AI vocabulary")
        check(try JSONDecoder().decode(VocabularyEntry.self, from: JSONEncoder().encode(entry)).dictionarySnapshot == snapshot, "Provenance lost on round trip")
      }
      let bundled = try BundledDictionaries.registry()
      if let provider = bundled.providers.first as? SQLiteDictionaryProvider {
        var wrong = provider.descriptor
        wrong.revision = "incorrect-revision"
        let mismatched = SQLiteDictionaryProvider(databaseURL: provider.databaseURL, descriptor: wrong)
        do {
          _ = try await mismatched.lookup([.init(text: "hello", reason: "exact")], sourceLanguage: "en", definitionLanguage: "zh")
          failures.append("Mismatched pack revision accepted")
        } catch DictionaryDataError.invalid { }
      }
      for (query, source, gloss) in [("食べる", "ja", "吃"), ("食べました", "ja", "吃"), ("hello", "en", "你好"), ("went", "en", "去"), ("running", "en", "跑")] {
        let found = try await bundled.lookup(.init(text: query, sourceOverride: source))
        check(found.notices.isEmpty, "Pack errors for \(query): \(found.notices)")
        check(found.matches.flatMap { $0.entry.senses.flatMap(\.glosses) }.contains { $0.contains(gloss) }, "Real-data semantic fixture missing: \(query)")
        check(found.matches.allSatisfy { $0.entry.definitionLanguage == "zh" }, "Wrong definition language: \(query)")
      }
      let phrase = try await bundled.lookup(.init(text: "お疲れ様", sourceOverride: "ja"))
      check(!phrase.matches.isEmpty, "Japanese phrase lookup")
      let normalized = try await bundled.lookup(.init(text: "ｶﾀｶﾅ", sourceOverride: "ja"))
      check(!normalized.matches.isEmpty, "Half-width Katakana lookup")
      let homophones = try await bundled.lookup(.init(text: "はし", sourceOverride: "ja"))
      check(Set(homophones.matches.map { $0.entry.headword }).count >= 2, "Homophone readings collapsed")
      let sql = try await bundled.lookup(.init(text: "' OR 1=1 --", sourceOverride: "en"))
      check(sql.matches.isEmpty, "SQL input escaped binding")
      let absent = try await bundled.lookup(.init(text: "xyzzynotarealwordabc", sourceOverride: "en"))
      check(absent.supportsPair && absent.matches.isEmpty, "Absent word conflated with unsupported pair")
    } catch { failures.append("Dictionary check threw: \(error)") }
    failures += await appIntegration()
    return failures
  }
}

private struct DictionaryFixtureProvider: DictionaryProvider {
  let descriptor = DictionaryDescriptor(id: "fixture", name: "Fixture", revision: "1", sourceLanguages: ["fr"],
    definitionLanguages: ["en", "de"], attribution: "Test fixture", license: "CC0", licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/",
    canPersist: true, canUseWithAI: true)
  func lookup(_ candidates: [LexicalCandidate], sourceLanguage: String, definitionLanguage: String) async throws -> [DictionaryMatch] {
    try Task.checkCancellation()
    guard candidates.contains(where: { $0.text == "bonjour" }) else { return [] }
    return [.init(entry: .init(id: "bonjour", headword: "bonjour", sourceLanguage: sourceLanguage, definitionLanguage: definitionLanguage,
      readings: [], senses: [.init(id: "1", glosses: [definitionLanguage == "de" ? "hallo" : "hello"], labels: [])], sourceURL: "https://example.com/bonjour"),
      dictionary: descriptor, matchedForm: "bonjour", matchKind: "headword")]
  }
}

private actor DictionarySlowFixtureProvider: DictionaryProvider {
  nonisolated let descriptor = DictionaryFixtureProvider().descriptor
  private(set) var started = false
  func lookup(_ candidates: [LexicalCandidate], sourceLanguage: String, definitionLanguage: String) async throws -> [DictionaryMatch] {
    started = true
    try await Task.sleep(for: .seconds(30))
    return []
  }
}

extension DictionarySelfTestRunner {
  @MainActor
  static func appIntegration() async -> [String] {
    var failures: [String] = []
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhraseLens-dictionary-test-\(UUID())")
    let suite = "PhraseLens-dictionary-test-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let credentials = CredentialStore(directory: directory, defaults: defaults)
    let settings = SettingsStore(defaults: defaults, credentials: credentials, loadStoredCredentials: false)
    settings.settings.dictionaryDefinitionLanguage = "en"
    let library = LibraryStore(directory: directory)
    let late = DictionaryLateFixtureProvider()
    let model = AppModel(settingsStore: settings, library: library,
      dictionaryRegistry: DictionaryRegistry(providers: [late]), integrateWithSystem: false)
    model.inputText = "old"
    model.inputSource = .selection
    model.setDictionarySource("fr")
    while !(await late.started) { await Task.yield() }
    model.inputText = "bonjour"
    model.setDictionarySource("fr")
    await late.release()
    for _ in 0..<500 {
      if !model.history.isEmpty { break }
      try? await Task.sleep(for: .milliseconds(2))
    }
    if model.dictionaryMatches.first?.entry.headword != "bonjour" { failures.append("Stale dictionary request replaced current lookup") }
    if model.history.count != 1 || model.history.first?.sourceText != "bonjour" { failures.append("Obsolete lookup written to history") }
    if !model.outputText.isEmpty || model.isTranslating { failures.append("Dictionary lookup used AI output") }
    if let match = model.dictionaryMatches.first {
      model.saveDictionaryEntry(match)
      for _ in 0..<500 {
        if !model.vocabulary.isEmpty { break }
        try? await Task.sleep(for: .milliseconds(2))
      }
      do {
        let saved = try await library.vocabulary()
        if saved.first?.dictionarySnapshot?.matches.first?.id != match.id { failures.append("Dictionary save lost source") }
        let id = saved.first?.id
        model.saveDictionaryEntry(match)
        // An actor read after the save task starts observes its completed write.
        await Task.yield()
        let again = try await library.vocabulary()
        if again.count != 1 || again.first?.id != id { failures.append("Dictionary resave changed identity") }
      } catch { failures.append("Dictionary save failed: \(error)") }
    }
    if let history = model.history.first {
      model.clear()
      model.restore(history, showWindow: false)
      if !model.dictionaryVisible || model.dictionaryMatches.isEmpty || !model.outputText.isEmpty {
        failures.append("Dictionary history restored as AI text")
      }
    }
    let cachedIDs = model.dictionaryMatches.map(\.id)
    let historyCount = model.history.count
    model.outputText = "Cached AI translation"
    model.selectResultTab(.translation)
    if model.dictionaryVisible || model.currentResultText != "Cached AI translation" || model.isTranslating {
      failures.append("Translation tab did not reuse its cached result")
    }
    model.selectResultTab(.dictionary)
    if !model.dictionaryVisible || model.dictionaryMatches.map(\.id) != cachedIDs
      || model.currentResultText == "Cached AI translation" || !model.currentResultText.contains("Test fixture") {
      failures.append("Dictionary tab/copy used the hidden AI result")
    }
    if model.history.count != historyCount { failures.append("Tab switch duplicated dictionary history") }
    model.outputText = ""
    model.explainDictionaryWithAI()
    for _ in 0..<500 {
      if !model.isTranslating { break }
      try? await Task.sleep(for: .milliseconds(2))
    }
    if model.dictionaryVisible || model.dictionaryMatches.isEmpty || model.errorMessage != TranslationError.missingAPIKey.localizedDescription {
      failures.append("AI failure erased dictionary or bypassed credential check")
    }
    settings.settings.dictionaryDefinitionLanguage = "ja"
    if model.dictionaryVisible { failures.append("Definition setting unexpectedly switched result tabs") }
    model.selectResultTab(.dictionary)
    if model.visibleErrorMessage != nil { failures.append("AI failure leaked into dictionary tab") }
    for _ in 0..<500 {
      if case .result(let result) = model.dictionaryState, result.request.definitionLanguage == "ja" { break }
      try? await Task.sleep(for: .milliseconds(2))
    }
    if case .result(let result) = model.dictionaryState {
      if result.supportsPair || !result.matches.isEmpty { failures.append("Definition-language change kept stale result") }
    } else { failures.append("Definition-language change did not rerun lookup") }
    model.outputText = "Keep this AI translation"
    if model.canCopyResult { failures.append("Empty dictionary copied hidden translation") }
    model.selectResultTab(.translation)
    if model.outputText != "Keep this AI translation" { failures.append("Dictionary refresh erased cached AI output") }
    model.clear()
    if model.dictionaryVisible || !model.dictionaryMatches.isEmpty { failures.append("Clear left dictionary results visible") }
    model.inputSource = .manual
    model.inputText = "bonjour"
    model.setDictionarySource("auto")
    settings.settings.sourceLanguage = .japanese
    for _ in 0..<500 {
      if case .result(let result) = model.dictionaryState, result.request.sourceOverride == "ja" { break }
      try? await Task.sleep(for: .milliseconds(2))
    }
    if case .result(let result) = model.dictionaryState, result.request.sourceOverride == "ja" { }
    else { failures.append("Source-language change kept stale dictionary state") }
    model.inputText = "資料館の展示と見どころ"
    model.translate()
    for _ in 0..<500 {
      if !model.isLookingUpDictionary && !model.isTranslating { break }
      try? await Task.sleep(for: .milliseconds(2))
    }
    if model.dictionaryAvailable || model.dictionaryVisible || model.selectedResultTab != .translation
      || model.errorMessage != TranslationError.missingAPIKey.localizedDescription {
      failures.append("Screenshot title did not fall through to translation")
    }
    model.inputText = "hello world"
    model.translate()
    if model.dictionaryAvailable || !model.isTranslating { failures.append("Sentence was intercepted by dictionary") }
    model.stopTranslation()
    model.inputText = "bonjour"
    settings.settings.dictionaryEnabled = false
    model.lookupDictionary()
    if model.dictionaryAvailable || model.isLookingUpDictionary { failures.append("Disabled dictionary exposed lookup") }
    settings.settings.dictionaryEnabled = true
    model.clear()
    var custom = TranslationAction.builtIns[0]
    custom.id = UUID()
    model.customActions = [custom]
    model.selectedActionID = custom.id
    model.inputText = "bonjour"
    model.translate()
    if model.dictionaryVisible || model.primaryActionTitle != "Translate" { failures.append("Dictionary intercepted custom AI action") }
    model.stopTranslation()
    // Use the real packs to prove multi-token Japanese inflections qualify
    // from lexical evidence, while sentence-sized selections never do.
    settings.settings.dictionaryDefinitionLanguage = "zh"
    settings.settings.sourceLanguage = .auto
    let lexical = AppModel(settingsStore: settings, library: LibraryStore(directory: directory), integrateWithSystem: false)
    lexical.inputText = "食べました"
    lexical.translate()
    for _ in 0..<500 {
      if !lexical.isLookingUpDictionary { break }
      try? await Task.sleep(for: .milliseconds(2))
    }
    if !lexical.dictionaryAvailable || !lexical.dictionaryVisible || lexical.dictionaryMatches.isEmpty {
      failures.append("Real Japanese inflection did not expose dictionary tab")
    }
    lexical.outputText = "AI translation"
    lexical.selectResultTab(.translation)
    lexical.lookupDictionary()
    for _ in 0..<500 {
      if !lexical.isLookingUpDictionary { break }
      try? await Task.sleep(for: .milliseconds(2))
    }
    if lexical.outputText != "AI translation" { failures.append("Refreshing dictionary discarded translation") }
    lexical.selectResultTab(.translation)
    if lexical.isTranslating { failures.append("Returning to translation repeated AI request") }
    lexical.inputText = "資料館の展示と見どころ"
    if lexical.dictionaryAvailable || !lexical.outputText.isEmpty || !lexical.dictionaryMatches.isEmpty {
      failures.append("Changing from a word to a title retained stale tab/results")
    }
    lexical.translate()
    for _ in 0..<500 {
      if !lexical.isLookingUpDictionary && !lexical.isTranslating { break }
      try? await Task.sleep(for: .milliseconds(2))
    }
    if lexical.dictionaryAvailable || lexical.selectedResultTab != .translation {
      failures.append("Real dictionary packs intercepted the screenshot title")
    }
    lexical.stopTranslation()
    settings.settings.dictionaryDefinitionLanguage = "en"
    let pendingProvider = DictionaryLateFixtureProvider()
    let pending = AppModel(settingsStore: settings, library: library,
      dictionaryRegistry: DictionaryRegistry(providers: [pendingProvider]), integrateWithSystem: false)
    pending.inputText = "old"
    pending.setDictionarySource("fr")
    while !(await pendingProvider.started) { await Task.yield() }
    pending.outputText = "Cached translation while lookup runs"
    pending.selectResultTab(.translation)
    await pendingProvider.release()
    for _ in 0..<500 {
      if !pending.isLookingUpDictionary { break }
      try? await Task.sleep(for: .milliseconds(2))
    }
    if pending.dictionaryVisible || pending.currentResultText != "Cached translation while lookup runs" {
      failures.append("Background dictionary completion stole the active translation tab")
    }
    pending.stopTranslation()
    return failures
  }
}

/// Intentionally ignores cancellation to model a late third-party callback.
/// The coordinator must reject the completed old request independently.
private actor DictionaryLateFixtureProvider: DictionaryProvider {
  nonisolated let descriptor = DictionaryFixtureProvider().descriptor
  private(set) var started = false
  private var continuation: CheckedContinuation<Void, Never>?
  func lookup(_ candidates: [LexicalCandidate], sourceLanguage: String, definitionLanguage: String) async throws -> [DictionaryMatch] {
    if candidates.first?.text == "old" {
      started = true
      await withCheckedContinuation { continuation = $0 }
      return [.init(entry: .init(id: "old", headword: "old", sourceLanguage: "fr", definitionLanguage: "en",
        readings: [], senses: [.init(id: "1", glosses: ["obsolete"], labels: [])], sourceURL: "https://example.com/old"),
        dictionary: descriptor, matchedForm: "old", matchKind: "headword")]
    }
    return try await DictionaryFixtureProvider().lookup(candidates, sourceLanguage: sourceLanguage, definitionLanguage: definitionLanguage)
  }
  func release() { continuation?.resume(); continuation = nil }
}
