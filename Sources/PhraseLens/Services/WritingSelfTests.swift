import CoreGraphics
import Foundation

/// Self tests for the writing shortcut's pop-up: the actions it runs, the
/// tones `${tone}` stands for, the styles it remembers per app, settings
/// saved before any of that was editable, and where it opens. All pure, so
/// they run without another application to write into.
enum WritingSelfTests {
  static func run() -> [String] {
    var failures: [String] = []
    promptFailures(&failures)
    toneFailures(&failures)
    settingsFailures(&failures)
    migrationFailures(&failures)
    geometryFailures(&failures)
    return failures
  }

  private static let compose = TranslationAction.builtIn(for: .compose)
  private static let polish = TranslationAction.builtIn(for: .polishing)
  private static let translate = TranslationAction.builtIn(for: .translate)

  private static func tone(_ id: UUID) -> WritingTone {
    WritingTone.defaults.first { $0.id == id }!
  }

  // MARK: - Prompts

  private static func promptFailures(_ failures: inout [String]) {
    let draft = "  明天的会议我可能会晚到十分钟，你能帮我跟大家说一下吗？\n"
    let japanese = LanguageCode.japanese.displayName

    func writing(_ action: TranslationAction, _ text: String = draft, target: LanguageCode = .japanese,
      tone: String?) -> TranslationPrompt
    {
      PromptBuilder.build(text: text, source: .auto, target: target, action: action, writing: true, tone: tone)
    }

    let boss = writing(compose, tone: tone(WritingTone.bossID).instruction)
    check(boss.user == "Draft:\n\n明天的会议我可能会晚到十分钟，你能帮我跟大家说一下吗？",
      "Compose should send the draft trimmed and unescaped, as the message to rewrite", &failures)
    check(boss.system.contains(japanese) && boss.system.contains("敬語"),
      "Compose for the boss should name the language and ask for keigo", &failures)
    check(boss.system.contains("never answer it"),
      "a draft that asks a question must be rewritten, not answered", &failures)
    check(boss.system.contains("no readings"),
      "a message to send must not carry furigana or romanization", &failures)
    check(!boss.system.contains("${") && !boss.user.contains("${"),
      "Compose left a template variable unsubstituted", &failures)
    check(boss.priorTurns.isEmpty, "the writing prompt should be a single turn", &failures)

    let friend = writing(compose, tone: tone(WritingTone.friendsID).instruction)
    check(friend.system.contains("タメ口") && !friend.system.contains("敬語"),
      "Compose for a friend should ask for タメ口 only", &failures)
    let english = writing(compose, "收到，谢谢", target: .english, tone: tone(WritingTone.bossID).instruction)
    check(english.system.contains(LanguageCode.english.displayName) && !english.system.contains(japanese),
      "an English message should name English only", &failures)

    for missing in [nil, "  \n"] as [String?] {
      let neutral = writing(compose, tone: missing)
      check(neutral.system.contains(WritingTone.neutralInstruction),
        "a missing or blank tone should fall back to the neutral instruction", &failures)
    }

    // Compose is its template and nothing else: an edit is exactly what is sent.
    var edited = compose
    edited.rolePrompt = "Write to ${tone} in ${targetLang}. Keep it short."
    edited.commandPrompt = "${text}"
    let editedPrompt = writing(edited, tone: "my client")
    check(editedPrompt.system == "Write to my client in \(japanese). Keep it short."
        && editedPrompt.user == draft.trimmingCharacters(in: .whitespacesAndNewlines),
      "an edited Compose prompt was not sent as written", &failures)

    let polished = writing(polish, "これはテストのです", tone: tone(WritingTone.bossID).instruction)
    check(polished.user.contains("これはテストのです") && !polished.user.contains("${")
        && !polished.system.contains("${") && !polished.system.contains("敬語"),
      "Polish in the writing pop-up should polish the draft and ignore the tone", &failures)

    let custom = TranslationAction(
      name: "Reply to client",
      rolePrompt: "You write emails. Tone: ${tone}.",
      commandPrompt: "${text}"
    )
    let customPrompt = writing(custom, "${tone} is literal here", tone: "warm")
    check(customPrompt.system == "You write emails. Tone: warm."
        && customPrompt.user == "${tone} is literal here",
      "a custom action should get ${tone}, and the draft should not be scanned for it", &failures)
    let lookup = PromptBuilder.build(text: "hello", source: .english, target: .japanese, action: custom)
    check(lookup.system.contains(WritingTone.neutralInstruction),
      "an action using ${tone} outside the writing pop-up should get the neutral tone", &failures)

    check(compose.usesTone && compose.usesTargetLanguage,
      "Compose should show the tone chips and the language switch", &failures)
    check(!polish.usesTone && !polish.usesTargetLanguage,
      "Polish keeps the draft's language and tone, so it should show neither switch", &failures)
    check(translate.usesTargetLanguage && !translate.usesTone,
      "Translate should show the language switch only", &failures)
    check(custom.usesTone && !custom.usesTargetLanguage,
      "a custom action should show the switches its prompt asks for", &failures)
    check(ResultCommand.defaults(for: .compose).first == .replace,
      "Compose's answer should be written back first", &failures)
  }

  // MARK: - Tones

  private static func toneFailures(_ failures: inout [String]) {
    check(WritingTone.defaults.map(\.id) == [WritingTone.friendsID, WritingTone.coworkersID, WritingTone.bossID],
      "the shipped tones should be friends, coworkers, and boss, in that order", &failures)
    let boss = tone(WritingTone.bossID)
    check(["上司", "Boss"].contains(boss.displayName),
      "a shipped tone should be named in the interface language", &failures)
    var renamed = boss
    renamed.name = "部長"
    check(renamed.displayName == "部長", "a renamed tone should keep its new name", &failures)
    check(boss.styleName(in: .japanese) == "敬語"
        && tone(WritingTone.coworkersID).styleName(in: .english) == "Professional",
      "shipped tones should be named in the language being written", &failures)
    var reworded = boss
    reworded.instruction = "very polite"
    check(reworded.styleName(in: .japanese) == nil && renamed.styleName(in: .japanese) == "敬語",
      "only an edited instruction should drop the grammar name", &failures)
    check(WritingTone.toneID(forLegacyRegister: "casual") == WritingTone.friendsID
        && WritingTone.toneID(forLegacyRegister: "polite") == WritingTone.coworkersID
        && WritingTone.toneID(forLegacyRegister: "formal") == WritingTone.bossID
        && WritingTone.toneID(forLegacyRegister: "royal") == nil,
      "0.15 registers should map onto the shipped tones", &failures)

    check(WritingStyle.languageOptions(including: [.english, .japanese]) == [.japanese, .english],
      "the pop-up should offer Japanese and English", &failures)
    check(WritingStyle.languageOptions(including: [.korean, .japanese, .auto]) == [.japanese, .english, .korean],
      "a language chosen in Settings should join Japanese and English", &failures)
  }

  // MARK: - Settings

  private static func settingsFailures(_ failures: inout [String]) {
    var settings = AppSettings()
    check(settings.writingShowsPreview, "the writing shortcut should preview by default", &failures)
    check(settings.writingActionIDs == [compose.id, polish.id] && settings.writingTones == WritingTone.defaults,
      "the pop-up should start with Compose, Polish, and the shipped tones", &failures)
    check(settings.installedBuiltInActionIDs.contains(compose.id) && settings.hiddenActionIDs == [compose.id],
      "Compose should come installed, and off the lookup pop-up", &failures)
    check(settings.writingActions(customActions: []).map(\.id) == [compose.id, polish.id],
      "the writing pop-up should open its tabs on Compose", &failures)
    check(settings.writingStyle(forApp: "com.tinyspeck.slackmacgap")
        == WritingStyle(actionID: compose.id, language: .english, toneID: WritingTone.coworkersID),
      "an unseen app should open on Compose, in English, for coworkers", &failures)

    let custom = TranslationAction(name: "Email", rolePrompt: "${tone}", commandPrompt: "${text}")
    settings.writingActionIDs.insert(custom.id)
    check(settings.writingActions(customActions: [custom]).map(\.id) == [compose.id, polish.id, custom.id],
      "a custom action switched on for writing should join the pop-up", &failures)

    let line = WritingStyle(actionID: compose.id, language: .japanese, toneID: WritingTone.friendsID)
    check(!settings.remembersWritingStyle(line, forApp: "jp.naver.line.mac"),
      "a style never used should not count as remembered", &failures)
    settings.rememberWritingStyle(line, forApp: "jp.naver.line.mac")
    check(settings.remembersWritingStyle(line, forApp: "jp.naver.line.mac"),
      "a style just used should count as remembered, so it is not written again", &failures)
    check(settings.writingStyle(forApp: "jp.naver.line.mac") == line,
      "an app should reopen with the style last used in it", &failures)
    check(settings.writingStyle(forApp: "com.tinyspeck.slackmacgap") == line,
      "an unseen app should fall back to the style used last anywhere", &failures)
    let slack = WritingStyle(actionID: polish.id, language: .japanese, toneID: WritingTone.bossID)
    settings.rememberWritingStyle(slack, forApp: "com.tinyspeck.slackmacgap")
    check(settings.writingStyle(forApp: "jp.naver.line.mac") == line,
      "a style chosen in one app should not change another app's", &failures)
    check(settings.writingStyle(forApp: "com.tinyspeck.slackmacgap").actionID == polish.id,
      "an app should reopen on the action last used in it", &failures)
    check(!settings.remembersWritingStyle(slack, forApp: "com.apple.MobileSMS"),
      "an app that was never used should still need its style filed", &failures)
    check(settings.writingStyle(forApp: nil) == slack,
      "an app without a bundle identifier should use the style used last", &failures)

    let client = WritingTone(name: "Clients", instruction: "warm and formal, to a client")
    settings.writingTones.append(client)
    check(settings.writingTone(client.id) == client, "an added tone should be found by its identifier", &failures)
    check(settings.writingTone(UUID())?.id == WritingTone.friendsID,
      "a deleted tone should give way to the first one", &failures)
    settings.writingToneID = WritingTone.bossID
    check(settings.lastWritingToneInstruction == tone(WritingTone.bossID).instruction,
      "lookups should get the tone used last", &failures)

    do {
      let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
      check(decoded == settings, "writing settings did not survive a round trip", &failures)
    } catch {
      failures.append("writing settings coding threw: \(error)")
    }

    var reset = settings
    reset.hiddenActionIDs = []
    reset.writingActionIDs = []
    reset.resetActionPresentation()
    check(reset.hiddenActionIDs == [compose.id] && reset.writingActionIDs == [compose.id, polish.id],
      "resetting the actions should put Compose back in the writing pop-up only", &failures)

    var readded = AppSettings()
    readded.installedBuiltInActionIDs.remove(compose.id)
    readded.hiddenActionIDs = []
    readded.addActionTemplates([compose.id], customActions: [])
    check(readded.installedBuiltInActionIDs.contains(compose.id) && readded.hiddenActionIDs == [compose.id],
      "Compose added back from the templates should stay off the lookup pop-up", &failures)
  }

  // MARK: - Settings from 0.15

  private static func migrationFailures(_ failures: inout [String]) {
    do {
      // 0.15 had a fixed register and no Compose action.
      var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as! [String: Any]
      for key in ["writingActionIDs", "writingTones", "writingActionID", "writingToneID"] {
        legacy.removeValue(forKey: key)
      }
      legacy["writingRegister"] = "formal"
      legacy["writingTargetLanguage"] = "ja"
      legacy["writingStylesByApp"] = ["jp.naver.line.mac": ["language": "ja", "register": "casual"]]
      legacy["installedBuiltInActionIDs"] = TranslationAction.starterIDs.map(\.uuidString)
      legacy["actionOrder"] = TranslationAction.starterIDs.map(\.uuidString)
      legacy["hiddenActionIDs"] = [String]()
      let migrated = try JSONDecoder().decode(
        AppSettings.self,
        from: JSONSerialization.data(withJSONObject: legacy)
      )
      check(migrated.writingToneID == WritingTone.bossID && migrated.writingActionID == compose.id,
        "0.15's register should become the matching tone, on Compose", &failures)
      check(migrated.writingStylesByApp["jp.naver.line.mac"]
          == WritingStyle(actionID: compose.id, language: .japanese, toneID: WritingTone.friendsID),
        "a register 0.15 remembered for an app should become the matching tone", &failures)
      check(migrated.installedBuiltInActionIDs.contains(compose.id) && migrated.hiddenActionIDs == [compose.id],
        "upgrading should install Compose for the writing shortcut, off the lookup pop-up", &failures)
      check(migrated.orderedActions(customActions: []).map(\.id)
          == [translate.id, TranslationAction.builtIn(for: .definition).id, compose.id, polish.id],
        "Compose should join the action list beside Polish", &failures)
      check(migrated.writingActions(customActions: []).map(\.id) == [compose.id, polish.id]
          && migrated.writingTones == WritingTone.defaults,
        "upgrading should give the pop-up Compose, Polish, and the shipped tones", &failures)

      // Compose deleted after the upgrade stays deleted.
      var deleted = migrated
      deleted.installedBuiltInActionIDs.remove(compose.id)
      deleted.actionOrder.removeAll { $0 == compose.id }
      deleted.hiddenActionIDs = []
      deleted.writingActionIDs = [polish.id]
      let reloaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(deleted))
      check(!reloaded.installedBuiltInActionIDs.contains(compose.id) && reloaded.hiddenActionIDs.isEmpty,
        "a deleted Compose came back on reload", &failures)

      // Settings from before the compose pop-up open it with its defaults.
      var older = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as! [String: Any]
      for key in ["writingActionIDs", "writingTones", "writingActionID", "writingToneID",
        "writingStylesByApp", "writingShowsPreview"]
      {
        older.removeValue(forKey: key)
      }
      let fresh = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: older))
      check(fresh.writingToneID == WritingTone.coworkersID && fresh.writingStylesByApp.isEmpty
          && fresh.writingShowsPreview,
        "settings saved before the compose pop-up should open it with its defaults", &failures)
    } catch {
      failures.append("writing settings migration threw: \(error)")
    }
  }

  // MARK: - Placement

  private static func geometryFailures(_ failures: inout [String]) {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let size = CGSize(width: 480, height: 360)
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

    // Switching between reading and writing keeps the header where it was.
    let reading = CGRect(x: 400, y: 300, width: 480, height: 440)
    let writing = PopupHandOffGeometry.frame(size: size, replacing: reading, visibleFrame: screen)
    check(writing.minX == reading.minX && writing.maxY == reading.maxY && writing.size == size,
      "switching to writing should keep the pop-up's top-left corner", &failures)
    let low = CGRect(x: 400, y: 20, width: 480, height: 360)
    let taller = PopupHandOffGeometry.frame(size: CGSize(width: 480, height: 440), replacing: low, visibleFrame: screen)
    check(screen.contains(taller) && taller.minX == low.minX,
      "a taller state near the bottom of the screen should stay on screen", &failures)
  }

  private static func check(_ condition: @autoclosure () -> Bool, _ message: String, _ failures: inout [String]) {
    if !condition() { failures.append(message) }
  }
}
