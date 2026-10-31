import AppKit
import Foundation

/// One translation of the draft, in one style.
struct ComposeDraft: Equatable, Sendable {
  var text = ""
  var isStreaming = true
  var error: String?
}

/// The writing shortcut's pop-up: the message drafted in another app, its
/// translation in the chosen style, and the write back over the draft.
///
/// Kept apart from the translator's own model on purpose. Writing a message
/// must not clear what the main window is showing, and a lookup must not
/// cancel a message half written.
@MainActor
final class ComposeModel: ObservableObject {
  @Published private(set) var sourceText = ""
  @Published private(set) var style = WritingStyle(language: .japanese, register: .polite)
  /// Every style tried on this draft, so switching back to one is instant.
  @Published private(set) var drafts: [WritingStyle: ComposeDraft] = [:]
  /// Fixed when the draft is read, so picking Japanese does not take away a
  /// third language the pop-up opened with.
  @Published private(set) var languageOptions = WritingStyle.languageOptions(including: [])
  /// Why the draft could not be read, or the translation could not be written.
  @Published private(set) var errorMessage: String?
  /// The translation went to the clipboard after a write that failed.
  @Published private(set) var copiedAfterFailure = false
  @Published private(set) var isAccessibilityPermissionMissing = false
  /// Enter was pressed while the translation was still arriving. It is
  /// written the moment it finishes.
  @Published private(set) var replacesWhenFinished = false
  /// Changes with every draft read, so the pop-up can put the caret back in
  /// its editor, and so a request started for an earlier draft can tell it
  /// has been overtaken.
  @Published private(set) var sessionID = UUID()

  let settingsStore: SettingsStore
  private let client = TranslationClient()
  private let accessibility = AccessibilityService()
  private var capture: ComposeCapture?
  private var tasks: [WritingStyle: Task<Void, Never>] = [:]

  init(settingsStore: SettingsStore) {
    self.settingsStore = settingsStore
  }

  /// Whether there is a draft on screen, as opposed to only a reason there is not.
  var hasDraft: Bool { capture != nil }
  var applicationName: String? { capture?.target.applicationName }
  var currentDraft: ComposeDraft? { drafts[style] }
  var isStreaming: Bool { currentDraft?.isStreaming == true }

  /// The translation in the current style, as the reader has edited it. Edits
  /// are refused while it is still arriving: the next chunk would erase them.
  var translation: String {
    get { drafts[style]?.text ?? "" }
    set {
      guard var draft = drafts[style], !draft.isStreaming, draft.text != newValue else { return }
      draft.text = newValue
      drafts[style] = draft
    }
  }

  var canReplace: Bool {
    guard capture != nil, let draft = currentDraft, draft.error == nil else { return false }
    return draft.isStreaming || !WriteBackComposer.clean(draft.text).isEmpty
  }

  /// Whether the current failure is one only Settings can fix.
  var isConfigurationError: Bool {
    guard let error = currentDraft?.error else { return false }
    return error == TranslationError.missingAPIKey.localizedDescription
      || error == TranslationError.missingOAuthCredentials.localizedDescription
      || error.hasPrefix(TranslationError.invalidEndpoint("").localizedDescription)
  }

  // MARK: - Opening and closing

  /// The writing shortcut: opens the pop-up on the focused control's text,
  /// or puts it away when it is already open.
  func toggle(sourceProcessIdentifier: pid_t?) {
    if ComposePanelCoordinator.shared.isVisible {
      cancel()
      return
    }
    SelectionPanelCoordinator.shared.close()
    let processIdentifier =
      sourceProcessIdentifier ?? ActiveApplicationTracker.shared.lastExternalProcessIdentifier
    let allowCopyFallback = settingsStore.settings.useClipboardFallback
    Task {
      do {
        let capture = try await accessibility.composeCapture(
          from: processIdentifier,
          allowCopyFallback: allowCopyFallback
        )
        begin(with: capture)
      } catch {
        fail(error)
      }
    }
  }

  /// Escape, the close button, or a click elsewhere: nothing is written.
  func cancel() {
    cancelRequests()
    capture = nil
    replacesWhenFinished = false
    sessionID = UUID()
    ComposePanelCoordinator.shared.close()
  }

  private func begin(with capture: ComposeCapture) {
    cancelRequests()
    self.capture = capture
    sourceText = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
    style = settingsStore.settings.writingStyle(forApp: capture.bundleIdentifier)
    languageOptions = WritingStyle.languageOptions(
      including: [settingsStore.settings.writingTargetLanguage, style.language]
    )
    drafts = [:]
    errorMessage = nil
    copiedAfterFailure = false
    isAccessibilityPermissionMissing = false
    replacesWhenFinished = false
    sessionID = UUID()
    request(style)
    ComposePanelCoordinator.shared.show(model: self, anchor: capture.anchorRect)
  }

  /// Nothing to translate. Saying so beats a shortcut that silently does
  /// nothing, which reads as broken.
  private func fail(_ error: Error) {
    cancelRequests()
    capture = nil
    sourceText = ""
    drafts = [:]
    copiedAfterFailure = false
    replacesWhenFinished = false
    let translationError = error as? TranslationError
    isAccessibilityPermissionMissing = translationError == .accessibilityPermissionRequired
    let shortcut = settingsStore.settings.shortcuts.writing
    switch translationError {
    case .noInput?:
      errorMessage = L10n.isChinese
        ? "输入框是空的。先在里面写好要发的内容，再按 \(shortcut)。"
        : "The field is empty. Write your message there first, then press \(shortcut)."
    case .focusedInputUnavailable?, .selectionUnavailable?:
      errorMessage = L10n.isChinese
        ? "没有找到可以写入的输入框。把光标放进聊天输入框，再按 \(shortcut)。"
        : "No text field to write into. Put the cursor in the message box, then press \(shortcut)."
    default:
      errorMessage = error.localizedDescription
    }
    sessionID = UUID()
    ComposePanelCoordinator.shared.show(model: self, anchor: nil)
  }

  func openAccessibilitySettings() {
    _ = accessibility.isTrusted(prompt: true)
    cancel()
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
      NSWorkspace.shared.open(url)
    }
  }

  // MARK: - Style

  func select(_ register: WritingRegister) {
    choose(WritingStyle(language: style.language, register: register))
  }

  func select(_ language: LanguageCode) {
    choose(WritingStyle(language: language, register: style.register))
  }

  func cycleRegister(backwards: Bool = false) {
    select(backwards ? style.register.previous : style.register.next)
  }

  func cycleLanguage() {
    let options = languageOptions
    let index = options.firstIndex(of: style.language) ?? 0
    select(options[(index + 1) % options.count])
  }

  /// Asks again for the current style, for a different wording.
  func regenerate() {
    guard capture != nil, !isStreaming else { return }
    drafts[style] = nil
    request(style)
  }

  private func choose(_ next: WritingStyle) {
    guard capture != nil, next != style else { return }
    style = next
    // Pressed Enter early, then changed the style: the wait was for the
    // translation that is no longer on screen.
    replacesWhenFinished = false
    remember(next)
    request(next)
  }

  /// Files a style as the one used in this app. Settings are only written
  /// when that changes anything, since every write re-renders every window.
  private func remember(_ style: WritingStyle) {
    let app = capture?.bundleIdentifier
    guard !settingsStore.settings.remembersWritingStyle(style, forApp: app) else { return }
    settingsStore.settings.rememberWritingStyle(style, forApp: app)
  }

  // MARK: - Translating

  private func request(_ style: WritingStyle) {
    if let draft = drafts[style], draft.error == nil { return }
    tasks[style]?.cancel()
    drafts[style] = ComposeDraft()
    let prompt = PromptBuilder.writing(text: sourceText, style: style)
    let settings = settingsStore.settings
    // The connection and model chosen for Translate, so a message is written
    // by the same model that reads one.
    let action = settings.resolvedBuiltInActions.first { $0.mode == .translate }
      ?? TranslationAction.builtIn(for: .translate)
    let session = sessionID

    tasks[style] = Task { [weak self] in
      guard let self else { return }
      var streamed = ""
      do {
        let (connection, configuration) = try settingsStore.resolve(action)
        let (key, accountId) = try await settingsStore.validCredentials(
          for: connection,
          proxy: settings.proxy
        )
        let clock = ContinuousClock()
        var nextUpdate = clock.now
        for try await chunk in client.stream(
          prompt: prompt,
          configuration: configuration,
          apiKey: key,
          accountId: accountId,
          proxy: settings.proxy
        ) {
          guard sessionID == session, !Task.isCancelled else { return }
          streamed.append(chunk)
          let now = clock.now
          if now >= nextUpdate {
            drafts[style]?.text = streamed
            nextUpdate = now.advanced(by: .milliseconds(50))
          }
        }
        guard sessionID == session, !Task.isCancelled else { return }
        let text = WriteBackComposer.clean(streamed)
        guard !text.isEmpty else { throw TranslationError.invalidResponse }
        drafts[style] = ComposeDraft(text: text, isStreaming: false)
        if style == self.style, replacesWhenFinished {
          replacesWhenFinished = false
          replace()
        }
      } catch {
        guard sessionID == session, !Task.isCancelled else { return }
        drafts[style] = ComposeDraft(text: streamed, isStreaming: false, error: error.localizedDescription)
        if style == self.style { replacesWhenFinished = false }
      }
    }
  }

  private func cancelRequests() {
    tasks.values.forEach { $0.cancel() }
    tasks = [:]
  }

  // MARK: - Writing back

  /// Enter: writes the translation over the draft. Pressed while the
  /// translation is still arriving, it waits for the end of it.
  func replace() {
    guard let capture, let draft = currentDraft, draft.error == nil else { return }
    guard !draft.isStreaming else {
      replacesWhenFinished = true
      return
    }
    let text = WriteBackComposer.clean(draft.text)
    guard !text.isEmpty else { return }
    // Sending in the style the pop-up opened with is a choice too: without
    // this, an app that was never switched would follow the next app that is.
    remember(style)
    cancelRequests()
    errorMessage = nil
    copiedAfterFailure = false
    // The pop-up holds key focus, and the field it is writing into needs it
    // back first. No exit animation: the text landing is the feedback.
    ComposePanelCoordinator.shared.close(animated: false)
    Task {
      do {
        _ = try await accessibility.replaceComposed(text, in: capture)
        self.capture = nil
      } catch {
        // The translation must not be lost to a failed write: it goes on the
        // clipboard, and the pop-up comes back to say why.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedAfterFailure = true
        errorMessage = error.localizedDescription
        ComposePanelCoordinator.shared.show(model: self, anchor: capture.anchorRect)
      }
    }
  }

  func copyTranslation() {
    let text = WriteBackComposer.clean(translation)
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
