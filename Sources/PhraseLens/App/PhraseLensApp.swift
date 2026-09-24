import AppKit
import Darwin
import SwiftUI

@main
struct PhraseLensApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model: AppModel

  init() {
    if CommandLine.arguments.contains("--dictionary-self-test") {
      Task.detached {
        let failures = await DictionarySelfTestRunner.run()
        failures.forEach { print("DICTIONARY TEST FAILED: \($0)") }
        if failures.isEmpty { print("DICTIONARY TEST PASSED") }
        Darwin.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
      }
      dispatchMain()
    }
    if CommandLine.arguments.contains("--self-test") {
      let failures = SelfTestRunner.run()
      if failures.isEmpty {
        print("SELF-TEST PASSED")
        Darwin.exit(EXIT_SUCCESS)
      }
      failures.forEach { print("SELF-TEST FAILED: \($0)") }
      Darwin.exit(EXIT_FAILURE)
    }
    let model: AppModel
    #if DEBUG
    if CommandLine.arguments.contains("--dictionary-preview") {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhraseLens-preview-\(UUID())")
      let defaults = UserDefaults(suiteName: "PhraseLens-preview-\(UUID())")!
      let settings = SettingsStore(defaults: defaults,
        credentials: CredentialStore(directory: directory, defaults: defaults), loadStoredCredentials: false)
      if CommandLine.arguments.contains("--preview-light") { settings.settings.theme = .light }
      settings.dismissSetupGuide()
      settings.settings.selectionPanelPinned = true
      model = AppModel(settingsStore: settings, library: LibraryStore(directory: directory), integrateWithSystem: false)
      let arguments = CommandLine.arguments
      func previewValue(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
      }
      model.inputText = previewValue("--preview-text") ?? "食べました"
      if let result = previewValue("--preview-result") {
        // Deterministic visual QA without credentials, network or user history.
        model.outputText = result
        model.selectResultTab(.translation)
      } else {
        model.translate()
      }
    } else { model = AppModel() }
    #else
    model = AppModel()
    #endif
    _model = StateObject(wrappedValue: model)
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
      CommandGroup(after: .newItem) {
        Button("Translate Selection in Pop-Up") {
          model.captureSelectionAndTranslate()
        }
        .keyboardShortcut("f", modifiers: [.option])

        Button("Open Full Translator") {
          WindowCoordinator.showMain()
        }
        .keyboardShortcut("f", modifiers: [.option, .shift])

        Button("Screenshot OCR") {
          model.captureOCR()
        }
        .keyboardShortcut("s", modifiers: [.option])
      }
      CommandMenu("Translation") {
        Button("Translate") { model.translate() }
          .keyboardShortcut(.return, modifiers: [.command])
        Button("Stop") { model.stopTranslation() }
          .keyboardShortcut(".", modifiers: [.command])
        Button("Ask a Follow-Up") { model.requestFollowUpFocus() }
          .keyboardShortcut("l", modifiers: [.command])
          .disabled(!model.canAskFollowUp)
        Divider()
        // The tab bar shows glyphs alone once the window is narrow, so the
        // actions also need a keyboard route that names them.
        Menu("Action") {
          ForEach(Array(model.visibleActions.enumerated()), id: \.element.id) { index, action in
            Button(action.name) { model.selectAction(action.id) }
              .keyboardShortcut(
                index < 9
                  ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
                  : nil
              )
          }
        }
        Button("Next Action") { model.cycleAction(by: 1) }
          .keyboardShortcut("]", modifiers: [.command, .shift])
        Button("Previous Action") { model.cycleAction(by: -1) }
          .keyboardShortcut("[", modifiers: [.command, .shift])
        Divider()
        Button("Copy Result") { model.copyOutput() }
          .keyboardShortcut("c", modifiers: [.command, .shift])
        Button("Speak Source") { model.speakInput() }
      }
    }

    Settings {
      SettingsView()
        .environmentObject(model)
        .environmentObject(model.settingsStore)
        .environmentObject(model.modelCatalog)
    }

    MenuBarExtra("PhraseLens", systemImage: "character.bubble") {
      Button("Open Translator") { WindowCoordinator.showMain() }
      Button("Translate Selection in Pop-Up") { model.captureSelectionAndTranslate() }
      Button("Screenshot OCR") { model.captureOCR() }
      Divider()
      SettingsLink { Text("Settings…") }
      Divider()
      Button("Quit") { NSApp.terminate(nil) }
    }
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
