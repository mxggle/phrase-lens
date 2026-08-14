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
    WindowCoordinator.showMain()
    return true
  }

  private func applyActivationPolicy() {
    guard let model = Self.sharedModel else { return }
    NSApp.setActivationPolicy(model.settingsStore.settings.showDockIcon ? .regular : .accessory)
  }
}
