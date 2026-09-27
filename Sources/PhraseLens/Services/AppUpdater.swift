import AppKit
import Combine
import Sparkle

/// Sparkle owns scheduling, preference persistence, signature verification,
/// installation and relaunch. Never install executable code ourselves.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
  @Published private(set) var canCheckForUpdates = false
  @Published private(set) var automaticallyChecksForUpdates = false
  @Published private(set) var automaticallyDownloadsUpdates = false
  @Published private(set) var allowsAutomaticUpdates = false
  @Published private(set) var lastUpdateCheckDate: Date?
  @Published private(set) var isAvailable = false
  @Published private(set) var startupError: String?

  private var controller: SPUStandardUpdaterController?

  override init() {
    super.init()
    // CLI self-tests and SwiftPM executables must never schedule updates.
    guard Bundle.main.bundleURL.pathExtension == "app",
      !CommandLine.arguments.contains("--dictionary-preview") else { return }
    let info = Bundle.main.infoDictionary ?? [:]
    guard let feed = info["SUFeedURL"] as? String, let url = URL(string: feed),
      Self.acceptsFeed(url),
      let key = info["SUPublicEDKey"] as? String,
      Data(base64Encoded: key)?.count == 32,
      info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
      info["SURequireSignedFeed"] as? Bool == true,
      info["SUSignedFeedFailureExpirationInterval"] as? Int == 0 else {
      startupError = L10n.isChinese ? "此构建缺少有效的更新配置。" : "This build is missing a valid update configuration."
      return
    }
    let controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
    )
    self.controller = controller
    let updater = controller.updater
    updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
    updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloadsUpdates)
    updater.publisher(for: \.allowsAutomaticUpdates).assign(to: &$allowsAutomaticUpdates)
    updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastUpdateCheckDate)
    do {
      try updater.start()
      isAvailable = true
    } catch {
      startupError = error.localizedDescription
    }
  }

  private static func acceptsFeed(_ url: URL) -> Bool {
    if url.scheme == "https", url.host != nil { return true }
    #if DEBUG
    if isUpdateTest, url.scheme == "http", url.host == "127.0.0.1" { return true }
    #endif
    return false
  }

  func checkForUpdates() {
    guard isAvailable, canCheckForUpdates else { return }
    NSApp.activate(ignoringOtherApps: true)
    controller?.checkForUpdates(nil)
  }

  func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    guard isAvailable else { return }
    controller?.updater.automaticallyChecksForUpdates = enabled
  }

  func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
    guard isAvailable, allowsAutomaticUpdates else { return }
    controller?.updater.automaticallyDownloadsUpdates = enabled
  }

  // Appcast feeds and release notes are signed; only archive signatures from
  // the embedded key authorize installing a replacement. No custom bypasses.
  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    #if DEBUG
    if Self.isUpdateTest {
      NSLog("PhraseLens updater test: %@", String(describing: error))
    }
    #endif
  }

  #if DEBUG
  static var isUpdateTest: Bool {
    Bundle.main.bundleIdentifier?.hasPrefix("com.harry.phraselens.updater-test.") == true
      && Bundle.main.object(forInfoDictionaryKey: "PhraseLensUpdateTest") as? Bool == true
  }
  #endif
}
