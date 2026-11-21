@preconcurrency import ApplicationServices
import AppKit
import Foundation

/// Asks Chromium browsers to put their pages in the accessibility tree.
///
/// Chrome and the browsers built on it show an accessibility client only
/// their own window: tabs, toolbar, address bar. The page is not in the tree
/// at all, so a selection in it has no paragraph to be read from, no focused
/// element, nothing for the context search to find; the words themselves
/// only arrive through ⌘C. `AXManualAccessibility`, the switch that builds the
/// tree in Electron apps, is refused by Chrome as unsupported. What Chrome
/// does honour is `AXEnhancedUserInterface`, the attribute VoiceOver sets, and
/// it builds the page tree one to four seconds after being asked — measured
/// on Chrome 158 and macOS 26: 0 text blocks before, 296 four seconds after.
///
/// Those seconds are why this is not done at capture time. The switch is
/// thrown when such a browser comes to the front, long before the reader has
/// found and selected anything, and thrown back when PhraseLens quits, since
/// Chrome keeps the tree for as long as the attribute stays on. It costs
/// Chrome what VoiceOver costs it: a tree kept for every page it shows.
/// Chrome counts these requests, so each process is asked exactly once.
@MainActor
final class BrowserAccessibilityActivator {
  static let shared = BrowserAccessibilityActivator()

  /// Bundle identifiers of browsers that keep their pages out of the tree
  /// until a screen reader asks for them. A prefix covers a browser's beta,
  /// dev and canary channels, which append to the stable identifier.
  ///
  /// Electron apps are deliberately absent: they answer
  /// `AXManualAccessibility`, which builds their tree without the side
  /// effects of telling them a screen reader is running.
  nonisolated static let chromiumBundleIdentifierPrefixes = [
    "com.google.Chrome",
    "org.chromium.Chromium",
    "com.microsoft.edgemac",
    "com.brave.Browser",
    "company.thebrowser.Browser",
    "company.thebrowser.dia",
    "com.vivaldi.Vivaldi",
    "com.operasoftware.Opera",
    "ru.yandex.desktop.yandex-browser",
    "com.naver.Whale",
  ]

  /// How long a first capture waits for a page tree that was asked for a
  /// moment ago. Chrome waits two seconds for the request to settle and then
  /// builds; four and a half covers that with room for a heavy page.
  static let pageTreeAllowance = Duration.milliseconds(4_500)
  private static let readinessPollInterval = Duration.milliseconds(150)

  /// When each browser process was asked. A process is only ever asked once;
  /// a relaunched browser is a new process and is asked again.
  private var activatedAt: [pid_t: ContinuousClock.Instant] = [:]

  private init() {}

  nonisolated static func isChromiumBrowser(bundleIdentifier: String?) -> Bool {
    guard let bundleIdentifier else { return false }
    return chromiumBundleIdentifierPrefixes.contains { bundleIdentifier.hasPrefix($0) }
  }

  /// Asks `application` for its page tree if it is a Chromium browser that
  /// has not been asked yet, and returns when it was asked. `nil` means there
  /// is nothing to wait for: not such a browser, or no Accessibility
  /// permission to ask with.
  @discardableResult
  func activate(_ application: NSRunningApplication?) -> ContinuousClock.Instant? {
    guard
      let application,
      Self.isChromiumBrowser(bundleIdentifier: application.bundleIdentifier),
      AXIsProcessTrusted()
    else { return nil }
    let processIdentifier = application.processIdentifier
    if let activated = activatedAt[processIdentifier] { return activated }

    // A browser that quit took its tree with it; forget it so the table only
    // holds processes a quit has to switch back off.
    activatedAt = activatedAt.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
    setEnhancedUserInterface(true, for: processIdentifier)
    let now = ContinuousClock.now
    activatedAt[processIdentifier] = now
    return now
  }

  /// Makes sure a capture from `processIdentifier` meets a page tree.
  ///
  /// For a browser asked long ago this returns at once. For one asked a
  /// moment ago — the reader switched to it and pressed the shortcut within
  /// seconds, or PhraseLens has just launched — it waits until the browser
  /// reports a focused element, which it does not do while its page is out of
  /// the tree, or until the allowance runs out.
  func preparePageTree(for processIdentifier: pid_t) async {
    guard let activated = activate(NSRunningApplication(processIdentifier: processIdentifier)) else {
      return
    }
    let deadline = activated.advanced(by: Self.pageTreeAllowance)
    while ContinuousClock.now < deadline {
      let ready = await Task.detached(priority: .userInitiated) {
        Self.reportsFocusedElement(processIdentifier)
      }.value
      if ready { return }
      try? await Task.sleep(for: Self.readinessPollInterval)
    }
  }

  /// Hands every browser still running back the way it was found.
  func deactivateAll() {
    for processIdentifier in activatedAt.keys
    where NSRunningApplication(processIdentifier: processIdentifier) != nil {
      setEnhancedUserInterface(false, for: processIdentifier)
    }
    activatedAt.removeAll()
  }

  private func setEnhancedUserInterface(_ enabled: Bool, for processIdentifier: pid_t) {
    let application = AXUIElementCreateApplication(processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.4)
    let value: CFBoolean = enabled ? kCFBooleanTrue : kCFBooleanFalse
    // Chrome answers "not implemented" while still acting on the request, so
    // the status says nothing about whether this worked.
    _ = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, value)
  }

  nonisolated private static func reportsFocusedElement(_ processIdentifier: pid_t) -> Bool {
    let application = AXUIElementCreateApplication(processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.3)
    var focused: CFTypeRef?
    return AXUIElementCopyAttributeValue(
      application,
      kAXFocusedUIElementAttribute as CFString,
      &focused
    ) == .success && focused != nil
  }
}
