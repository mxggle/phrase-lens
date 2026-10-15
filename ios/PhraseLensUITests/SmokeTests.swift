import XCTest

/// Walks the three tabs and the Share sheet on a Simulator and keeps a
/// screenshot of each, so a layout change can be checked without a phone.
///
/// `./scripts/screenshots.sh` runs it and copies the images to
/// build/screenshots/. Without SCREENSHOT_DIR the images are only kept as
/// test attachments in the result bundle.
final class SmokeTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = true
  }

  @MainActor
  func testTabs() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.navigationBars["PhraseLens"].waitForExistence(timeout: 10))
    snapshot("1-lookup")

    let field = app.textFields.firstMatch
    field.tap()
    field.typeText("serendipity")
    app.navigationBars.buttons["Look Up"].tap()
    // No key is set on a fresh Simulator, so this settles on the setup hint.
    _ = app.staticTexts["Add an API key in Settings."].waitForExistence(timeout: 10)
    snapshot("2-lookup-result")

    app.tabBars.buttons["Actions"].tap()
    XCTAssertTrue(app.navigationBars["Actions"].waitForExistence(timeout: 5))
    snapshot("3-actions")

    app.tabBars.buttons["Settings"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    snapshot("4-settings")
  }

  /// Selects a word on a page in Safari and opens PhraseLens from Share….
  /// The page comes from SHARE_PAGE_URL (screenshots.sh serves one locally).
  @MainActor
  func testShareSheet() throws {
    let url = try XCTUnwrap(
      ProcessInfo.processInfo.environment["SHARE_PAGE_URL"],
      "Set SHARE_PAGE_URL to a page with a word on it"
    )
    // A fresh install's extension can be missing from the sheet until the
    // app has run once.
    let app = XCUIApplication()
    app.launch()
    app.terminate()

    let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    safari.launch()
    let address = safari.textFields["Address"].firstMatch.exists
      ? safari.textFields["Address"].firstMatch
      : safari.buttons["Address"].firstMatch
    if address.waitForExistence(timeout: 10) { address.tap() }
    safari.typeText(url + "\n")

    let word = safari.staticTexts["serendipity"].firstMatch
    XCTAssertTrue(word.waitForExistence(timeout: 15))
    word.press(forDuration: 1.2)
    snapshot("5-safari-selection")

    // The edit menu shows a few items; Next Page opens the full list, where
    // Share… is a button rather than a menu item.
    var share = safari.menuItems["Share…"].firstMatch
    if !share.waitForExistence(timeout: 2) {
      safari.buttons["Next Page"].firstMatch.tap()
      share = safari.buttons["Share…"].firstMatch
    }
    XCTAssertTrue(share.waitForExistence(timeout: 3))
    share.tap()
    sleep(2)
    snapshot("6-share-sheet")

    var entry = safari.cells["PhraseLens"].firstMatch
    if !entry.waitForExistence(timeout: 3) {
      safari.swipeUp()
      entry = safari.cells["PhraseLens"].firstMatch
    }
    if !entry.exists { entry = safari.buttons["PhraseLens"].firstMatch }
    XCTAssertTrue(entry.waitForExistence(timeout: 3), "PhraseLens is not in the Share sheet")
    snapshot("7-share-sheet-list")
    entry.tap()
    sleep(4)
    snapshot("8-action-extension")
  }

  @MainActor
  private func snapshot(_ name: String) {
    let shot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: shot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
      try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
  }
}
