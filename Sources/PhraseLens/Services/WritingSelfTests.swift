import CoreGraphics
import Foundation

/// Self tests for the writing shortcut's pop-up: its prompt, the styles it
/// remembers, and where it opens. All pure, so they run without another
/// application to write into.
enum WritingSelfTests {
  static func run() -> [String] {
    var failures: [String] = []
    promptFailures(&failures)
    styleFailures(&failures)
    settingsFailures(&failures)
    geometryFailures(&failures)
    return failures
  }

  // MARK: - Prompt

  private static func promptFailures(_ failures: inout [String]) {
    let draft = "  明天的会议我可能会晚到十分钟，你能帮我跟大家说一下吗？\n"
    let boss = PromptBuilder.writing(text: draft, style: WritingStyle(language: .japanese, register: .formal))
    check(boss.user.hasSuffix("明天的会议我可能会晚到十分钟，你能帮我跟大家说一下吗？"),
      "the draft should be sent trimmed and unescaped, as the message to rewrite", &failures)
    check(boss.system.contains("Japanese") && boss.system.contains("敬語"),
      "a message for the boss should ask for Japanese keigo", &failures)
    check(boss.system.contains("never answer it"),
      "a draft that asks a question must be rewritten, not answered", &failures)
    check(boss.system.contains("no readings"),
      "a message to send must not carry furigana or romanization", &failures)
    check(boss.priorTurns.isEmpty, "the writing prompt should be a single turn", &failures)

    let friend = PromptBuilder.writing(text: draft, style: WritingStyle(language: .japanese, register: .casual))
    check(friend.system.contains("タメ口") && !friend.system.contains("敬語"),
      "a message for a friend should ask for タメ口 only", &failures)
    let coworker = PromptBuilder.writing(text: draft, style: WritingStyle(language: .japanese, register: .polite))
    check(coworker.system.contains("です・ます"), "a message for a coworker should ask for です・ます", &failures)

    let english = PromptBuilder.writing(text: "收到，谢谢", style: WritingStyle(language: .english, register: .formal))
    check(english.system.contains("English") && !english.system.contains("Japanese")
        && english.system.contains("formal"),
      "an English message should name English and its own register", &failures)
  }

  // MARK: - Styles

  private static func styleFailures(_ failures: inout [String]) {
    check(WritingRegister.casual.next == .polite && WritingRegister.formal.next == .casual,
      "Tab should step through the registers and wrap", &failures)
    check(WritingRegister.casual.previous == .formal && WritingRegister.polite.previous == .casual,
      "⇧Tab should step back through the registers and wrap", &failures)
    check(WritingRegister.formal.styleName(in: .japanese) == "敬語"
        && WritingRegister.polite.styleName(in: .english) == "Professional",
      "registers should be named in the language being written", &failures)
    check(WritingStyle.languageOptions(including: .japanese) == [.japanese, .english],
      "the pop-up should offer Japanese and English", &failures)
    check(WritingStyle.languageOptions(including: .korean) == [.japanese, .english, .korean],
      "a language chosen in Settings should join Japanese and English", &failures)
  }

  // MARK: - Settings

  private static func settingsFailures(_ failures: inout [String]) {
    var settings = AppSettings()
    check(settings.writingShowsPreview, "the writing shortcut should preview by default", &failures)
    check(settings.writingStyle(forApp: "com.tinyspeck.slackmacgap")
        == WritingStyle(language: .english, register: .polite),
      "an unseen app should open with the last language and register", &failures)

    let line = WritingStyle(language: .japanese, register: .casual)
    settings.rememberWritingStyle(line, forApp: "jp.naver.line.mac")
    check(settings.writingStyle(forApp: "jp.naver.line.mac") == line,
      "an app should reopen with the style last used in it", &failures)
    check(settings.writingStyle(forApp: "com.tinyspeck.slackmacgap") == line,
      "an unseen app should fall back to the style used last anywhere", &failures)
    let slack = WritingStyle(language: .japanese, register: .formal)
    settings.rememberWritingStyle(slack, forApp: "com.tinyspeck.slackmacgap")
    check(settings.writingStyle(forApp: "jp.naver.line.mac") == line,
      "a style chosen in one app should not change another app's", &failures)
    check(settings.writingStyle(forApp: nil) == slack,
      "an app without a bundle identifier should use the style used last", &failures)

    do {
      let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
      check(decoded.writingStylesByApp == settings.writingStylesByApp
          && decoded.writingRegister == .formal && decoded.writingShowsPreview,
        "remembered writing styles did not survive a round trip", &failures)
      var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as! [String: Any]
      for key in ["writingRegister", "writingStylesByApp", "writingShowsPreview"] {
        legacy.removeValue(forKey: key)
      }
      let migrated = try JSONDecoder().decode(
        AppSettings.self,
        from: JSONSerialization.data(withJSONObject: legacy)
      )
      check(migrated.writingRegister == .polite && migrated.writingStylesByApp.isEmpty
          && migrated.writingShowsPreview,
        "settings saved before the compose pop-up should open it with its defaults", &failures)
    } catch {
      failures.append("writing settings coding threw: \(error)")
    }
  }

  // MARK: - Placement

  private static func geometryFailures(_ failures: inout [String]) {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let size = CGSize(width: 460, height: 320)
    let chatBox = CGRect(x: 300, y: 40, width: 700, height: 60)
    let above = ComposePanelGeometry.frame(size: size, anchor: chatBox, visibleFrame: screen)
    check(above.minY > chatBox.maxY && above.minX == chatBox.minX,
      "the pop-up should open above a message box, lined up with it", &failures)

    let topField = CGRect(x: 300, y: 800, width: 400, height: 30)
    let below = ComposePanelGeometry.frame(size: size, anchor: topField, visibleFrame: screen)
    check(below.maxY < topField.minY, "with no room above, the pop-up should open below the field", &failures)

    let edgeField = CGRect(x: 1300, y: 40, width: 120, height: 30)
    let clamped = ComposePanelGeometry.frame(size: size, anchor: edgeField, visibleFrame: screen)
    check(screen.contains(clamped), "the pop-up should stay on screen beside a field at the edge", &failures)
  }

  private static func check(_ condition: @autoclosure () -> Bool, _ message: String, _ failures: inout [String]) {
    if !condition() { failures.append(message) }
  }
}
