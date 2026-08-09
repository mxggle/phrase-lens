import AppKit
import Combine
import Foundation

enum InputSource: Sendable {
  case manual
  case selection
  case ocr
  case history
}

@MainActor
final class AppModel: ObservableObject {
  @Published var inputText = ""
  @Published var outputText = ""
  @Published private(set) var outputUsesMarkdown = false
  @Published var selectedActionID = TranslationAction.builtIns[0].id
  @Published var selectionContext: String?
  @Published var inputSource: InputSource = .manual
  @Published var isSelectionExpanded = false
  @Published var isTranslating = false
  @Published var statusMessage = "Ready"
  @Published var errorMessage: String?
  @Published var history: [HistoryEntry] = []
  @Published var vocabulary: [VocabularyEntry] = []
  @Published var customActions: [TranslationAction] = []
  @Published var shortcutErrors: [String] = []
  @Published private(set) var isAccessibilityTrusted = false

  let settingsStore: SettingsStore
  let speech = SpeechService()

  private let client = TranslationClient()
  private let library = LibraryStore()
  private let accessibility = AccessibilityService()
  private let ocr = OCRService()
  private var translationTask: Task<Void, Never>?
  private var requestID = UUID()
  private var selectionCaptureID = UUID()
  private var cancellables = Set<AnyCancellable>()

  init(settingsStore: SettingsStore = SettingsStore()) {
    self.settingsStore = settingsStore
    isAccessibilityTrusted = accessibility.isTrusted()
    selectedActionID = settingsStore.settings.defaultActionID
    speech.$errorMessage
      .compactMap { $0 }
      .sink { [weak self] message in self?.errorMessage = message }
      .store(in: &cancellables)
    Task { await loadLibrary() }
    configureHotKeys()
  }

  var allActions: [TranslationAction] {
    TranslationAction.builtIns + customActions
  }

  var selectedAction: TranslationAction {
    allActions.first(where: { $0.id == selectedActionID })
      ?? TranslationAction.builtIns[0]
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
    errorMessage = nil
    isTranslating = true
    statusMessage = "Connecting to \(settingsStore.settings.provider.provider.rawValue)…"

    let settings = settingsStore.settings
    let source =
      settings.sourceLanguage == .auto
      ? LanguageDetector.detect(text)
      : settings.sourceLanguage
    let target = settings.targetLanguage
    let action = selectedAction
    outputUsesMarkdown = action.outputMarkdown
    let context = selectionContext
    let prompt = PromptBuilder.build(
      text: text,
      source: source,
      target: target,
      action: action,
      selectionContext: context
    )
    let configuration = settings.provider
    let key = settingsStore.apiKey
    let proxy = settings.proxy

    translationTask = Task {
      do {
        for try await chunk in client.stream(
          prompt: prompt,
          configuration: configuration,
          apiKey: key,
          proxy: proxy
        ) {
          guard requestID == activeRequest else { return }
          outputText += chunk
          statusMessage = "Translating…"
        }
        guard requestID == activeRequest else { return }
        isTranslating = false
        statusMessage = "Completed"
        guard !outputText.isEmpty else {
          throw TranslationError.invalidResponse
        }
        let entry = HistoryEntry(
          sourceText: text,
          translatedText: outputText,
          sourceLanguage: source,
          targetLanguage: target,
          actionName: action.name,
          provider: configuration.provider,
          model: configuration.model,
          selectionContext: context
        )
        try await library.addHistory(entry)
        history.insert(entry, at: 0)
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
        isTranslating = false
        statusMessage = "Stopped"
      } catch {
        guard requestID == activeRequest else { return }
        isTranslating = false
        statusMessage = "Failed"
        errorMessage = error.localizedDescription
      }
    }
  }

  func stopTranslation() {
    requestID = UUID()
    translationTask?.cancel()
    translationTask = nil
    isTranslating = false
    statusMessage = "Stopped"
  }

  func clear() {
    stopTranslation()
    inputText = ""
    outputText = ""
    outputUsesMarkdown = false
    selectionContext = nil
    inputSource = .manual
    isSelectionExpanded = false
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
      outputUsesMarkdown = false
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
      let language =
        settings.sourceLanguage == .auto
        ? LanguageDetector.detect(text)
        : settings.sourceLanguage
      speech.speak(
        text,
        language: language,
        rate: settings.speechRate,
        volume: settings.speechVolume,
        provider: settings.resolvedTTSProvider
      )
    }
  }

  func collectCurrentWord() {
    let word = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !word.isEmpty, !outputText.isEmpty else { return }
    let settings = settingsStore.settings
    let entry = VocabularyEntry(
      word: word,
      explanation: outputText,
      sourceLanguage: settings.sourceLanguage,
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
    inputText = entry.sourceText
    outputText = entry.translatedText
    selectionContext = entry.selectionContext
    inputSource = .history
    settingsStore.settings.sourceLanguage = entry.sourceLanguage
    settingsStore.settings.targetLanguage = entry.targetLanguage
    if let action = allActions.first(where: { $0.name == entry.actionName }) {
      selectedActionID = action.id
      outputUsesMarkdown = action.outputMarkdown
    } else {
      outputUsesMarkdown = false
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
    Task {
      do {
        try await library.saveCustomActions(actions)
        statusMessage = "Actions saved"
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func configureHotKeys() {
    shortcutErrors = GlobalHotKeyManager.shared.register(
      shortcuts: settingsStore.settings.shortcuts
    ) { [weak self] action, sourceProcessIdentifier in
      self?.handleHotKey(action, sourceProcessIdentifier: sourceProcessIdentifier)
    }
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
    outputUsesMarkdown = false
    selectionContext = nil
    inputSource = .selection
    isSelectionExpanded = false
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
        let preferredMode: ActionMode =
          PromptBuilder.hasMeaningfulContext(snapshot.surroundingText, for: snapshot.text)
          ? .explainContext
          : .translate
        if let action = TranslationAction.builtIns.first(where: { $0.mode == preferredMode }) {
          selectedActionID = action.id
        }
        if compact {
          SelectionPanelCoordinator.shared.show(
            model: self,
            anchorScreenRect: snapshot.screenRect
          )
        } else {
          WindowCoordinator.showMain()
        }
        if settingsStore.settings.autoTranslate {
          translate()
        }
      } catch {
        guard selectionCaptureID == activeCapture else { return }
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
        isSelectionExpanded = true
        if let translate = TranslationAction.builtIns.first(where: { $0.mode == .translate }) {
          selectedActionID = translate.id
        }
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
        var replacement = ""
        for try await chunk in client.stream(
          prompt: prompt,
          configuration: settings.provider,
          apiKey: settingsStore.apiKey,
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
    } catch {
      errorMessage = "Could not load local library: \(error.localizedDescription)"
    }
  }
}

@MainActor
enum WindowCoordinator {
  static let mainWindowIdentifier = NSUserInterfaceItemIdentifier(
    "NextAITranslatorNative.MainWindow"
  )

  static func showMain() {
    SelectionPanelCoordinator.shared.close()
    let settings = AppDelegate.sharedModel?.settingsStore.settings
    NSApp.setActivationPolicy(settings?.showDockIcon == false ? .accessory : .regular)
    NSApp.activate(ignoringOtherApps: true)
    if let window = mainWindow() {
      window.level = .floating
      window.makeKeyAndOrderFront(nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        if !window.isKeyWindow {
          window.makeKeyAndOrderFront(nil)
        }
        window.level = settings?.alwaysOnTop == true ? .floating : .normal
      }
    }
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

  static func tagMainWindowIfNeeded() {
    guard
      let window = NSApp.windows.first(where: {
        $0.identifier != mainWindowIdentifier
          && $0.canBecomeKey
          && $0.frame.width >= 760
      })
    else { return }
    window.identifier = mainWindowIdentifier
  }

  static func mainWindow() -> NSWindow? {
    if let tagged = NSApp.windows.first(where: {
      $0.identifier == mainWindowIdentifier
    }) {
      return tagged
    }
    tagMainWindowIfNeeded()
    return NSApp.windows.first(where: {
      $0.identifier == mainWindowIdentifier
    })
  }
}
