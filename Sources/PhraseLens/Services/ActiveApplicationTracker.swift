import AppKit
import Foundation

/// Remembers the application the user was working in before PhraseLens came
/// forward.
///
/// Selection capture needs the process that owns the text. The global shortcut
/// records it inside its Carbon handler, but the same command is also reachable
/// from the menu bar extra and from the ⌥F menu item, and by the time those run
/// PhraseLens is the active application: the system-wide `AXFocusedApplication`
/// attribute then answers either PhraseLens or — while a menu is tracking, or
/// while the app runs as an accessory with no key window — nothing at all.
/// Watching activations keeps a usable answer for those entry points.
@MainActor
final class ActiveApplicationTracker {
  static let shared = ActiveApplicationTracker()

  private var lastActiveProcessIdentifier: pid_t?
  private var observer: NSObjectProtocol?

  private init() {}

  func start() {
    guard observer == nil else { return }
    record(NSWorkspace.shared.frontmostApplication?.processIdentifier)
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { notification in
      let application =
        notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      let processIdentifier = application?.processIdentifier
      Task { @MainActor in
        ActiveApplicationTracker.shared.record(processIdentifier)
      }
    }
  }

  func stop() {
    if let observer {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    observer = nil
  }

  /// The most recent application other than PhraseLens, or `nil` when none has
  /// been seen yet or that application has quit.
  var lastExternalProcessIdentifier: pid_t? {
    guard
      let lastActiveProcessIdentifier,
      NSRunningApplication(processIdentifier: lastActiveProcessIdentifier) != nil
    else { return nil }
    return lastActiveProcessIdentifier
  }

  private func record(_ processIdentifier: pid_t?) {
    guard
      let processIdentifier,
      processIdentifier != ProcessInfo.processInfo.processIdentifier
    else { return }
    lastActiveProcessIdentifier = processIdentifier
  }
}
