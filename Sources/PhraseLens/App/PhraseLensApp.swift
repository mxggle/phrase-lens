import AppKit
import Darwin
import SwiftUI

@main
struct PhraseLensApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model: AppModel

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
    let model = AppModel()
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
