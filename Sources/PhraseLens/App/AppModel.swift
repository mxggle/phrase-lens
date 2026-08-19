import AppKit
import Combine
import Foundation

enum InputSource: Sendable {
  case manual
  case selection
  case ocr
  case history
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

@MainActor
final class AppModel: ObservableObject {
  @Published var inputText = ""
  @Published var outputText = ""
  @Published private(set) var outputRendering: OutputRendering = .plain
  @Published var selectedActionID = TranslationAction.builtIns[0].id
  @Published var selectionContext: String?
  @Published var inputSource: InputSource = .manual
  @Published var isSelectionExpanded = false
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
  @Published var statusMessage = "Ready"
  @Published var errorMessage: String?
  @Published var history: [HistoryEntry] = []
  @Published var vocabulary: [VocabularyEntry] = []
  @Published var customActions: [TranslationAction] = []
  @Published var shortcutErrors: [String] = []
  @Published private(set) var isAccessibilityTrusted = false

  let settingsStore: SettingsStore
  let modelCatalog = ModelCatalogStore()
  let speech = SpeechService()

  private let client = TranslationClient()
  private let library = LibraryStore()
  private let accessibility = AccessibilityService()
  private let ocr = OCRService()
  private var translationTask: Task<Void, Never>?
  private var followUpTask: Task<Void, Never>?
  private var requestID = UUID()
  private var followUpRequestID = UUID()
  /// The history row the current result was filed under, so a thread built on
  /// top of it is saved to that same row instead of to a new one.
  private var currentHistoryID: UUID?
  private var selectionCaptureID = UUID()
  private var restoredSourceLanguage: LanguageCode?
  private var cancellables = Set<AnyCancellable>()

  init(settingsStore: SettingsStore = SettingsStore()) {
    self.settingsStore = settingsStore
    isAccessibilityTrusted = accessibility.isTrusted()
    selectedActionID =
      settingsStore.settings.resolvedDefaultAction(customActions: [])?.id
      ?? TranslationAction.builtIns[0].id
    speech.$errorMessage
      .compactMap { $0 }
      .sink { [weak self] message in self?.errorMessage = message }
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
    Task { await loadLibrary() }
    configureHotKeys()
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

  func translate() {
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
    errorMessage = nil
    isTranslating = true
    statusMessage = "Connecting to \(settingsStore.settings.provider.provider.rawValue)…"

    let settings = settingsStore.settings
    let source = TranslationSourceResolver.resolve(
      text,
      configuredSource: settings.sourceLanguage,
      inputSource: inputSource,
      restoredSource: restoredSourceLanguage
    )
    let target = settings.targetLanguage
    let action = selectedAction
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
            statusMessage = "Translating…"
            nextUIUpdate = now.advanced(by: .milliseconds(50))
          }
        }
        guard requestID == activeRequest else { return }
        outputText = streamedText
        isTranslating = false
        statusMessage = "Completed"
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
        }
      } catch let error as TranslationError where error == .cancelled {
        guard requestID == activeRequest else { return }
        outputText = streamedText
        isTranslating = false
        statusMessage = "Stopped"
      } catch {
        guard requestID == activeRequest else { return }
        outputText = streamedText
        isTranslating = false
        statusMessage = "Failed"
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
    requestID = UUID()
    translationTask?.cancel()
    translationTask = nil
    isTranslating = false
    stopFollowUp()
    statusMessage = "Stopped"
  }

  func clear() {
    stopTranslation()
    inputText = ""
    outputText = ""
    outputRendering = .plain
    selectionContext = nil
    inputSource = .manual
    restoredSourceLanguage = nil
    isSelectionExpanded = false
    resetFollowUps()
    errorMessage = nil
    statusMessage = "Ready"
  }

  func swapLanguages() {
    let source = settingsStore.settings.sourceLanguage
    guard source != .auto else { return }
    settingsStore.settings.sourceLanguage = settingsStore.settings.targetLanguage
    settingsStore.settings.targetLanguage = source
    if !outputText.isEmpty {
      let previousInput = inputText
      inputText = outputText
      outputText = previousInput
      outputRendering = .plain
      // The questions were asked about the answer that just became the input.
      resetFollowUps()
    }
  }

  func copyOutput() {
    guard !outputText.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(outputText, forType: .string)
    statusMessage = "Copied"
  }

  func speakInput() {
    if speech.isSpeaking {
      speech.stop()
    } else {
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
    }
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
    statusMessage = "Answering…"

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
        statusMessage = "Completed"
        await persistFollowUps()
      } catch let error as TranslationError where error == .cancelled {
        guard followUpRequestID == activeRequest else { return }
        await settleFollowUp(turn.id, question: question, text: streamedText, status: "Stopped")
      } catch {
        guard followUpRequestID == activeRequest else { return }
        await settleFollowUp(
          turn.id,
          question: question,
          text: streamedText,
          status: "Failed",
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
    statusMessage = "Copied"
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
      $0.word.localizedCaseInsensitiveCompare(word) == .orderedSame
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
        statusMessage = "Removed from vocabulary"
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
    let entry = VocabularyEntry(
      word: word,
      explanation: outputText,
      sourceLanguage: source,
      targetLanguage: settings.targetLanguage
    )
    Task {
      do {
        try await library.addVocabulary(entry)
        vocabulary.removeAll {
          $0.word.localizedCaseInsensitiveCompare(word) == .orderedSame
        }
        vocabulary.insert(entry, at: 0)
        statusMessage = "Added to vocabulary"
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func restore(_ entry: HistoryEntry) {
    stopTranslation()
    resetFollowUps()
    inputText = entry.sourceText
    outputText = entry.translatedText
    selectionContext = entry.selectionContext
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
    WindowCoordinator.showMain()
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
        statusMessage = "Actions saved"
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
    inputSource = .selection
    restoredSourceLanguage = nil
    isSelectionExpanded = false
    resetFollowUps()
    errorMessage = nil
    statusMessage = "Reading selection…"

    Task {
      do {
        let snapshot = try await accessibility.currentSelection(
          from: sourceProcessIdentifier,
          allowCopyFallback: settingsStore.settings.useClipboardFallback
        )
        guard selectionCaptureID == activeCapture else { return }
        guard !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw TranslationError.selectionUnavailable
        }
        inputText = snapshot.text
        selectionContext = snapshot.surroundingText
        statusMessage = "Ready"
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
          statusMessage = "Ready"
          return
        }
        statusMessage = "Selection unavailable"
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
        inputSource = .ocr
        restoredSourceLanguage = nil
        resetFollowUps()
        isSelectionExpanded = true
        selectDefaultAction()
        WindowCoordinator.showMain()
        if settingsStore.settings.autoTranslate {
          self.translate()
        }
      } catch let error as TranslationError where error == .cancelled {
        WindowCoordinator.showMain()
        statusMessage = "OCR cancelled"
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
      errorMessage = "Could not open Accessibility settings."
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
      errorMessage = "Could not load local library: \(error.localizedDescription)"
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
