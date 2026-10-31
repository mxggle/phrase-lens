import AppKit
import Foundation

/// One answer for the draft, from one action in one style.
struct ComposeDraft: Equatable, Sendable {
  var text = ""
  var isStreaming = true
  var error: String?
}

/// What one answer was asked for: an action, a language when the action
/// writes into one, and the option picked under it.
struct ComposeRequestKey: Hashable, Sendable {
  var actionID: UUID
  var language: LanguageCode
  var optionID: UUID?
}

/// The writing shortcut's pop-up: the message drafted in another app, an
/// action's answer for it, and the write back over the draft.
///
/// The actions are the reader's own, from the action list: Compose and
/// Polish to begin with, and any other action switched on for writing. An
/// action with options gets a row of them, and one that uses `${targetLang}`
/// gets the language switch.
///
/// Kept apart from the translator's own model on purpose. Writing a message
/// must not clear what the main window is showing, and a lookup must not
/// cancel a message half written.
@MainActor
final class ComposeModel: ObservableObject {
  @Published private(set) var sourceText = ""
  @Published private(set) var style = WritingStyle(language: .japanese)
  /// The option picked under the current action, or nil for none.
  @Published private(set) var currentOption: ActionOption?
  /// Every action, language and option tried on this draft, so switching
  /// back to one is instant.
  @Published private(set) var drafts: [ComposeRequestKey: ComposeDraft] = [:]
  /// The actions on offer, read once per draft so a settings change cannot
  /// pull the tab that is on screen out from under the reader.
  @Published private(set) var actions: [TranslationAction] = []
  /// Fixed when the draft is read, so picking Japanese does not take away a
  /// third language the pop-up opened with.
  @Published private(set) var languageOptions = WritingStyle.languageOptions(including: [])
  /// Why the draft could not be read, or the answer could not be written.
  @Published private(set) var errorMessage: String?
  /// The answer went to the clipboard after a write that failed.
  @Published private(set) var copiedAfterFailure = false
  @Published private(set) var isAccessibilityPermissionMissing = false
  /// Enter was pressed while the answer was still arriving. It is written
  /// the moment it finishes.
  @Published private(set) var replacesWhenFinished = false
  /// Changes with every draft read, so the pop-up can put the caret back in
  /// its editor, and so a request started for an earlier draft can tell it
  /// has been overtaken.
  @Published private(set) var sessionID = UUID()

  let settingsStore: SettingsStore
  private let client = TranslationClient()
  private let accessibility = AccessibilityService()
  private var capture: ComposeCapture?
  private var tasks: [ComposeRequestKey: Task<Void, Never>] = [:]

  init(settingsStore: SettingsStore) {
    self.settingsStore = settingsStore
  }

  /// Whether there is a draft on screen, as opposed to only a reason there is not.
  var hasDraft: Bool { capture != nil }
  var applicationName: String? { capture?.target.applicationName }
  var currentAction: TranslationAction? { actions.first { $0.id == style.actionID } }
  /// The current action's options, shown as a row under the tabs.
  var options: [ActionOption] { currentAction?.availableOptions ?? [] }
  var showsLanguages: Bool { currentAction?.usesTargetLanguage == true }
  var currentDraft: ComposeDraft? { drafts[currentKey] }
  private var currentKey: ComposeRequestKey { requestKey(for: style, option: currentOption) }
  var isStreaming: Bool { currentDraft?.isStreaming == true }

  /// The answer in the current style, as the reader has edited it. Edits
  /// are refused while it is still arriving: the next chunk would erase them.
  var translation: String {
    get { currentDraft?.text ?? "" }
    set {
      let key = currentKey
      guard var draft = drafts[key], !draft.isStreaming, draft.text != newValue else { return }
      draft.text = newValue
      drafts[key] = draft
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
  /// or puts it away when it is already open. `actions` are the ones
  /// switched on for writing, in the action list's order.
  func toggle(sourceProcessIdentifier: pid_t?, actions: [TranslationAction]) {
    if ComposePanelCoordinator.shared.isVisible {
      cancel()
      return
    }
    SelectionPanelCoordinator.shared.close()
    guard !actions.isEmpty else {
      fail(message: L10n.isChinese
        ? "还没有写作时可用的动作。在“动作”里选一个动作，打开“写作时可用”。"
        : "No action is set up for writing. In Actions, pick one and turn on “Use when writing”.")
      return
    }
    let processIdentifier =
      sourceProcessIdentifier ?? ActiveApplicationTracker.shared.lastExternalProcessIdentifier
    let allowCopyFallback = settingsStore.settings.useClipboardFallback
    Task {
      do {
        let capture = try await accessibility.composeCapture(
          from: processIdentifier,
          allowCopyFallback: allowCopyFallback
        )
        begin(with: capture, actions: actions)
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

  private func begin(with capture: ComposeCapture, actions: [TranslationAction]) {
    cancelRequests()
    let settings = settingsStore.settings
    self.capture = capture
    self.actions = actions
    sourceText = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
    var style = settings.writingStyle(forApp: capture.bundleIdentifier)
    // An action deleted since this app last used it gives way to the first
    // one, rather than to a pop-up with nothing chosen.
    if !actions.contains(where: { $0.id == style.actionID }) { style.actionID = actions[0].id }
    self.style = style
    currentOption = chosenOption(for: style.actionID)
    languageOptions = WritingStyle.languageOptions(
      including: [settings.writingTargetLanguage, style.language]
    )
    drafts = [:]
    errorMessage = nil
    copiedAfterFailure = false
    isAccessibilityPermissionMissing = false
    replacesWhenFinished = false
    sessionID = UUID()
    request(style, option: currentOption)
    ComposePanelCoordinator.shared.show(model: self, anchor: capture.anchorRect)
  }

  /// Nothing to work on. Saying so beats a shortcut that silently does
  /// nothing, which reads as broken.
  private func fail(_ error: Error) {
    let translationError = error as? TranslationError
    let shortcut = settingsStore.settings.shortcuts.writing
    let message: String
    switch translationError {
    case .noInput?:
      message = L10n.isChinese
        ? "输入框是空的。先在里面写好要发的内容，再按 \(shortcut)。"
        : "The field is empty. Write your message there first, then press \(shortcut)."
    case .focusedInputUnavailable?, .selectionUnavailable?:
      message = L10n.isChinese
        ? "没有找到可以写入的输入框。把光标放进聊天输入框，再按 \(shortcut)。"
        : "No text field to write into. Put the cursor in the message box, then press \(shortcut)."
    default:
      message = error.localizedDescription
    }
    fail(message: message, permissionMissing: translationError == .accessibilityPermissionRequired)
  }

  private func fail(message: String, permissionMissing: Bool = false) {
    cancelRequests()
    capture = nil
    sourceText = ""
    drafts = [:]
    copiedAfterFailure = false
    replacesWhenFinished = false
    isAccessibilityPermissionMissing = permissionMissing
    errorMessage = message
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

  // MARK: - Choosing

  func select(action id: UUID) {
    var next = style
    next.actionID = id
    choose(next, option: chosenOption(for: id))
  }

  /// Clicking an option picks it; clicking the picked one again takes it off.
  func toggle(option id: UUID) {
    guard capture != nil, let option = options.first(where: { $0.id == id }) else { return }
    pick(currentOption?.id == id ? nil : option)
  }

  func select(_ language: LanguageCode) {
    var next = style
    next.language = language
    choose(next, option: currentOption)
  }

  /// The action at a position in the tab row, for ⌘1 to ⌘9.
  func selectAction(at index: Int) {
    guard actions.indices.contains(index) else { return }
    select(action: actions[index].id)
  }

  func cycleAction(backwards: Bool = false) {
    guard let index = actions.firstIndex(where: { $0.id == style.actionID }) else { return }
    select(action: actions[Self.wrapped(index, backwards: backwards, count: actions.count)].id)
  }

  /// Tab and ⇧Tab: the next option along, starting from the first when
  /// none is picked.
  func cycleOption(backwards: Bool = false) {
    guard capture != nil, !options.isEmpty else { return }
    guard let index = options.firstIndex(where: { $0.id == currentOption?.id }) else {
      pick(backwards ? options[options.count - 1] : options[0])
      return
    }
    pick(options[Self.wrapped(index, backwards: backwards, count: options.count)])
  }

  func cycleLanguage() {
    guard showsLanguages else { return }
    let index = languageOptions.firstIndex(of: style.language) ?? 0
    select(languageOptions[Self.wrapped(index, backwards: false, count: languageOptions.count)])
  }

  private static func wrapped(_ index: Int, backwards: Bool, count: Int) -> Int {
    (index + (backwards ? -1 : 1) + count) % count
  }

  /// Asks again for the current style, for a different wording.
  func regenerate() {
    guard capture != nil, !isStreaming else { return }
    drafts[currentKey] = nil
    request(style, option: currentOption)
  }

  private func choose(_ next: WritingStyle, option: ActionOption?) {
    guard capture != nil, next != style || option != currentOption else { return }
    style = next
    currentOption = option
    // Pressed Enter early, then changed the style: the wait was for the
    // answer that is no longer on screen.
    replacesWhenFinished = false
    remember(next)
    request(next, option: option)
  }

  private func pick(_ option: ActionOption?) {
    guard option != currentOption else { return }
    let app = capture?.bundleIdentifier
    if !settingsStore.settings.remembersOption(option?.id, for: style.actionID, inApp: app) {
      settingsStore.settings.rememberOption(option?.id, for: style.actionID, inApp: app)
    }
    choose(style, option: option)
  }

  /// The option an action starts on in the app being written in.
  private func chosenOption(for actionID: UUID) -> ActionOption? {
    guard let action = actions.first(where: { $0.id == actionID }) else { return nil }
    return settingsStore.settings.chosenOption(for: action, inApp: capture?.bundleIdentifier)
  }

  /// Files a style as the one used in this app. Settings are only written
  /// when that changes anything, since every write re-renders every window.
  private func remember(_ style: WritingStyle) {
    let app = capture?.bundleIdentifier
    guard !settingsStore.settings.remembersWritingStyle(style, forApp: app) else { return }
    settingsStore.settings.rememberWritingStyle(style, forApp: app)
  }

  /// The request with whatever the action ignores taken out, so Polish
  /// asked in Japanese and Polish asked in English are the same request.
  private func requestKey(for style: WritingStyle, option: ActionOption?) -> ComposeRequestKey {
    let action = actions.first { $0.id == style.actionID }
    return ComposeRequestKey(
      actionID: style.actionID,
      language: action?.usesTargetLanguage == false ? .auto : style.language,
      optionID: option?.id
    )
  }

  // MARK: - Asking

  private func request(_ style: WritingStyle, option: ActionOption?) {
    let key = requestKey(for: style, option: option)
    if let draft = drafts[key], draft.error == nil { return }
    guard let action = actions.first(where: { $0.id == style.actionID }) else { return }
    tasks[key]?.cancel()
    drafts[key] = ComposeDraft()
    let settings = settingsStore.settings
    // The draft's own language is left for the model to tell: the detector
    // takes Han-only text for Japanese, and a Chinese draft is the usual case.
    let prompt = PromptBuilder.build(
      text: sourceText,
      source: .auto,
      target: style.language,
      action: action,
      writing: true,
      option: option
    )
    let session = sessionID

    tasks[key] = Task { [weak self] in
      guard let self else { return }
      var streamed = ""
      do {
        // Each action keeps its own connection and model, as in a lookup.
        let (connection, configuration) = try settingsStore.resolve(action)
        let (apiKey, accountId) = try await settingsStore.validCredentials(
          for: connection,
          proxy: settings.proxy
        )
        let clock = ContinuousClock()
        var nextUpdate = clock.now
        for try await chunk in client.stream(
          prompt: prompt,
          configuration: configuration,
          apiKey: apiKey,
          accountId: accountId,
          proxy: settings.proxy
        ) {
          guard sessionID == session, !Task.isCancelled else { return }
          streamed.append(chunk)
          let now = clock.now
          if now >= nextUpdate {
            drafts[key]?.text = streamed
            nextUpdate = now.advanced(by: .milliseconds(50))
          }
        }
        guard sessionID == session, !Task.isCancelled else { return }
        let text = WriteBackComposer.clean(streamed)
        guard !text.isEmpty else { throw TranslationError.invalidResponse }
        drafts[key] = ComposeDraft(text: text, isStreaming: false)
        if key == currentKey, replacesWhenFinished {
          replacesWhenFinished = false
          replace()
        }
      } catch {
        guard sessionID == session, !Task.isCancelled else { return }
        drafts[key] = ComposeDraft(text: streamed, isStreaming: false, error: error.localizedDescription)
        if key == currentKey { replacesWhenFinished = false }
      }
    }
  }

  private func cancelRequests() {
    tasks.values.forEach { $0.cancel() }
    tasks = [:]
  }

  // MARK: - Writing back

  /// Enter: writes the answer over the draft. Pressed while the answer is
  /// still arriving, it waits for the end of it.
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
        // The answer must not be lost to a failed write: it goes on the
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
