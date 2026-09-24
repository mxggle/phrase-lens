import AppKit
import Combine
import Foundation

enum InputSource: Sendable {
  case manual
  case selection
  case ocr
  case history
}

/// Whether the armed action got the surrounding text it works from.
enum SelectionContextState: Sendable {
  /// The action does not read the text around the selection.
  case unused
  case captured
  case missing
}

/// How far along a run of the vocabulary tagger is.
///
/// Only the runs a reader asked for report here. A word filed the moment it is
/// collected reports nothing: that work is meant to be invisible, and a
/// progress strip appearing on its own would be the only sign of it.
struct VocabularyOrganizeProgress: Equatable, Sendable {
  var completed: Int
  var total: Int
}

/// Which pane's text the speech service is reading.
///
/// One synthesizer serves both panes, so the pane is what tells the two speak
/// buttons apart: the one that started the audio offers to stop it, and the
/// other still offers to speak its own text.
enum SpokenPane: Sendable {
  case source
  case result
}

/// How the result pane should lay the output out.
enum OutputRendering: Sendable {
  /// The armed action asked for plain text.
  case plain
  /// The armed action asked for Markdown.
  case markdown
  /// No action speaks for this output — restored history whose action has
  /// since been deleted or renamed. Only here does the text itself decide.
  case undetermined
}

enum ResultTab: String, CaseIterable {
  case translation = "Translation"
  case dictionary = "Dictionary"
}

@MainActor
final class AppModel: ObservableObject {
  @Published var inputText = "" {
    didSet {
      if oldValue != inputText {
        stopTranslation()
        outputText = ""
        errorMessage = nil
        resetFollowUps()
        resetDictionary()
        dictionarySourceOverride = "auto"
        statusMessage = L10n.isChinese ? "就绪" : "Ready"
      }
    }
  }
  @Published private(set) var translatorFocusToken = UUID()
  @Published private(set) var dictionaryState: DictionaryLookupState = .idle
  @Published private(set) var selectedResultTab: ResultTab = .dictionary
  private var translationRequested = false
  private var translationErrorMessage: String?
  private var translatedTarget: LanguageCode?
  private var translatedSourceOverride: String?
  @Published private var dictionaryWordConfirmed = false
  @Published private(set) var dictionarySourceOverride = "auto"
  private var dictionaryTask: Task<Void, Never>?
  private var dictionaryRequestID = UUID()
  private var dictionaryRegistry: DictionaryRegistry?
  @Published var outputText = ""
  @Published private(set) var outputRendering: OutputRendering = .plain
  @Published var selectedActionID = TranslationAction.builtIns[0].id
  @Published var selectionContext: String?
  /// What the last selection capture managed to read. Drives the context
  /// badge, and gives a reader reporting "it did not pick up the sentence"
  /// something concrete to report.
  @Published private(set) var selectionDiagnostics: SelectionDiagnostics?
  @Published var inputSource: InputSource = .manual
  @Published var isTranslating = false
  /// The questions asked about the current result, oldest first. The last one
  /// may still be streaming its answer.
  @Published private(set) var followUps: [FollowUpTurn] = []
  @Published private(set) var isAnsweringFollowUp = false
  /// Why the last follow-up failed. Shown beside the composer rather than in
  /// an alert: the result it belongs to is still on screen and still readable.
  @Published private(set) var followUpError: String?
  @Published var followUpDraft = ""
  /// Changes whenever a command outside the composer asks it for keyboard
  /// focus, which is the only way a menu item can reach a text field.
  @Published private(set) var followUpFocusToken = UUID()
  @Published var statusMessage = L10n.isChinese ? "就绪" : "Ready"
  @Published var errorMessage: String?
  @Published var history: [HistoryEntry] = []
  @Published var vocabulary: [VocabularyEntry] = []
  /// The filing run the reader started, or nil when none is running.
  @Published private(set) var vocabularyOrganizing: VocabularyOrganizeProgress?
  @Published var customActions: [TranslationAction] = []
  @Published var shortcutErrors: [String] = []
  @Published private(set) var isAccessibilityTrusted = false
  /// The pane whose text is being spoken, or nil when nothing is.
  @Published private(set) var speakingPane: SpokenPane?

  let settingsStore: SettingsStore
  let modelCatalog = ModelCatalogStore()
  let speech = SpeechService()

  private let client = TranslationClient()
  private let tagger = VocabularyTagger()
  private let library: LibraryStore
  private let accessibility = AccessibilityService()
  private let ocr = OCRService()
  private var translationTask: Task<Void, Never>?
  private var vocabularyTaggingTask: Task<Void, Never>?
  private var followUpTask: Task<Void, Never>?
  private var requestID = UUID()
  private var followUpRequestID = UUID()
  /// The history row the current result was filed under, so a thread built on
  /// top of it is saved to that same row instead of to a new one.
  private var currentHistoryID: UUID?
  private var selectionCaptureID = UUID()
  private var restoredSourceLanguage: LanguageCode?
  private var cancellables = Set<AnyCancellable>()

  init(settingsStore: SettingsStore = SettingsStore(), library: LibraryStore = LibraryStore(),
       dictionaryRegistry: DictionaryRegistry? = nil, integrateWithSystem: Bool = true) {
    self.settingsStore = settingsStore
    self.library = library
    self.dictionaryRegistry = dictionaryRegistry
    isAccessibilityTrusted = integrateWithSystem && accessibility.isTrusted()
    selectedActionID =
      settingsStore.settings.resolvedDefaultAction(customActions: [])?.id
      ?? TranslationAction.builtIns[0].id
    speech.$errorMessage
      .compactMap { $0 }
      .sink { [weak self] message in self?.errorMessage = message }
      .store(in: &cancellables)
    // Audio that finished, failed, or was stopped from anywhere leaves no
    // pane speaking. Every start assigns the pane after calling `speak`,
    // which begins by stopping whatever was playing and lands here first.
    speech.$isSpeaking
      .filter { !$0 }
      .sink { [weak self] _ in self?.speakingPane = nil }
      .store(in: &cancellables)
    settingsStore.$settings
      .removeDuplicates { previous, current in
        previous.defaultActionID == current.defaultActionID
          && previous.actionOrder == current.actionOrder
          && previous.hiddenActionIDs == current.hiddenActionIDs
          && previous.builtInActionOverrides == current.builtInActionOverrides
      }
      .dropFirst()
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in self?.reconcileActionSelection() }
      }
      .store(in: &cancellables)
    observeRuntimeSettings()
    if integrateWithSystem {
      Task { await loadLibrary() }
      configureHotKeys()
    }
  }

  var allActions: [TranslationAction] {
    orderedActions
  }

  /// All available actions in the user's preferred display order. Hidden
  /// actions remain here so the Actions editor can manage them.
  var orderedActions: [TranslationAction] {
    settingsStore.settings.orderedActions(customActions: customActions)
  }

  /// The actions that may be selected from translation surfaces.
  var visibleActions: [TranslationAction] {
    settingsStore.settings.orderedActions(
      customActions: customActions,
      includingHidden: false
    )
  }

  var selectedAction: TranslationAction {
    visibleActions.first(where: { $0.id == selectedActionID })
      ?? settingsStore.settings.resolvedDefaultAction(customActions: customActions)
      ?? TranslationAction.builtIns[0]
  }

  /// Whether the result is laid out as Markdown rather than shown literally.
  ///
  /// What the request asked the model for is the authority (see
  /// `PromptBuilder.expectsMarkdown`): a model that answers in Markdown anyway
  /// does not get to override an author who turned the switch off. Inspecting
  /// the text is a last resort, for output whose action no longer exists.
  var outputUsesMarkdown: Bool {
    switch outputRendering {
    case .markdown: true
    case .plain: false
    case .undetermined: MarkdownParser.looksLikeMarkdown(outputText)
    }
  }

  var visibleSourceLanguages: [LanguageCode] {
    let favorites = normalizedFavoriteLanguages()
    return [.auto] + favorites
  }

  var visibleTargetLanguages: [LanguageCode] {
    normalizedFavoriteLanguages()
  }

  /// Whether the armed action has the surrounding text it needs.
  ///
  /// Only actions that read `${context}` report anything: for the rest there
  /// is no such thing as a missing context, and a badge saying so would be
  /// noise on every capture.
  var selectionContextState: SelectionContextState {
    guard inputSource == .selection, selectedAction.usesSelectionContext else { return .unused }
    return PromptBuilder.hasMeaningfulContext(selectionContext, for: inputText)
      ? .captured
      : .missing
  }

  /// The captured surrounding text, trimmed to something a tooltip can hold.
  var selectionContextPreview: String? {
    guard
      let context = selectionContext?.trimmingCharacters(in: .whitespacesAndNewlines),
      !context.isEmpty
    else { return nil }
    let preview = context.count > 320 ? String(context.prefix(320)) + "…" : context
    return "Surrounding text captured with the selection:\n\n\(preview)"
  }

  /// What the capture actually saw, for the reader whose sentence was not
  /// picked up. Roles and counts only — the text itself is theirs.
  var selectionCaptureSummary: String {
    var lines = [
      "No surrounding text could be read from the source app, "
        + "so this action explains the selection on its own."
    ]
    if let diagnostics = selectionDiagnostics {
      let timedOut = diagnostics.traversalTruncated ? " · search hit its time limit" : ""
      lines.append(
        "Focused control: \(diagnostics.focusedRole ?? "unknown") · "
          + "\(diagnostics.candidateCount) elements · "
          + "\(diagnostics.textSegmentCount) text blocks\(timedOut)"
      )
    }
    return lines.joined(separator: "\n\n")
  }

  var isAccessibilityPermissionError: Bool {
    errorMessage == TranslationError.accessibilityPermissionRequired.localizedDescription
  }

  /// Whether the current failure is something only Settings can fix, so a
  /// surface showing it can offer that route instead of a retry that would
  /// reproduce the same error. Matched against the errors themselves rather
  /// than against copied strings, as the accessibility case above is.
  var isConfigurationError: Bool {
    guard let errorMessage else { return false }
    return errorMessage == TranslationError.missingAPIKey.localizedDescription
      || errorMessage.hasPrefix(TranslationError.invalidEndpoint("").localizedDescription)
  }

  func resetDictionary() {
    dictionaryRequestID = UUID()
    dictionaryTask?.cancel()
    dictionaryTask = nil
    selectedResultTab = .dictionary
    dictionaryState = .idle
    dictionaryWordConfirmed = false
    translationRequested = false
    translatedTarget = nil
    translatedSourceOverride = nil
  }

  private var supportsDictionaryTabs: Bool {
    settingsStore.settings.dictionaryEnabled && selectedAction.isBuiltIn && selectedAction.mode == .translate
  }

  var dictionaryAvailable: Bool {
    supportsDictionaryTabs && (DictionaryLanguageResolver.isLookupCandidate(inputText)
      || (DictionaryLanguageResolver.canProbeLexicalEntry(inputText) && dictionaryWordConfirmed))
  }

  var dictionaryVisible: Bool { dictionaryAvailable && selectedResultTab == .dictionary }

  // An AI request may finish while the user is reading offline definitions.
  // Keep that error with its tab; dictionary save/speech errors remain visible.
  var visibleErrorMessage: String? {
    dictionaryVisible && errorMessage == translationErrorMessage ? nil : errorMessage
  }

  var canCopyResult: Bool { !currentResultText.isEmpty }

  var currentResultText: String {
    dictionaryVisible
      ? dictionaryMatches.filter { $0.dictionary.canPersist }.map(\.plainText).joined(separator: "\n\n")
      : outputText
  }

  func selectResultTab(_ tab: ResultTab) {
    guard tab != .dictionary || dictionaryAvailable else { return }
    selectedResultTab = tab
    if isSpeaking(.result) { speech.stop() }
    switch tab {
    case .translation:
      let languageChanged = (translatedTarget.map { $0 != settingsStore.settings.targetLanguage } ?? false)
        || (translatedSourceOverride.map { $0 != dictionarySourceOverride } ?? false)
      if languageChanged || (outputText.isEmpty && !isTranslating && !translationRequested) {
        translateWithAI(preserveDictionary: true)
      }
    case .dictionary:
      if case .idle = dictionaryState { lookupDictionary() }
      // A definition-language change while this tab was hidden must not show
      // the cached result in the old language.
      if case .result(let result) = dictionaryState,
        result.request.definitionLanguage != settingsStore.settings.dictionaryDefinitionLanguage {
        lookupDictionary()
      }
    }
  }

  func setDictionarySource(_ language: String) {
    dictionarySourceOverride = language
    if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lookupDictionary() }
  }

  var dictionarySourceOptions: [String] {
    let extra = dictionaryRegistry?.providers.flatMap { $0.descriptor.sourceLanguages } ?? []
    return ["auto"] + Array(Set(LanguageCode.allCases.filter { $0 != .auto }.map(\.rawValue) + extra + [dictionarySourceOverride]).subtracting(["auto"])).sorted()
  }

  var dictionaryDefinitionOptions: [String] {
    let extra = dictionaryRegistry?.providers.flatMap { $0.descriptor.definitionLanguages } ?? []
    return ["zh"] + Array(Set(LanguageCode.allCases.filter { $0 != .auto }.map(\.rawValue) + extra + [settingsStore.settings.dictionaryDefinitionLanguage]).subtracting(["zh"])).sorted()
  }

  var dictionaryMatches: [DictionaryMatch] {
    if case .result(let result) = dictionaryState { return result.matches }
    return []
  }

  var isLookingUpDictionary: Bool {
    if case .loading = dictionaryState { return true }
    return false
  }

  func lookupDictionary(definitionLanguage: String? = nil, configuredSource: String? = nil, probing: Bool = false) {
    let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard supportsDictionaryTabs, DictionaryLanguageResolver.canProbeLexicalEntry(query) else { return }
    dictionaryTask?.cancel()
    selectedResultTab = .dictionary
    dictionaryState = .loading
    let source = dictionarySourceOverride != "auto" ? dictionarySourceOverride
      : (inputSource == .manual ? (configuredSource ?? settingsStore.settings.sourceLanguage.rawValue) : "auto")
    let request = DictionaryRequest(text: query, sourceOverride: source,
      definitionLanguage: definitionLanguage ?? settingsStore.settings.dictionaryDefinitionLanguage,
      context: selectionContext)
    let ticket = UUID()
    dictionaryRequestID = ticket
    statusMessage = L10n.isChinese ? "正在查词…" : "Looking up dictionary…"
    dictionaryTask = Task {
      do {
        if dictionaryRegistry == nil { dictionaryRegistry = try BundledDictionaries.registry() }
        guard let dictionaryRegistry else { throw DictionaryDataError.unavailable }
        let result = try await dictionaryRegistry.lookup(request)
        guard !Task.isCancelled, dictionaryRequestID == ticket else { return }
        if !result.matches.isEmpty { dictionaryWordConfirmed = true }
        dictionaryState = .result(result)
        if probing && result.matches.isEmpty {
          if selectedResultTab == .dictionary { translateWithAI(preserveDictionary: true) }
          return
        }
        statusMessage = result.matches.isEmpty
          ? (L10n.isChinese ? "未找到词条释义" : "No dictionary entry")
          : (L10n.isChinese ? "词典 · 离线" : "Dictionary · Offline")
        let saved = result.matches.filter { $0.dictionary.canPersist }
        guard !saved.isEmpty else { return }
        let snapshot = DictionarySnapshot(query: query, definitionLanguage: request.definitionLanguage, matches: saved)
        let entry = HistoryEntry(sourceText: query,
          translatedText: saved.map(\.plainText).joined(separator: "\n\n"),
          sourceLanguage: LanguageCode(rawValue: saved[0].entry.sourceLanguage) ?? .auto,
          targetLanguage: LanguageCode(rawValue: request.definitionLanguage) ?? .simplifiedChinese,
          actionName: "Dictionary", provider: nil, model: "", dictionarySnapshot: snapshot,
          selectionContext: request.context)
        try await library.addHistory(entry)
        history.insert(entry, at: 0)
        // Dictionary history must not replace the AI history row used by follow-ups.
      } catch is CancellationError { }
      catch {
        guard dictionaryRequestID == ticket else { return }
        if case .result = dictionaryState {
          statusMessage = L10n.isChinese ? "词典已加载；历史记录未能保存" : "Dictionary loaded; history could not be saved"
        } else {
          dictionaryState = .failed(error.localizedDescription)
          statusMessage = L10n.isChinese ? "词典不可用" : "Dictionary unavailable"
          if probing && selectedResultTab == .dictionary { translateWithAI(preserveDictionary: true) }
        }
      }
    }
  }

  func explainDictionaryWithAI() {
    // The translation uses the user's input, never licensed dictionary content.
    selectResultTab(.translation)
  }

  func saveDictionaryEntry(_ match: DictionaryMatch, sense: DictionarySense? = nil) {
    guard match.dictionary.canPersist else { return }
    var selected = match
    if let sense { selected.entry.senses = [sense] }
    let snapshot = DictionarySnapshot(query: inputText,
      definitionLanguage: match.entry.definitionLanguage, matches: [selected])
    var entry = VocabularyEntry(word: match.entry.headword, explanation: selected.plainText,
      sourceLanguage: LanguageCode(rawValue: match.entry.sourceLanguage) ?? .auto,
      targetLanguage: LanguageCode(rawValue: match.entry.definitionLanguage) ?? .simplifiedChinese,
      dictionarySnapshot: snapshot)
    if let existing = vocabulary.first(where: { $0.matchesIdentity(of: entry) }) { entry.id = existing.id }
    let savedEntry = entry
    Task {
      do {
        try await library.addVocabulary(savedEntry)
        vocabulary.removeAll { $0.matchesIdentity(of: savedEntry) }
        vocabulary.insert(savedEntry, at: 0)
        statusMessage = L10n.isChinese ? "词条已保存至生词本" : "Dictionary entry saved"
      } catch { errorMessage = error.localizedDescription }
    }
  }

  func isDictionaryEntrySaved(_ match: DictionaryMatch, sense: DictionarySense? = nil) -> Bool {
    let ids = sense.map { [$0.id] } ?? match.entry.senses.map(\.id)
    return vocabulary.contains {
      $0.dictionarySnapshot?.matches.first?.id == match.id
        && $0.dictionarySnapshot?.matches.first?.entry.senses.map(\.id) == ids
    }
  }

  func copyDictionaryEntry(_ match: DictionaryMatch) {
    guard match.dictionary.canPersist else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(match.plainText, forType: .string)
    statusMessage = L10n.isChinese ? "已拷贝词条及出处" : "Dictionary entry copied with source"
  }

  func speakDictionaryEntry(_ match: DictionaryMatch) {
    speech.speak(match.entry.readings.first ?? match.entry.headword,
      language: LanguageCode(rawValue: match.entry.sourceLanguage) ?? .auto,
      rate: settingsStore.settings.speechRate, volume: settingsStore.settings.speechVolume,
      provider: settingsStore.settings.resolvedTTSProvider)
    speakingPane = .source
  }

  var primaryActionTitle: String { dictionaryVisible ? "Look Up" : "Translate" }

  func translate() {
    if supportsDictionaryTabs, selectedResultTab == .dictionary,
      DictionaryLanguageResolver.canProbeLexicalEntry(inputText) {
      lookupDictionary(probing: !dictionaryAvailable)
    } else {
      translateWithAI(preserveDictionary: supportsDictionaryTabs)
    }
  }

  func translateWithAI(preserveDictionary: Bool = false, actionOverride: TranslationAction? = nil) {
    if !preserveDictionary { resetDictionary() }
    selectedResultTab = .translation
    translationRequested = true
    translatedTarget = settingsStore.settings.targetLanguage
    translatedSourceOverride = dictionarySourceOverride
    let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      errorMessage = TranslationError.noInput.localizedDescription
      return
    }

    translationTask?.cancel()
    requestID = UUID()
    let activeRequest = requestID
    outputText = ""
    // The thread hangs off the answer that is about to be replaced.
    resetFollowUps()
    translationErrorMessage = nil
    errorMessage = nil
    isTranslating = true
    statusMessage = L10n.isChinese
      ? "正在连接 \(settingsStore.settings.provider.provider.rawValue)…"
      : "Connecting to \(settingsStore.settings.provider.provider.rawValue)…"

    let settings = settingsStore.settings
    let resolvedSource = TranslationSourceResolver.resolve(
      text,
      configuredSource: settings.sourceLanguage,
      inputSource: inputSource,
      restoredSource: restoredSourceLanguage
    )
    let source = preserveDictionary && dictionarySourceOverride != "auto"
      ? (LanguageCode(rawValue: dictionarySourceOverride) ?? resolvedSource) : resolvedSource
    let target = settings.targetLanguage
    let action = actionOverride ?? selectedAction
    outputRendering = PromptBuilder.expectsMarkdown(action, text: text) ? .markdown : .plain
    let context = selectionContext
    let prompt = PromptBuilder.build(
      text: text,
      source: source,
      target: target,
      action: action,
      selectionContext: context
    )
    let configuration = settings.provider
    let proxy = settings.proxy

    translationTask = Task {
      // Held outside the `do` so a failure can still flush it: the UI is
      // updated on a 50 ms throttle, and text that arrived inside the last
      // tick is as real as the rest of the answer.
      var streamedText = ""
      do {
        let (key, accountId) = try await settingsStore.validCredentials()
        streamedText.reserveCapacity(min(max(text.utf8.count, 1_024), 65_536))
        let clock = ContinuousClock()
        var nextUIUpdate = clock.now

        for try await chunk in client.stream(
          prompt: prompt,
          configuration: configuration,
          apiKey: key,
          accountId: accountId,
          proxy: proxy
        ) {
          guard requestID == activeRequest else { return }
          streamedText.append(chunk)
          let now = clock.now
          if now >= nextUIUpdate {
            outputText = streamedText
            statusMessage = L10n.isChinese ? "正在翻译…" : "Translating…"
            nextUIUpdate = now.advanced(by: .milliseconds(50))
          }
        }
        guard requestID == activeRequest else { return }
        outputText = streamedText
        isTranslating = false
        statusMessage = L10n.isChinese ? "完成" : "Completed"
        guard !streamedText.isEmpty else {
          throw TranslationError.invalidResponse
        }
        try await recordHistory(
          HistoryEntry(
            sourceText: text,
            translatedText: streamedText,
            sourceLanguage: source,
            targetLanguage: target,
            actionName: action.name,
            provider: configuration.provider,
            model: configuration.model,
            selectionContext: context
          )
        )
        if settings.autoSpeakSelection {
          speech.speak(
            text,
            language: source,
            rate: settings.speechRate,
            volume: settings.speechVolume,
            provider: settings.resolvedTTSProvider
          )
          speakingPane = .source
        }
      } catch let error as TranslationError where error == .cancelled {
        guard requestID == activeRequest else { return }
        outputText = streamedText
        isTranslating = false
        statusMessage = L10n.isChinese ? "已停止" : "Stopped"
      } catch {
        guard requestID == activeRequest else { return }
        outputText = streamedText
        isTranslating = false
        statusMessage = L10n.isChinese ? "失败" : "Failed"
        translationErrorMessage = error.localizedDescription
        errorMessage = error.localizedDescription
        // A provider that stopped early still answered. The text on screen is
        // as real as any other result and belongs in history; the message
        // above is what says it is a fragment.
        if case TranslationError.streamInterrupted = error, !streamedText.isEmpty {
          try? await recordHistory(
            HistoryEntry(
              sourceText: text,
              translatedText: streamedText,
              sourceLanguage: source,
              targetLanguage: target,
              actionName: action.name,
              provider: configuration.provider,
              model: configuration.model,
              selectionContext: context
            )
          )
        }
      }
    }
  }

  private func recordHistory(_ entry: HistoryEntry) async throws {
    try await library.addHistory(entry)
    history.insert(entry, at: 0)
    currentHistoryID = entry.id
  }

  /// Calls off everything the translator is running, the follow-up thread
  /// included: both stream into the same pane, so one Stop has to reach both.
  func stopTranslation() {
    dictionaryRequestID = UUID()
    dictionaryTask?.cancel()
    dictionaryTask = nil
    if case .loading = dictionaryState {
      dictionaryState = .failed(L10n.isChinese ? "已停止查词。" : "Lookup stopped.")
    }
    requestID = UUID()
    translationTask?.cancel()
    translationTask = nil
    isTranslating = false
    stopFollowUp()
    statusMessage = L10n.isChinese ? "已停止" : "Stopped"
  }

  /// Typing over text that arrived from somewhere else makes it the user's
  /// own. The provenance badge and the surrounding sentence captured with the
  /// selection both stop describing what is in the box on the first keystroke,
  /// so a keystroke is what drops them — sending the old context along with
  /// edited text would quietly translate the word against a sentence it is no
  /// longer part of.
  func editInputText(_ newValue: String) {
    guard newValue != inputText else { return }
    inputText = newValue
    guard inputSource != .manual else { return }
    inputSource = .manual
    selectionContext = nil
    selectionDiagnostics = nil
    restoredSourceLanguage = nil
  }

  func clear() {
    stopTranslation()
    inputText = ""
    outputText = ""
    outputRendering = .plain
    selectionContext = nil
    selectionDiagnostics = nil
    inputSource = .manual
    restoredSourceLanguage = nil
    resetFollowUps()
    errorMessage = nil
    statusMessage = L10n.isChinese ? "就绪" : "Ready"
  }

  func swapLanguages() {
    resetDictionary()
    let source = settingsStore.settings.sourceLanguage
    guard source != .auto else { return }
    settingsStore.settings.sourceLanguage = settingsStore.settings.targetLanguage
    settingsStore.settings.targetLanguage = source
    if !outputText.isEmpty {
      let previousInput = inputText
      inputText = outputText
      outputText = previousInput
      selectedResultTab = .translation
      outputRendering = .plain
      // The questions were asked about the answer that just became the input.
      resetFollowUps()
    }
  }

  func copyOutput() {
    let text = currentResultText
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    statusMessage = L10n.isChinese ? "已拷贝" : "Copied"
  }

  /// Whether this pane is the one currently being read aloud.
  func isSpeaking(_ pane: SpokenPane) -> Bool {
    speech.isSpeaking && speakingPane == pane
  }

  func speakInput() {
    guard !isSpeaking(.source) else {
      speech.stop()
      return
    }
    let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let settings = settingsStore.settings
    let language = TranslationSourceResolver.resolve(
      text,
      configuredSource: settings.sourceLanguage,
      inputSource: inputSource,
      restoredSource: restoredSourceLanguage
    )
    speech.speak(
      text,
      language: language,
      rate: settings.speechRate,
      volume: settings.speechVolume,
      provider: settings.resolvedTTSProvider
    )
    speakingPane = .source
  }

  /// Reads the result aloud, in the language it was translated into.
  ///
  /// A reader who cannot pronounce the answer has half a translation, so the
  /// result pane speaks for itself rather than borrowing the source pane's
  /// voice: the target language chooses the voice, and a Markdown answer is
  /// flattened first so its markup is not read out as words.
  func speakOutput() {
    guard !isSpeaking(.result) else {
      speech.stop()
      return
    }
    let text = SpokenText.from(outputText, isMarkdown: outputUsesMarkdown)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let settings = settingsStore.settings
    speech.speak(
      text,
      language: settings.targetLanguage,
      rate: settings.speechRate,
      volume: settings.speechVolume,
      provider: settings.resolvedTTSProvider
    )
    speakingPane = .result
  }

  // MARK: - Follow-up thread

  /// Whether there is a finished result to ask about. A question asked while
  /// the answer is still arriving would be about half a paragraph.
  var canAskFollowUp: Bool {
    !isTranslating && !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// One-tap questions for the current result, minus the ones already asked —
  /// a chip that would repeat an answer already in the thread is noise.
  var followUpSuggestions: [FollowUpSuggestion] {
    guard canAskFollowUp else { return [] }
    let asked = Set(followUps.map(\.question))
    return FollowUpSuggestion.suggestions(for: inputText, mode: selectedAction.mode)
      .filter { !asked.contains($0.question) }
  }

  /// Total streamed text in the result pane. The pane follows its own tail
  /// while text is arriving, and text arrives in both the result and the
  /// thread, so one measure has to cover both.
  var resultLength: Int {
    followUps.reduce(outputText.utf8.count) { total, turn in
      total + turn.question.utf8.count + turn.answer.utf8.count
    }
  }

  /// Asks about the result currently on screen.
  ///
  /// The question is appended before the request is made, so the thread shows
  /// what was asked while the answer is still on its way.
  func askFollowUp(_ rawQuestion: String) {
    let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, canAskFollowUp else { return }

    stopFollowUp()
    followUpError = nil
    followUpDraft = ""

    let settings = settingsStore.settings
    let source = TranslationSourceResolver.resolve(
      inputText.trimmingCharacters(in: .whitespacesAndNewlines),
      configuredSource: settings.sourceLanguage,
      inputSource: inputSource,
      restoredSource: restoredSourceLanguage
    )
    let prompt = PromptBuilder.followUp(
      question: question,
      base: PromptBuilder.build(
        text: inputText,
        source: source,
        target: settings.targetLanguage,
        action: selectedAction,
        selectionContext: selectionContext
      ),
      answer: outputText,
      turns: followUps,
      target: settings.targetLanguage
    )

    let turn = FollowUpTurn(question: question, answer: "")
    followUps.append(turn)
    isAnsweringFollowUp = true
    statusMessage = L10n.isChinese ? "正在回答…" : "Answering…"

    followUpRequestID = UUID()
    let activeRequest = followUpRequestID
    let configuration = settings.provider
    let proxy = settings.proxy

    followUpTask = Task {
      // Held outside the `do` for the same reason the translation stream holds
      // its own: text that arrived inside the last UI tick is part of the
      // answer even when the stream then failed.
      var streamedText = ""
      do {
        let (key, accountId) = try await settingsStore.validCredentials()
        let clock = ContinuousClock()
        var nextUIUpdate = clock.now
        for try await chunk in client.stream(
          prompt: prompt,
          configuration: configuration,
          apiKey: key,
          accountId: accountId,
          proxy: proxy
        ) {
          guard followUpRequestID == activeRequest else { return }
          streamedText.append(chunk)
          let now = clock.now
          if now >= nextUIUpdate {
            update(turn.id, answer: streamedText)
            nextUIUpdate = now.advanced(by: .milliseconds(50))
          }
        }
        guard followUpRequestID == activeRequest else { return }
        update(turn.id, answer: streamedText)
        isAnsweringFollowUp = false
        guard !streamedText.isEmpty else { throw TranslationError.invalidResponse }
        statusMessage = L10n.isChinese ? "完成" : "Completed"
        await persistFollowUps()
      } catch let error as TranslationError where error == .cancelled {
        guard followUpRequestID == activeRequest else { return }
        await settleFollowUp(
          turn.id,
          question: question,
          text: streamedText,
          status: L10n.isChinese ? "已停止" : "Stopped"
        )
      } catch {
        guard followUpRequestID == activeRequest else { return }
        await settleFollowUp(
          turn.id,
          question: question,
          text: streamedText,
          status: L10n.isChinese ? "失败" : "Failed",
          error: error.localizedDescription
        )
      }
    }
  }

  func stopFollowUp() {
    followUpRequestID = UUID()
    followUpTask?.cancel()
    followUpTask = nil
    guard isAnsweringFollowUp else { return }
    isAnsweringFollowUp = false
    // A question with nothing under it is not a turn, only a stray heading.
    if let last = followUps.last, last.answer.isEmpty {
      followUps.removeLast()
      followUpDraft = last.question
    }
  }

  func removeFollowUp(_ id: UUID) {
    guard let index = followUps.firstIndex(where: { $0.id == id }) else { return }
    if isAnsweringFollowUp, followUps[index].id == followUps.last?.id {
      stopFollowUp()
      return
    }
    followUps.remove(at: index)
    Task { await persistFollowUps() }
  }

  func copyFollowUpAnswer(_ id: UUID) {
    guard let turn = followUps.first(where: { $0.id == id }), !turn.answer.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(turn.answer, forType: .string)
    statusMessage = L10n.isChinese ? "已拷贝" : "Copied"
  }

  func dismissFollowUpError() {
    followUpError = nil
  }

  /// Hands keyboard focus to the composer from a menu command.
  func requestFollowUpFocus() {
    guard canAskFollowUp else { return }
    followUpFocusToken = UUID()
  }

  private func update(_ id: UUID, answer: String) {
    guard let index = followUps.firstIndex(where: { $0.id == id }) else { return }
    followUps[index].answer = answer
  }

  /// Closes out a follow-up that stopped early. Whatever streamed before it
  /// stopped is a real partial answer and stays; a turn with nothing under it
  /// hands its question back to the composer so it can be asked again.
  private func settleFollowUp(
    _ id: UUID,
    question: String,
    text: String,
    status: String,
    error: String? = nil
  ) async {
    isAnsweringFollowUp = false
    statusMessage = status
    followUpError = error
    if text.isEmpty {
      followUps.removeAll { $0.id == id }
      if followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        followUpDraft = question
      }
      return
    }
    update(id, answer: text)
    await persistFollowUps()
  }

  private func resetFollowUps() {
    stopFollowUp()
    followUps = []
    followUpDraft = ""
    followUpError = nil
    currentHistoryID = nil
  }

  /// Files the thread with the result it belongs to, so reopening that history
  /// row brings the whole conversation back rather than the first answer alone.
  private func persistFollowUps() async {
    guard let currentHistoryID,
      let index = history.firstIndex(where: { $0.id == currentHistoryID })
    else { return }
    let answered = followUps.filter { !$0.answer.isEmpty }
    history[index].followUps = answered.isEmpty ? nil : answered
    let updated = history[index]
    do {
      try await library.updateHistory(updated)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func vocabularyEntry(matching text: String) -> VocabularyEntry? {
    let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !word.isEmpty else { return nil }
    return vocabulary.first {
      $0.dictionarySnapshot == nil && $0.word.localizedCaseInsensitiveCompare(word) == .orderedSame
    }
  }

  var isCurrentWordCollected: Bool {
    vocabularyEntry(matching: inputText) != nil
  }

  func toggleCollectCurrentWord() {
    let word = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !word.isEmpty else { return }
    if let existing = vocabularyEntry(matching: word) {
      removeCollectedWord(existing)
    } else {
      collectCurrentWord()
    }
  }

  private func removeCollectedWord(_ entry: VocabularyEntry) {
    vocabulary.removeAll { $0.id == entry.id }
    Task {
      do {
        try await library.removeVocabulary(ids: [entry.id])
        statusMessage = L10n.isChinese ? "已从生词本移除" : "Removed from vocabulary"
      } catch {
        vocabulary.insert(entry, at: 0)
        errorMessage = error.localizedDescription
      }
    }
  }

  func collectCurrentWord() {
    let word = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !word.isEmpty, !outputText.isEmpty else { return }
    let settings = settingsStore.settings
    let source = TranslationSourceResolver.resolve(
      word,
      configuredSource: settings.sourceLanguage,
      inputSource: inputSource,
      restoredSource: restoredSourceLanguage
    )
    var entry = VocabularyEntry(
      word: word,
      explanation: outputText,
      sourceLanguage: source,
      targetLanguage: settings.targetLanguage
    )
    if let existing = vocabulary.first(where: { $0.matchesIdentity(of: entry) }) { entry.id = existing.id }
    let savedEntry = entry
    Task {
      let entry = savedEntry
      do {
        try await library.addVocabulary(entry)
        vocabulary.removeAll { $0.matchesIdentity(of: entry) }
        vocabulary.insert(entry, at: 0)
        statusMessage = L10n.isChinese ? "已添加到生词本" : "Added to vocabulary"
        // Filed straight away, so the word is already browsable by the time
        // the reader next opens the library. It runs unattended: a failure
        // here leaves the word saved and unfiled, which the Organize command
        // picks up later.
        tagVocabulary([entry], announcing: false)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func restore(_ entry: HistoryEntry, showWindow: Bool = true) {
    resetDictionary()
    stopTranslation()
    resetFollowUps()
    inputText = entry.sourceText
    if let snapshot = entry.dictionarySnapshot {
      settingsStore.settings.dictionaryDefinitionLanguage = snapshot.definitionLanguage
      outputText = ""
      dictionaryWordConfirmed = true
      selectedResultTab = .dictionary
      dictionaryState = .result(DictionaryLookupResult(
        request: .init(text: snapshot.query, definitionLanguage: snapshot.definitionLanguage),
        languages: Array(Set(snapshot.matches.map { $0.entry.sourceLanguage })).sorted(),
        matches: snapshot.matches, notices: [], supportsPair: true))
    } else {
      selectedResultTab = .translation
      translationRequested = true
      outputText = entry.translatedText
    }
    selectionContext = entry.selectionContext
    selectionDiagnostics = nil
    inputSource = .history
    restoredSourceLanguage = entry.sourceLanguage
    // The thread is reopened against its own history row, so questions asked
    // now are saved back to the same entry.
    followUps = entry.followUps ?? []
    currentHistoryID = entry.id
    settingsStore.settings.targetLanguage = entry.targetLanguage
    if let action = visibleActions.first(where: { $0.name == entry.actionName }) {
      selectedActionID = action.id
      outputRendering =
        PromptBuilder.expectsMarkdown(action, text: entry.sourceText) ? .markdown : .plain
    } else {
      // The action that produced this entry is gone, so nothing here states
      // the author's intent — the stored text is all there is to go on.
      selectDefaultAction()
      outputRendering = .undetermined
    }
    if entry.dictionarySnapshot != nil {
      selectedActionID = TranslationAction.builtIns[0].id
      if !dictionaryAvailable {
        selectedResultTab = .translation
        outputText = entry.translatedText
        outputRendering = .plain
      }
    }
    statusMessage = entry.dictionarySnapshot == nil
      ? (L10n.isChinese ? "已恢复历史记录" : "History restored")
      : (L10n.isChinese ? "词典 · 历史查询" : "Dictionary · Saved lookup")
    if showWindow {
      translatorFocusToken = UUID()
      WindowCoordinator.showMain()
    }
  }

  func toggleFavorite(_ entry: HistoryEntry) {
    guard let index = history.firstIndex(where: { $0.id == entry.id }) else { return }
    history[index].favorite.toggle()
    let updated = history[index]
    Task {
      do {
        try await library.updateHistory(updated)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func deleteHistory(ids: Set<UUID>) {
    history.removeAll { ids.contains($0.id) }
    Task {
      do {
        try await library.removeHistory(ids: ids)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  // MARK: - Filing saved words

  /// Words that have never been filed, or were filed under an older taxonomy.
  var unfiledVocabulary: [VocabularyEntry] {
    vocabulary.filter {
      ($0.tags?.taxonomyVersion ?? 0) < VocabularyTagger.taxonomyVersion
    }
  }

  /// How many there are, without building the list to find out — the library
  /// view asks on every layout pass.
  var unfiledVocabularyCount: Int {
    vocabulary.reduce(into: 0) { total, entry in
      if (entry.tags?.taxonomyVersion ?? 0) < VocabularyTagger.taxonomyVersion { total += 1 }
    }
  }

  var isOrganizingVocabulary: Bool { vocabularyOrganizing != nil }

  /// Files everything that is not filed yet.
  func organizeVocabulary() {
    tagVocabulary(unfiledVocabulary, announcing: true)
  }

  /// Files the given words again, whatever they are filed under now.
  func retagVocabulary(ids: Set<UUID>) {
    tagVocabulary(vocabulary.filter { ids.contains($0.id) }, announcing: true)
  }

  func cancelVocabularyOrganizing() {
    vocabularyTaggingTask?.cancel()
    vocabularyTaggingTask = nil
    vocabularyOrganizing = nil
    statusMessage = L10n.isChinese ? "已停止整理" : "Organizing stopped"
  }

  /// Sends words to the tagger in batches, saving each batch as it lands.
  ///
  /// Saving per batch rather than at the end is what makes a long run
  /// survivable: cancelling it, or losing the connection halfway through,
  /// keeps everything filed so far instead of spending the whole run for
  /// nothing.
  private func tagVocabulary(_ entries: [VocabularyEntry], announcing: Bool) {
    let entries = entries.filter { $0.dictionarySnapshot?.matches.allSatisfy { $0.dictionary.canUseWithAI } ?? true }
    guard !entries.isEmpty else { return }
    if announcing {
      vocabularyTaggingTask?.cancel()
    }

    let batches = stride(from: 0, to: entries.count, by: VocabularyTagger.batchSize).map {
      Array(entries[$0..<min($0 + VocabularyTagger.batchSize, entries.count)])
    }
    let configuration = settingsStore.settings.provider
    let proxy = settingsStore.settings.proxy
    var topics = VocabularyFacets.rankedTopics(of: vocabulary)

    if announcing {
      vocabularyOrganizing = VocabularyOrganizeProgress(completed: 0, total: entries.count)
    }

    let task = Task { [tagger, library, settingsStore] in
      var filed = 0
      do {
        let (key, accountId) = try await settingsStore.validCredentials()
        for batch in batches {
          try Task.checkCancellation()
          let tags = try await tagger.tag(
            batch,
            knownTopics: topics,
            configuration: configuration,
            apiKey: key,
            accountId: accountId,
            proxy: proxy
          )
          let updated = try await library.applyVocabularyTags(tags)
          vocabulary = updated
          // Later batches are offered the topics the earlier ones named, so a
          // single run converges on one set of buckets instead of coining a
          // synonym every twenty words.
          topics = VocabularyFacets.rankedTopics(of: updated)
          filed += batch.count
          if announcing {
            vocabularyOrganizing = VocabularyOrganizeProgress(
              completed: filed,
              total: entries.count
            )
          }
        }
        if announcing {
          statusMessage = L10n.isChinese
            ? "已智能分类 \(filed) 个生词"
            : (filed == 1 ? "1 word organized" : "\(filed) words organized")
        }
      } catch is CancellationError {
        // Stopped on purpose; whatever landed before the stop is already saved.
      } catch TranslationError.cancelled {
      } catch {
        if announcing { errorMessage = error.localizedDescription }
      }
      if announcing {
        vocabularyOrganizing = nil
        vocabularyTaggingTask = nil
      }
    }

    if announcing { vocabularyTaggingTask = task }
  }

  func deleteVocabulary(ids: Set<UUID>) {
    vocabulary.removeAll { ids.contains($0.id) }
    Task {
      do {
        try await library.removeVocabulary(ids: ids)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func saveCustomActions(_ actions: [TranslationAction]) {
    customActions = actions
    reconcileActionConfiguration()
    Task {
      do {
        try await library.saveCustomActions(actions)
        statusMessage = L10n.isChinese ? "动作已保存" : "Actions saved"
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func updateAction(_ action: TranslationAction) {
    if action.isBuiltIn {
      settingsStore.settings.setBuiltInOverride(action)
      reconcileActionSelection()
      return
    }
    guard let index = customActions.firstIndex(where: { $0.id == action.id }) else { return }
    var updated = customActions
    updated[index] = action
    saveCustomActions(updated)
  }

  func setActionHidden(_ id: UUID, hidden: Bool) {
    guard orderedActions.contains(where: { $0.id == id }) else { return }
    if hidden {
      guard visibleActions.count > 1 else { return }
      settingsStore.settings.hiddenActionIDs.insert(id)
    } else {
      settingsStore.settings.hiddenActionIDs.remove(id)
    }
    reconcileActionSelection()
  }

  func moveAction(_ id: UUID, to destination: Int) {
    var ids = orderedActions.map(\.id)
    guard let source = ids.firstIndex(of: id) else { return }
    let moved = ids.remove(at: source)
    ids.insert(moved, at: min(max(destination, 0), ids.count))
    settingsStore.settings.actionOrder = ids
  }

  func restoreActionDefaults(_ id: UUID) {
    guard TranslationAction.factoryBuiltIn(for: id) != nil else { return }
    settingsStore.settings.resetBuiltInAction(id)
    reconcileActionSelection()
  }

  func resetActionConfiguration() {
    settingsStore.settings.resetActionPresentation()
    reconcileActionSelection(preferDefault: true)
  }

  func setDefaultAction(_ id: UUID) {
    guard orderedActions.contains(where: { $0.id == id }) else {
      reconcileActionSelection(preferDefault: true)
      return
    }
    settingsStore.setDefaultAction(id)
    selectedActionID = id
  }

  /// Arms an action from a surface that holds no binding of its own — the
  /// Translation menu and its ⌘1…⌘9 shortcuts. Mirrors what the tab bar does
  /// on click, so a keyboard switch re-runs the same way a click does.
  func selectAction(_ id: UUID) {
    guard id != selectedActionID, visibleActions.contains(where: { $0.id == id }) else { return }
    resetDictionary()
    selectedActionID = id
    guard settingsStore.settings.autoTranslate,
      !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    translate()
  }

  /// Steps through the visible actions, wrapping at both ends, for ⌘⇧] / ⌘⇧[.
  func cycleAction(by offset: Int) {
    let actions = visibleActions
    guard actions.count > 1 else { return }
    let current = actions.firstIndex(where: { $0.id == selectedActionID }) ?? 0
    let next = (current + offset % actions.count + actions.count) % actions.count
    selectAction(actions[next].id)
  }

  func configureHotKeys() {
    shortcutErrors = GlobalHotKeyManager.shared.register(
      shortcuts: settingsStore.settings.shortcuts
    ) { [weak self] action, sourceProcessIdentifier in
      self?.handleHotKey(action, sourceProcessIdentifier: sourceProcessIdentifier)
    }
  }

  /// Applies settings whose effects live outside SwiftUI's view tree. These
  /// subscriptions remain active for the lifetime of the app, so changing a
  /// setting does not depend on a particular Settings pane being on screen.
  private func observeRuntimeSettings() {
    settingsStore.$settings
      .map(\.sourceLanguage)
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] language in
        guard let self, self.inputSource == .manual, self.dictionarySourceOverride == "auto" else { return }
        if self.dictionaryVisible {
          self.lookupDictionary(configuredSource: language.rawValue)
        } else {
          self.dictionaryTask?.cancel()
          self.dictionaryRequestID = UUID()
          self.dictionaryState = .idle
        }
      }
      .store(in: &cancellables)

    settingsStore.$settings
      .map(\.dictionaryDefinitionLanguage)
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] language in
        guard let self else { return }
        if self.dictionaryVisible {
          self.lookupDictionary(definitionLanguage: language)
        } else {
          self.dictionaryTask?.cancel()
          self.dictionaryRequestID = UUID()
          self.dictionaryState = .idle
        }
      }
      .store(in: &cancellables)

    settingsStore.$settings
      .map(\.dictionaryEnabled)
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] enabled in
        if !enabled { self?.resetDictionary() }
      }
      .store(in: &cancellables)

    settingsStore.$settings
      .map(\.shortcuts)
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in self?.configureHotKeys() }
      }
      .store(in: &cancellables)

    settingsStore.$settings
      .map(\.showDockIcon)
      .removeDuplicates()
      .dropFirst()
      .sink { visible in
        Task { @MainActor in
          NSApp.setActivationPolicy(visible ? .regular : .accessory)
        }
      }
      .store(in: &cancellables)

    settingsStore.$settings
      .map(\.alwaysOnTop)
      .removeDuplicates()
      .dropFirst()
      .sink { alwaysOnTop in
        Task { @MainActor in
          WindowCoordinator.mainWindow()?.level = alwaysOnTop ? .floating : .normal
        }
      }
      .store(in: &cancellables)

    settingsStore.$settings
      .map(\.appLanguage)
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in
        guard let self else { return }
        if self.statusMessage == "Ready" || self.statusMessage == "就绪" {
          self.statusMessage = L10n.isChinese ? "就绪" : "Ready"
        }
      }
      .store(in: &cancellables)
  }

  func handleHotKey(_ action: HotKeyAction, sourceProcessIdentifier: pid_t? = nil) {
    switch action {
    case .showWindow:
      WindowCoordinator.showMain()
    case .translateSelection:
      captureSelectionAndTranslate(
        compact: settingsStore.settings.useCompactSelectionPreview,
        sourceProcessIdentifier: sourceProcessIdentifier
      )
    case .screenshotOCR:
      captureOCR()
    case .writing:
      translateFocusedInput()
    }
  }

  func captureSelectionAndTranslate(
    compact: Bool = true,
    sourceProcessIdentifier: pid_t? = nil
  ) {
    stopTranslation()
    selectionCaptureID = UUID()
    let activeCapture = selectionCaptureID
    inputText = ""
    outputText = ""
    outputRendering = .plain
    selectionContext = nil
    selectionDiagnostics = nil
    inputSource = .selection
    restoredSourceLanguage = nil
    resetFollowUps()
    errorMessage = nil
    statusMessage = L10n.isChinese ? "正在读取划选文字…" : "Reading selection…"

    // The menu bar extra and the ⌥F menu item reach this without a source
    // process, and by the time they run PhraseLens is the active application.
    // The selection the user means belongs to whichever app was in front
    // before, so fall back to that instead of inspecting ourselves.
    let sourceApplication =
      sourceProcessIdentifier ?? ActiveApplicationTracker.shared.lastExternalProcessIdentifier

    Task {
      do {
        let snapshot = try await accessibility.currentSelection(
          from: sourceApplication,
          allowCopyFallback: settingsStore.settings.useClipboardFallback
        )
        guard selectionCaptureID == activeCapture else { return }
        guard !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw TranslationError.selectionUnavailable
        }
        inputText = snapshot.text
        selectionContext = snapshot.surroundingText
        selectionDiagnostics = snapshot.diagnostics
        statusMessage = L10n.isChinese ? "就绪" : "Ready"
        selectDefaultAction()
        if compact {
          SelectionPanelCoordinator.shared.show(model: self)
        } else {
          WindowCoordinator.showMain()
        }
        if settingsStore.settings.autoTranslate {
          translate()
        }
      } catch {
        guard selectionCaptureID == activeCapture else { return }
        // No text selected: skip silently instead of showing an error dialog.
        if let error = error as? TranslationError, error == .selectionUnavailable {
          inputSource = .manual
          statusMessage = L10n.isChinese ? "就绪" : "Ready"
          return
        }
        statusMessage = L10n.isChinese ? "未能读取选中文本" : "Selection unavailable"
        errorMessage = error.localizedDescription
        if compact {
          SelectionPanelCoordinator.shared.show(model: self)
        } else {
          WindowCoordinator.showMain()
        }
      }
    }
  }

  func captureOCR() {
    NSApp.hide(nil)
    Task {
      do {
        let text = try await ocr.captureAndRecognize()
        inputText = text
        selectionContext = nil
        selectionDiagnostics = nil
        inputSource = .ocr
        restoredSourceLanguage = nil
        resetFollowUps()
        selectDefaultAction()
        WindowCoordinator.showMain()
        if settingsStore.settings.autoTranslate {
          self.translate()
        }
      } catch let error as TranslationError where error == .cancelled {
        WindowCoordinator.showMain()
        statusMessage = L10n.isChinese ? "已取消截屏识别" : "OCR cancelled"
      } catch let error as TranslationError where error == .noTextRecognized {
        // A crop that holds no text is an outcome, not a failure, and it is
        // reported the way an empty selection already is. The modal this used to
        // raise arrived while the window was still coming back from being hidden,
        // and its backing surfaces blocked the main thread in the render server
        // for most of a second — the beachball the user actually saw.
        WindowCoordinator.showMain()
        statusMessage = error.localizedDescription
      } catch {
        WindowCoordinator.showMain()
        errorMessage = error.localizedDescription
      }
    }
  }

  func translateFocusedInput() {
    Task {
      do {
        let original = try accessibility.currentEditableText()
        let settings = settingsStore.settings
        let source = LanguageDetector.detect(original)
        let action = TranslationAction.builtIns.first(where: { $0.mode == .translate })!
        let prompt = PromptBuilder.build(
          text: original,
          source: source,
          target: settings.writingTargetLanguage,
          action: action,
          writing: true
        )
        let (key, accountId) = try await settingsStore.validCredentials()
        var replacement = ""
        for try await chunk in client.stream(
          prompt: prompt,
          configuration: settings.provider,
          apiKey: key,
          accountId: accountId,
          proxy: settings.proxy
        ) {
          replacement += chunk
        }
        guard !replacement.isEmpty else { throw TranslationError.invalidResponse }
        try accessibility.replaceCurrentEditableText(with: replacement)
      } catch {
        errorMessage = error.localizedDescription
        WindowCoordinator.showMain()
      }
    }
  }

  func requestAccessibilityPermission() {
    updateAccessibilityPermission(
      accessibility.isTrusted(prompt: true)
    )
  }

  func refreshAccessibilityPermission() {
    updateAccessibilityPermission(accessibility.isTrusted())
  }

  func openAccessibilitySettings() {
    requestAccessibilityPermission()
    guard !isAccessibilityTrusted else { return }
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      ),
      NSWorkspace.shared.open(url)
    else {
      errorMessage = L10n.isChinese ? "无法打开辅助功能设置。" : "Could not open Accessibility settings."
      return
    }
  }

  func applyLaunchAtLogin(_ enabled: Bool) {
    do {
      try LaunchAtLoginService.setEnabled(enabled)
      settingsStore.settings.launchAtLogin = enabled
    } catch {
      errorMessage = error.localizedDescription
      settingsStore.settings.launchAtLogin = LaunchAtLoginService.isEnabled
    }
  }

  private func updateAccessibilityPermission(_ trusted: Bool) {
    isAccessibilityTrusted = trusted
    if trusted, isAccessibilityPermissionError {
      errorMessage = nil
    }
  }

  private func normalizedFavoriteLanguages() -> [LanguageCode] {
    let filtered = settingsStore.settings.favoriteLanguages
      .filter { $0 != .auto }
    let unique = filtered.reduce(into: [LanguageCode]()) { result, language in
      if !result.contains(language) { result.append(language) }
    }
    return unique.isEmpty ? [.simplifiedChinese, .japanese, .english] : unique
  }

  private func loadLibrary() async {
    do {
      async let loadedHistory = library.history()
      async let loadedVocabulary = library.vocabulary()
      async let loadedActions = library.customActions()
      history = try await loadedHistory
      vocabulary = try await loadedVocabulary
      customActions = try await loadedActions
      reconcileActionConfiguration()
      // A saved default may refer to a custom action, which is unavailable
      // until the library finishes loading. Apply it now instead of leaving
      // the temporary built-in fallback selected for the rest of the session.
      reconcileActionSelection(preferDefault: true)
    } catch {
      errorMessage = L10n.isChinese
        ? "无法载入本地资料库：\(error.localizedDescription)"
        : "Could not load local library: \(error.localizedDescription)"
    }
  }

  private func selectDefaultAction() {
    if let action = settingsStore.settings.resolvedDefaultAction(customActions: customActions) {
      selectedActionID = action.id
    }
  }

  /// Removes references to deleted actions and guarantees that both the saved
  /// default and the live selection resolve to a visible action.
  private func reconcileActionConfiguration() {
    let availableIDs = Set(
      (settingsStore.settings.resolvedBuiltInActions + customActions).map(\.id)
    )
    settingsStore.settings.actionOrder.removeAll { !availableIDs.contains($0) }
    settingsStore.settings.hiddenActionIDs.formIntersection(availableIDs)
    reconcileActionSelection()
  }

  private func reconcileActionSelection(preferDefault: Bool = false) {
    if visibleActions.isEmpty, let firstAvailable = orderedActions.first {
      settingsStore.settings.hiddenActionIDs.remove(firstAvailable.id)
    }
    guard
      let fallback = settingsStore.settings.resolvedDefaultAction(customActions: customActions)
    else { return }

    if settingsStore.settings.defaultActionID != fallback.id {
      settingsStore.settings.defaultActionID = fallback.id
    }
    if preferDefault || !visibleActions.contains(where: { $0.id == selectedActionID }) {
      selectedActionID = fallback.id
    }
  }
}

@MainActor
enum WindowCoordinator {
  static let mainWindowIdentifier = NSUserInterfaceItemIdentifier(
    "PhraseLens.MainWindow"
  )

  /// The main `WindowGroup`'s scene id, so a closed main window can be built
  /// again rather than the app quietly doing nothing when it is asked for.
  static let mainWindowSceneID = "PhraseLens.MainWindow"

  /// SwiftUI's `openWindow` action, captured by the main window's own content
  /// while it is on screen. Closing the last window tears the scene down but
  /// not the action, so this is what brings the window back afterwards.
  private static var openMainWindowScene: (() -> Void)?

  static func registerMainWindowOpener(_ open: @escaping () -> Void) {
    openMainWindowScene = open
  }

  static func showMain() {
    // The window inherits the pop-up's model, so a translation that is still
    // streaming carries on here rather than being cancelled out from under it.
    SelectionPanelCoordinator.shared.close(cancelsTranslation: false)
    let settings = AppDelegate.sharedModel?.settingsStore.settings
    NSApp.setActivationPolicy(settings?.showDockIcon == false ? .accessory : .regular)
    NSApp.activate(ignoringOtherApps: true)
    if let window = mainWindow() {
      raiseMainWindow(window)
      return
    }
    // The user closed the last main window, so there is nothing to raise:
    // ask SwiftUI for a new one and raise that once it exists. Without this
    // the request lands on whatever other window the app still owns.
    guard let openMainWindowScene else { return }
    openMainWindowScene()
    DispatchQueue.main.async {
      guard let window = mainWindow() else { return }
      raiseMainWindow(window)
    }
  }

  /// Brings a main window forward. It is raised above everything first because
  /// the request usually comes from a hotkey pressed in another app, then
  /// dropped back to its configured level once it holds focus.
  private static func raiseMainWindow(_ window: NSWindow) {
    let settings = AppDelegate.sharedModel?.settingsStore.settings
    window.level = .floating
    window.makeKeyAndOrderFront(nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      if !window.isKeyWindow {
        window.makeKeyAndOrderFront(nil)
      }
      window.level = settings?.alwaysOnTop == true ? .floating : .normal
    }
  }

  /// Clears the way for the Settings scene before it is opened.
  ///
  /// The selection pop-up is a non-activating panel, usually on an app with no
  /// Dock icon, so nothing has activated the app by the time Settings is asked
  /// for: without this the window opens behind whatever the user was reading.
  /// The pop-up is handed off rather than dismissed, so a translation it was
  /// running survives the trip.
  static func prepareForSettings() {
    SelectionPanelCoordinator.shared.close(cancelsTranslation: false)
    let settings = AppDelegate.sharedModel?.settingsStore.settings
    NSApp.setActivationPolicy(settings?.showDockIcon == false ? .accessory : .regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// A window restored onto a display that no longer exists is resized by
  /// AppKit *after* the split view has laid out for the saved size, which
  /// leaves the sidebar and the detail column clipped until the user resizes
  /// the window. Re-applying the frame forces one correct layout pass.
  static func revalidateMainWindowLayout() {
    guard let window = mainWindow() else { return }
    let frame = window.frame
    var nudged = frame
    nudged.size.width -= 1
    window.setFrame(nudged, display: false)
    window.setFrame(frame, display: true)
  }

  /// Claims a window as the main one.
  ///
  /// Called from the main window's own content view, which is the only place
  /// that knows for certain which window it is: every other test is a guess
  /// from the outside, and guessing once cost the app a Settings window
  /// standing in for the translator.
  static func adoptMainWindow(_ window: NSWindow) {
    window.identifier = mainWindowIdentifier
    guard !window.styleMask.contains(.fullSizeContentView) else { return }
    configureChrome(of: window)
  }

  /// Last-resort identification for a main window that has not adopted itself
  /// yet — during launch, before its content view has a window. The Settings
  /// window is excluded outright: it is the same shape as the main window, so
  /// a match on size alone would hand it back as the translator.
  static func tagMainWindowIfNeeded() {
    let candidates = NSApp.windows.filter {
      $0.identifier != mainWindowIdentifier && $0.canBecomeKey && !($0 is NSPanel)
        && !isSettingsWindow($0)
    }
    guard
      let window = candidates.first(where: { $0.title == "PhraseLens" })
        ?? candidates.first(where: { $0.frame.width >= AppMetrics.windowMinWidth })
    else { return }
    adoptMainWindow(window)
  }

  /// The app draws its own top bar, so the window's content has to reach the
  /// top edge. `.hiddenTitleBar` hides the title and makes the bar
  /// transparent, but it leaves the content below the bar: without
  /// `fullSizeContentView` the sidebar starts 28pt down and the gap it
  /// reserves for the traffic lights lands under them instead of behind them.
  ///
  /// SwiftUI re-applies the scene's own style mask after launch, so this also
  /// runs from `WindowChrome` once the content view has a window.
  static func configureChrome(of window: NSWindow) {
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    // Content, not chrome, fills the bar area now, so dragging from anywhere
    // in the window would start a move the moment a drag misses a control.
    window.isMovableByWindowBackground = false
  }

  static func mainWindow() -> NSWindow? {
    if let tagged = taggedMainWindow() {
      return tagged
    }
    tagMainWindowIfNeeded()
    return taggedMainWindow()
  }

  /// The tag is checked against the Settings window as well, so a stale tag
  /// left by an earlier mis-identification cannot keep answering for the
  /// translator.
  private static func taggedMainWindow() -> NSWindow? {
    NSApp.windows.first {
      $0.identifier == mainWindowIdentifier && !isSettingsWindow($0)
    }
  }

  /// The SwiftUI `Settings` scene's window, which macOS may restore or
  /// auto-present during launch or activation.
  static func settingsWindow() -> NSWindow? {
    NSApp.windows.first(where: isSettingsWindow)
  }

  /// Settings keeps its title even with the title bar hidden, and SwiftUI
  /// stamps its own identifier on the scene, so either one identifies it.
  private static func isSettingsWindow(_ window: NSWindow) -> Bool {
    window.title == "PhraseLens Settings"
      || (window.identifier?.rawValue.contains("SwiftUI_Settings") ?? false)
  }

  /// Dismisses a Settings window that macOS or SwiftUI presented without an
  /// explicit user action. Settings should only appear on request.
  static func dismissAutoPresentedSettingsWindow() {
    guard let window = settingsWindow() else { return }
    window.isRestorable = false
    if window.isVisible {
      window.close()
    }
  }
}
