import AppKit
import Darwin
import SwiftUI

@main
struct PhraseLensApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model: AppModel
  @StateObject private var appUpdater: AppUpdater
  /// Whether the menu bar item is in the menu bar. macOS can take it out:
  /// the reader can ⌘-drag it off, or switch PhraseLens off under System
  /// Settings › Menu Bar. A `MenuBarExtra` with no binding quits the app when
  /// that happens, so with the item switched off the app quit the moment it
  /// launched. With the binding the item just goes, and the app keeps running
  /// with its window, Dock icon and shortcuts. It is asked for again at the
  /// next launch, so it comes back once it is allowed.
  @State private var menuBarItemInserted = true

  init() {
    if CommandLine.arguments.contains("--self-test") {
      let failures = SelfTestRunner.run()
      if failures.isEmpty {
        print("SELF-TEST PASSED")
        Darwin.exit(EXIT_SUCCESS)
      }
      failures.forEach { print("SELF-TEST FAILED: \($0)") }
      Darwin.exit(EXIT_FAILURE)
    }
    #if DEBUG
    if CommandLine.arguments.contains("--learning-probe") {
      let application = NSApplication.shared
      application.setActivationPolicy(.prohibited)
      Task { @MainActor in
        let status = await LearningProbe.run(arguments: CommandLine.arguments)
        Darwin.exit(status)
      }
      application.run()
    }
    if CommandLine.arguments.contains("--write-back-probe") {
      let application = NSApplication.shared
      application.setActivationPolicy(.accessory)
      Task { @MainActor in
        let status = await WriteBackProbe.run(arguments: CommandLine.arguments)
        Darwin.exit(status)
      }
      application.run()
    }
    #endif
    let model: AppModel
    #if DEBUG
    if AppUpdater.isUpdateTest,
      let path = Bundle.main.object(forInfoDictionaryKey: "PhraseLensUpdateTestDirectory") as? String {
      let directory = URL(fileURLWithPath: path, isDirectory: true)
      let defaults = UserDefaults.standard
      let settings = SettingsStore(defaults: defaults,
        credentials: CredentialStore(directory: directory, defaults: defaults), loadStoredCredentials: false)
      settings.dismissSetupGuide()
      model = AppModel(settingsStore: settings, library: LibraryStore(directory: directory), integrateWithSystem: false)
    } else if CommandLine.arguments.contains("--dictionary-preview") {
      let arguments = CommandLine.arguments
      func previewValue(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
      }
      // `--preview-library <dir>` reads a copy of a library, so the library
      // sections can be photographed populated without touching the real one.
      let directory = previewValue("--preview-library").map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("PhraseLens-preview-\(UUID())")
      let defaults = UserDefaults(suiteName: "PhraseLens-preview-\(UUID())")!
      let settings = SettingsStore(defaults: defaults,
        credentials: CredentialStore(directory: directory, defaults: defaults), loadStoredCredentials: false)
      if CommandLine.arguments.contains("--preview-light") { settings.settings.theme = .light }
      if CommandLine.arguments.contains("--preview-dark") { settings.settings.theme = .dark }
      if CommandLine.arguments.contains("--preview-chinese") { settings.settings.appLanguage = .simplifiedChinese }
      settings.dismissSetupGuide()
      settings.settings.selectionPanelPinned = true
      model = AppModel(settingsStore: settings, library: LibraryStore(directory: directory), integrateWithSystem: false)
      if previewValue("--preview-library") != nil { model.loadPreviewLibrary() }
      model.selectedActionID = previewValue("--preview-action") == "translate"
        ? TranslationAction.builtIn(for: .translate).id
        : TranslationAction.builtIn(for: .definition).id
      model.inputText = previewValue("--preview-text") ?? "食べました"
      if let source = previewValue("--preview-capture-from").flatMap({ pid_t($0) }) {
        model.previewCapture(
          from: source,
          action: previewValue("--preview-action") == "polish" ? .polishing : .translate,
          result: previewValue("--preview-result") ?? "(preview result)"
        )
      } else if let result = previewValue("--preview-result") {
        // Deterministic visual QA without credentials, network or user history.
        model.outputText = result
        if let question = previewValue("--preview-question") {
          model.seedPreviewFollowUp(question: question, answer: previewValue("--preview-answer") ?? "")
        }
      } else {
        model.translate()
      }
    } else { model = AppModel() }
    #else
    model = AppModel()
    #endif
    _model = StateObject(wrappedValue: model)
    _appUpdater = StateObject(wrappedValue: AppUpdater())
    AppDelegate.sharedModel = model
  }

  var body: some Scene {
    // The scene is addressed by id so that a main window the user closed can
    // be opened again from the menu bar or a hotkey.
    WindowGroup("PhraseLens", id: WindowCoordinator.mainWindowSceneID) {
      RootView()
        .environmentObject(model)
        .environmentObject(model.settingsStore)
        .environmentObject(model.modelCatalog)
        .environmentObject(model.learning)
        .frame(minWidth: AppMetrics.windowMinWidth, minHeight: AppMetrics.windowMinHeight)
        .onAppear {
          #if DEBUG
          if CommandLine.arguments.contains("--dictionary-preview-panel") {
            SelectionPanelCoordinator.shared.show(model: model)
          }
          #endif
        }
    }
    .defaultSize(width: 1080, height: 720)
    // The app draws its own top bar, so the system title bar is hidden and the
    // sidebar reserves the space the traffic lights need.
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(after: .appInfo) {
        Button(L10n.isChinese ? "检查更新…" : "Check for Updates…") { appUpdater.checkForUpdates() }
          .disabled(!appUpdater.canCheckForUpdates)
      }
      CommandGroup(after: .newItem) {
        EntryPointCommands(model: model, settingsStore: model.settingsStore)
      }
      CommandMenu(AppSection.translator.title) {
        WorkspaceCommands(model: model, settingsStore: model.settingsStore)
      }
    }

    Settings {
      SettingsView()
        .environmentObject(appUpdater)
        .environmentObject(model)
        .environmentObject(model.settingsStore)
        .environmentObject(model.modelCatalog)
        .environmentObject(model.learning)
    }

    MenuBarExtra("PhraseLens", systemImage: "character.bubble", isInserted: $menuBarItemInserted) {
      MenuBarMenu(
        model: model,
        settingsStore: model.settingsStore,
        learning: model.learning,
        appUpdater: appUpdater
      )
    }
  }

}

// MARK: - Menus

extension KeyboardShortcut {
  /// A global shortcut as Settings saves it ("⌥F"), for a menu to print beside
  /// the command it opens. Nil for one a menu cannot show, such as a function
  /// key, or one the reader cleared.
  init?(globalShortcut value: String) {
    let upper = value.uppercased()
    var modifiers: EventModifiers = []
    if upper.contains("⌘") { modifiers.insert(.command) }
    if upper.contains("⌥") { modifiers.insert(.option) }
    if upper.contains("⌃") { modifiers.insert(.control) }
    if upper.contains("⇧") { modifiers.insert(.shift) }
    let key = upper.filter { !"⌘⌥⌃⇧ +".contains($0) }
    let equivalent: KeyEquivalent
    switch key {
    case "SPACE": equivalent = .space
    case "←": equivalent = .leftArrow
    case "→": equivalent = .rightArrow
    case "↑": equivalent = .upArrow
    case "↓": equivalent = .downArrow
    default:
      guard key.count == 1, let character = key.lowercased().first else { return nil }
      equivalent = KeyEquivalent(character)
    }
    guard !modifiers.isEmpty else { return nil }
    self.init(equivalent, modifiers: modifiers)
  }
}

/// The ways in from another app, each with the shortcut the reader set for it.
/// The shortcuts themselves are global and fire wherever the reader is; the
/// menu prints them so it is also the place to look them up.
private struct EntryPointCommands: View {
  @ObservedObject var model: AppModel
  @ObservedObject var settingsStore: SettingsStore

  var body: some View {
    let shortcuts = settingsStore.settings.shortcuts
    Button(L10n.isChinese ? "查词…" : "Look Up…") {
      model.handleHotKey(.translateSelection)
    }
    .keyboardShortcut(KeyboardShortcut(globalShortcut: shortcuts.translateSelection))

    Button(L10n.isChinese ? "写作…" : "Write…") {
      model.handleHotKey(.writing)
    }
    .keyboardShortcut(KeyboardShortcut(globalShortcut: shortcuts.writing))

    Button(L10n.isChinese ? "截屏识别文字" : "Capture Text from Screen") {
      model.captureOCR()
    }
    .keyboardShortcut(KeyboardShortcut(globalShortcut: shortcuts.screenshotOCR))

    Button(L10n.isChinese ? "打开主窗口" : "Open Main Window") {
      WindowCoordinator.showMain()
    }
    .keyboardShortcut(KeyboardShortcut(globalShortcut: shortcuts.showWindow))
  }
}

/// The workbench's commands. The keys are the ones both pop-ups use, so one
/// grammar holds everywhere: ⌘R asks again, ⌘L steps the language, ⌘. stops,
/// ⌘1–9 pick an action, ⇧⌘C copies; ⌘K asks a follow-up, which only the
/// main window has.
private struct WorkspaceCommands: View {
  @ObservedObject var model: AppModel
  @ObservedObject var settingsStore: SettingsStore

  private var hasInput: Bool {
    !model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    let actionName = model.selectedAction?.displayName ?? (L10n.isChinese ? "动作" : "Action")
    Button(L10n.isChinese ? "运行“\(actionName)”" : "Run “\(actionName)”") { model.translate() }
      .disabled(model.selectedAction == nil || !hasInput)
    Button(L10n.isChinese ? "重新生成" : "Ask Again") { model.regenerate() }
      .keyboardShortcut("r", modifiers: [.command])
      .disabled(model.selectedAction == nil || !hasInput)
    Button(L10n.isChinese ? "停止" : "Stop") { model.stopTranslation() }
      .keyboardShortcut(".", modifiers: [.command])
    Button(L10n.isChinese ? "深入追问" : "Ask a Follow-Up") { model.requestFollowUpFocus() }
      .keyboardShortcut("k", modifiers: [.command])
      .disabled(!model.canAskFollowUp)
    Divider()
    // The tab bar shows glyphs alone once the window is narrow, so the
    // actions also need a keyboard route that names them.
    Menu(L10n.isChinese ? "动作" : "Action") {
      ForEach(Array(model.visibleActions.enumerated()), id: \.element.id) { index, action in
        Button(action.displayName) { model.selectAction(action.id) }
          .keyboardShortcut(
            index < 9
              ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
              : nil
          )
      }
    }
    Button(L10n.isChinese ? "下一个动作" : "Next Action") { model.cycleAction(by: 1) }
      .keyboardShortcut("]", modifiers: [.command, .shift])
    Button(L10n.isChinese ? "上一个动作" : "Previous Action") { model.cycleAction(by: -1) }
      .keyboardShortcut("[", modifiers: [.command, .shift])
    Button(L10n.isChinese ? "切换目标语言" : "Next Target Language") { model.cycleTargetLanguage() }
      .keyboardShortcut("l", modifiers: [.command])
      .disabled(model.visibleTargetLanguages.count < 2)
    Divider()
    Button(L10n.isChinese ? "拷贝结果" : "Copy Result") { model.copyOutput() }
      .keyboardShortcut("c", modifiers: [.command, .shift])
      .disabled(!model.canCopyResult)
    // Listed only for the actions that offer them, and enabled only while
    // the input is a selection that can still be written back to.
    ForEach(model.offeredResultCommands.filter(\.writesToSource)) { command in
      Button(command.menuTitle(sourceApplication: model.writableSource?.applicationName)) {
        model.perform(command)
      }
      .disabled(!model.canPerform(command))
    }
    Button(L10n.isChinese ? "朗读原文" : "Speak Source") { model.speakInput() }
      .disabled(!hasInput)
  }
}

/// The menu bar item: every way in with its shortcut, and the day's review
/// when there is one, since that is the one thing waiting on the reader.
private struct MenuBarMenu: View {
  @ObservedObject var model: AppModel
  @ObservedObject var settingsStore: SettingsStore
  @ObservedObject var learning: LearningModel
  @ObservedObject var appUpdater: AppUpdater

  var body: some View {
    EntryPointCommands(model: model, settingsStore: settingsStore)
    Divider()
    let due = learning.dueCount
    Button(
      due > 0
        ? (L10n.isChinese ? "今天待复习 \(due) 个…" : "Review \(due) Due Today…")
        : (L10n.isChinese ? "学习中心…" : "Study…")
    ) {
      model.openLearning(tab: due > 0 ? .review : nil)
    }
    Divider()
    SettingsLink { Text(L10n.isChinese ? "设置…" : "Settings…") }
      .keyboardShortcut(",", modifiers: [.command])
    Button(L10n.isChinese ? "检查更新…" : "Check for Updates…") { appUpdater.checkForUpdates() }
      .disabled(!appUpdater.canCheckForUpdates)
    Divider()
    Button(L10n.isChinese ? "退出 PhraseLens" : "Quit PhraseLens") { NSApp.terminate(nil) }
      .keyboardShortcut("q", modifiers: [.command])
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  static weak var sharedModel: AppModel?
  private var resignObserver: NSObjectProtocol?

  func applicationDidFinishLaunching(_: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = false
    applyActivationPolicy()
    ActiveApplicationTracker.shared.start()
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: nil,
      queue: .main
    ) { _ in
      Task { @MainActor in
        guard let model = Self.sharedModel,
          model.settingsStore.settings.autoHideWhenInactive,
          !model.settingsStore.settings.alwaysOnTop
        else { return }
        WindowCoordinator.mainWindow()?.orderOut(nil)
      }
    }
    DispatchQueue.main.async {
      WindowCoordinator.tagMainWindowIfNeeded()
      WindowCoordinator.revalidateMainWindowLayout()
      WindowCoordinator.dismissAutoPresentedSettingsWindow()
    }
  }

  func applicationWillTerminate(_: Notification) {
    if let resignObserver {
      NotificationCenter.default.removeObserver(resignObserver)
    }
    GlobalHotKeyManager.shared.unregisterAll()
    ActiveApplicationTracker.shared.stop()
  }

  func applicationDidBecomeActive(_: Notification) {
    Self.sharedModel?.refreshAccessibilityPermission()
  }

  func applicationShouldHandleReopen(
    _: NSApplication,
    hasVisibleWindows _: Bool
  ) -> Bool {
    // showMain() covers both cases itself: raise the window if one exists,
    // or ask SwiftUI to recreate the scene and raise that once it appears.
    // Always return false afterwards — true tells AppKit to *also* run its
    // own default reopen handling, which for a WindowGroup races our own
    // scene-recreation call and leaves two main windows on screen. Returning
    // false skips that default without skipping our own handling above,
    // which happens unconditionally either way.
    WindowCoordinator.showMain()
    return false
  }

  private func applyActivationPolicy() {
    guard let model = Self.sharedModel else { return }
    NSApp.setActivationPolicy(model.settingsStore.settings.showDockIcon ? .regular : .accessory)
  }
}
