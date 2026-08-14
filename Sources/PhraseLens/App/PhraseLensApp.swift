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
    WindowGroup("PhraseLens") {
      RootView()
        .environmentObject(model)
        .environmentObject(model.settingsStore)
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
    WindowCoordinator.dismissAutoPresentedSettingsWindow()
    // If the user closed the last main window, let SwiftUI recreate the scene
    // window itself. Racing it with our own ordering calls can leave two main
    // windows behind.
    guard WindowCoordinator.mainWindow() != nil else { return false }
    WindowCoordinator.showMain()
    return true
  }

  private func applyActivationPolicy() {
    guard let model = Self.sharedModel else { return }
    NSApp.setActivationPolicy(model.settingsStore.settings.showDockIcon ? .regular : .accessory)
  }
}
