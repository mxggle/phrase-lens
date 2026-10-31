import CoreGraphics
import Foundation

/// Self tests for the writing shortcut's pop-up and for action options: the
/// actions it runs, the options under them and how they reach the prompt,
/// what each app remembers, settings saved by 0.15, and where the pop-up
/// opens. All pure, so they run without another application to write into.
enum WritingSelfTests {
  static func run() -> [String] {
    var failures: [String] = []
    promptFailures(&failures)
    optionFailures(&failures)
    settingsFailures(&failures)
    migrationFailures(&failures)
    geometryFailures(&failures)
    return failures
  }

  private static let compose = TranslationAction.builtIn(for: .compose)
  private static let polish = TranslationAction.builtIn(for: .polishing)
  private static let translate = TranslationAction.builtIn(for: .translate)

  private static func option(_ id: UUID) -> ActionOption {
    ActionOption.composeDefaults.first { $0.id == id }!
  }

  // MARK: - Prompts

  private static func promptFailures(_ failures: inout [String]) {
    let draft = "  明天的会议我可能会晚到十分钟，你能帮我跟大家说一下吗？\n"
    let japanese = LanguageCode.japanese.displayName

    func writing(_ action: TranslationAction, _ text: String = draft, target: LanguageCode = .japanese,
      option: ActionOption?) -> TranslationPrompt
    {
      PromptBuilder.build(text: text, source: .auto, target: target, action: action, writing: true, option: option)
    }

    let boss = writing(compose, option: option(ActionOption.bossID))
    check(boss.user == "Draft:\n\n明天的会议我可能会晚到十分钟，你能帮我跟大家说一下吗？",
      "Compose should send the draft trimmed and unescaped, as the message to rewrite", &failures)
    check(boss.system.contains(japanese) && boss.system.contains("敬語"),
      "Compose for the boss should name the language and ask for keigo", &failures)
    check(boss.system.hasSuffix(option(ActionOption.bossID).instruction),
      "the picked option should be the last thing the system prompt says", &failures)
    check(boss.system.contains("never answer it"),
      "a draft that asks a question must be rewritten, not answered", &failures)
    check(boss.system.contains("no readings"),
      "a message to send must not carry furigana or romanization", &failures)
    check(!boss.system.contains("${") && !boss.user.contains("${"),
      "Compose left a template variable unsubstituted", &failures)
    check(boss.priorTurns.isEmpty, "the writing prompt should be a single turn", &failures)

    let friend = writing(compose, option: option(ActionOption.friendsID))
    check(friend.system.contains("タメ口") && !friend.system.contains("敬語"),
      "Compose for a friend should ask for タメ口 only", &failures)
    let english = writing(compose, "收到，谢谢", target: .english, option: option(ActionOption.bossID))
    check(english.system.contains(LanguageCode.english.displayName) && !english.system.contains(japanese),
      "an English message should name English only", &failures)

    let plain = writing(compose, option: nil)
    check(!plain.system.contains("Additional instruction") && boss.system.hasPrefix(plain.system),
      "with no option picked, the prompt should be the action's own, with nothing added", &failures)

    // An option with no instruction still says something: its name.
    let formal = ActionOption(name: "Formal", instruction: "  \n")
    check(writing(compose, option: formal).system.hasSuffix("Additional instruction for this answer: Formal"),
      "an option left without an instruction should add its name", &failures)

    // Compose is its template and nothing else: an edit is exactly what is sent.
    var edited = compose
    edited.rolePrompt = "Write in ${targetLang}. Keep it short."
    edited.commandPrompt = "${text}"
    let editedPrompt = writing(edited, option: nil)
    check(editedPrompt.system == "Write in \(japanese). Keep it short."
        && editedPrompt.user == draft.trimmingCharacters(in: .whitespacesAndNewlines),
      "an edited Compose prompt was not sent as written", &failures)

    let polished = writing(polish, "これはテストのです", option: nil)
    check(polished.user.contains("これはテストのです") && !polished.user.contains("${")
        && !polished.system.contains("${") && !polished.system.contains("Additional instruction"),
      "Polish in the writing pop-up should polish the draft as it is", &failures)

    // Any action can have options, and a lookup sends the picked one too.
    let rigorous = ActionOption(name: "Rigorous", instruction: "Keep terms exact; do not paraphrase.")
    let lookup = PromptBuilder.build(
      text: "hello", source: .english, target: .japanese, action: translate, option: rigorous
    )
    check(lookup.system.hasSuffix("Keep terms exact; do not paraphrase."),
      "a translation with an option should end its system prompt with the option", &failures)
    check(PromptBuilder.build(text: "hello", source: .english, target: .japanese, action: translate).system
        == PromptBuilder.build(text: "hello", source: .english, target: .japanese, action: translate, option: nil).system,
      "a translation without an option should be unchanged", &failures)
    let custom = TranslationAction(name: "Email", rolePrompt: "", commandPrompt: "${text}")
    check(PromptBuilder.build(text: "hi", source: .english, target: .japanese, action: custom, option: rigorous)
        .system == "Additional instruction for this answer: Keep terms exact; do not paraphrase.",
      "an action with no system prompt should get the option alone", &failures)

    check(compose.usesTargetLanguage && !polish.usesTargetLanguage && translate.usesTargetLanguage,
      "only the actions that write into a language should show the language switch", &failures)
    check(ResultCommand.defaults(for: .compose).first == .replace,
      "Compose's answer should be written back first", &failures)
  }

  // MARK: - Options

  private static func optionFailures(_ failures: inout [String]) {
    check(compose.availableOptions.map(\.id)
        == [ActionOption.friendsID, ActionOption.coworkersID, ActionOption.bossID]
        && compose.defaultOption?.id == ActionOption.coworkersID,
      "Compose should ship with friends, coworkers, and boss, coworkers picked", &failures)
    check(TranslationAction.builtIns.filter { $0.mode != .compose }.allSatisfy {
      $0.availableOptions.isEmpty && $0.defaultOption == nil
    }, "every other built-in should start with no options", &failures)

    let boss = option(ActionOption.bossID)
    check(["上司", "Boss"].contains(boss.displayName),
      "a shipped option should be named in the interface language", &failures)
    var renamed = boss
    renamed.name = "部長"
    check(renamed.displayName == "部長", "a renamed option should keep its new name", &failures)
    check(boss.styleName(in: .japanese) == "敬語"
        && option(ActionOption.coworkersID).styleName(in: .english) == "Professional",
      "shipped options should name their grammar in the language being written", &failures)
    var reworded = boss
    reworded.instruction = "very polite"
    check(reworded.styleName(in: .japanese) == nil && renamed.styleName(in: .japanese) == "敬語"
        && ActionOption(name: "Formal", instruction: "").styleName(in: .japanese) == nil,
      "only a shipped, unedited instruction should name its grammar", &failures)
    check(ActionOption.id(forLegacyRegister: "casual") == ActionOption.friendsID
        && ActionOption.id(forLegacyRegister: "polite") == ActionOption.coworkersID
        && ActionOption.id(forLegacyRegister: "formal") == ActionOption.bossID
        && ActionOption.id(forLegacyRegister: "royal") == nil,
      "0.15 registers should map onto Compose's options", &failures)

    // Options are part of the action, so they are saved and restored with it.
    do {
      var custom = TranslationAction(name: "Translate formally", commandPrompt: "${text}")
      custom.options = [ActionOption(name: "Formal", instruction: "Use formal written language.")]
      custom.defaultOptionID = custom.options?.first?.id
      let decoded = try JSONDecoder().decode(TranslationAction.self, from: JSONEncoder().encode(custom))
      check(decoded == custom, "an action's options did not survive a round trip", &failures)
      // An action saved before options existed has none.
      var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(translate)) as! [String: Any]
      legacy.removeValue(forKey: "options")
      legacy.removeValue(forKey: "defaultOptionID")
      let old = try JSONDecoder().decode(
        TranslationAction.self, from: JSONSerialization.data(withJSONObject: legacy)
      )
      check(old.availableOptions.isEmpty && old.defaultOption == nil,
        "an action saved before options should open with none", &failures)
    } catch {
      failures.append("action options coding threw: \(error)")
    }

    var gone = compose
    gone.defaultOptionID = UUID()
    check(gone.defaultOption == nil, "a default option that was deleted should count as none", &failures)

    check(WritingStyle.languageOptions(including: [.english, .japanese]) == [.japanese, .english],
      "the pop-up should offer Japanese and English", &failures)
    check(WritingStyle.languageOptions(including: [.korean, .japanese, .auto]) == [.japanese, .english, .korean],
      "a language chosen in Settings should join Japanese and English", &failures)
  }

  // MARK: - Settings

  private static func settingsFailures(_ failures: inout [String]) {
    var settings = AppSettings()
    check(settings.writingShowsPreview, "the writing shortcut should preview by default", &failures)
    check(settings.writingActionIDs == [compose.id, polish.id],
      "the pop-up should start with Compose and Polish", &failures)
    check(settings.installedBuiltInActionIDs.contains(compose.id) && settings.hiddenActionIDs == [compose.id],
      "Compose should come installed, and off the lookup pop-up", &failures)
    check(settings.writingActions(customActions: []).map(\.id) == [compose.id, polish.id],
      "the writing pop-up should open its tabs on Compose", &failures)
    check(settings.writingStyle(forApp: "com.tinyspeck.slackmacgap")
        == WritingStyle(actionID: compose.id, language: .english),
      "an unseen app should open on Compose, in English", &failures)

    let custom = TranslationAction(name: "Email", rolePrompt: "", commandPrompt: "${text}")
    settings.writingActionIDs.insert(custom.id)
    check(settings.writingActions(customActions: [custom]).map(\.id) == [compose.id, polish.id, custom.id],
      "a custom action switched on for writing should join the pop-up", &failures)

    let line = WritingStyle(actionID: compose.id, language: .japanese)
    check(!settings.remembersWritingStyle(line, forApp: "jp.naver.line.mac"),
      "a style never used should not count as remembered", &failures)
    settings.rememberWritingStyle(line, forApp: "jp.naver.line.mac")
    check(settings.remembersWritingStyle(line, forApp: "jp.naver.line.mac"),
      "a style just used should count as remembered, so it is not written again", &failures)
    check(settings.writingStyle(forApp: "jp.naver.line.mac") == line,
      "an app should reopen with the style last used in it", &failures)
    check(settings.writingStyle(forApp: "com.tinyspeck.slackmacgap") == line,
      "an unseen app should fall back to the style used last anywhere", &failures)
    let slack = WritingStyle(actionID: polish.id, language: .japanese)
    settings.rememberWritingStyle(slack, forApp: "com.tinyspeck.slackmacgap")
    check(settings.writingStyle(forApp: "jp.naver.line.mac") == line,
      "a style chosen in one app should not change another app's", &failures)
    check(settings.writingStyle(forApp: "com.tinyspeck.slackmacgap").actionID == polish.id,
      "an app should reopen on the action last used in it", &failures)
    check(settings.writingStyle(forApp: nil) == slack,
      "an app without a bundle identifier should use the style used last", &failures)

    // The option picked under each action, per app.
    let lineApp = "jp.naver.line.mac"
    let slackApp = "com.tinyspeck.slackmacgap"
    check(settings.chosenOption(for: compose, inApp: lineApp)?.id == ActionOption.coworkersID,
      "an action should start on its default option", &failures)
    check(settings.chosenOption(for: translate, inApp: lineApp) == nil,
      "an action without options should have none picked", &failures)
    check(!settings.remembersOption(ActionOption.friendsID, for: compose.id, inApp: lineApp),
      "an option never picked should not count as remembered", &failures)
    settings.rememberOption(ActionOption.friendsID, for: compose.id, inApp: lineApp)
    check(settings.remembersOption(ActionOption.friendsID, for: compose.id, inApp: lineApp),
      "an option just picked should count as remembered, so it is not written again", &failures)
    check(settings.chosenOption(for: compose, inApp: lineApp)?.id == ActionOption.friendsID,
      "an app should reopen on the option last picked in it", &failures)
    check(settings.chosenOption(for: compose, inApp: slackApp)?.id == ActionOption.friendsID,
      "an app with no choice of its own should take the one picked last anywhere", &failures)
    settings.rememberOption(ActionOption.bossID, for: compose.id, inApp: slackApp)
    check(settings.chosenOption(for: compose, inApp: lineApp)?.id == ActionOption.friendsID
        && settings.chosenOption(for: compose, inApp: slackApp)?.id == ActionOption.bossID,
      "an option picked in one app should not change another app's", &failures)
    settings.rememberOption(nil, for: compose.id, inApp: slackApp)
    check(settings.chosenOption(for: compose, inApp: slackApp) == nil
        && settings.chosenOption(for: compose, inApp: nil) == nil,
      "taking an option off should be remembered as none picked", &failures)
    check(settings.chosenOption(for: polish, inApp: slackApp) == nil,
      "a choice for one action should not touch another", &failures)
    var trimmed = compose
    trimmed.options = trimmed.options?.filter { $0.id != ActionOption.friendsID }
    check(settings.chosenOption(for: trimmed, inApp: lineApp)?.id == ActionOption.coworkersID,
      "an option deleted since it was picked should give way to the default", &failures)

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

    // A built-in whose options were edited is saved as an override.
    var edited = AppSettings()
    var formalTranslate = translate
    formalTranslate.options = [ActionOption(name: "Formal", instruction: "Formal and written.")]
    edited.builtInActionOverrides = [formalTranslate]
    check(edited.resolvedBuiltInActions.first { $0.id == translate.id }?.availableOptions.map(\.name) == ["Formal"],
      "options added to a built-in should be kept as its override", &failures)
  }

  // MARK: - Settings from 0.15

  private static func migrationFailures(_ failures: inout [String]) {
    do {
      // 0.15 had a fixed register and no Compose action.
      var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as! [String: Any]
      for key in ["writingActionIDs", "writingActionID", "actionOptionChoices"] {
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
      check(migrated.chosenOption(for: compose, inApp: "com.tinyspeck.slackmacgap")?.id == ActionOption.bossID
          && migrated.writingActionID == compose.id,
        "0.15's register should become Compose's matching option", &failures)
      check(migrated.chosenOption(for: compose, inApp: "jp.naver.line.mac")?.id == ActionOption.friendsID
          && migrated.writingStylesByApp["jp.naver.line.mac"]
            == WritingStyle(actionID: compose.id, language: .japanese),
        "a register 0.15 remembered for an app should become that app's option", &failures)
      check(migrated.installedBuiltInActionIDs.contains(compose.id) && migrated.hiddenActionIDs == [compose.id],
        "upgrading should install Compose for the writing shortcut, off the lookup pop-up", &failures)
      check(migrated.orderedActions(customActions: []).map(\.id)
          == [translate.id, TranslationAction.builtIn(for: .definition).id, compose.id, polish.id],
        "Compose should join the action list beside Polish", &failures)
      check(migrated.writingActions(customActions: []).map(\.id) == [compose.id, polish.id],
        "upgrading should give the pop-up Compose and Polish", &failures)

      // Once saved, the migrated choices are the choices: a later pick wins.
      var picked = migrated
      picked.rememberOption(nil, for: compose.id, inApp: "jp.naver.line.mac")
      let reread = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(picked))
      check(reread.chosenOption(for: compose, inApp: "jp.naver.line.mac") == nil,
        "a register from 0.15 should not override a choice made since", &failures)

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
      for key in ["writingActionIDs", "writingActionID", "writingStylesByApp", "writingShowsPreview",
        "actionOptionChoices"]
      {
        older.removeValue(forKey: key)
      }
      let fresh = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: older))
      check(fresh.actionOptionChoices.isEmpty && fresh.writingStylesByApp.isEmpty && fresh.writingShowsPreview
          && fresh.chosenOption(for: compose, inApp: nil)?.id == ActionOption.coworkersID,
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
  }

  private static func check(_ condition: @autoclosure () -> Bool, _ message: String, _ failures: inout [String]) {
    if !condition() { failures.append(message) }
  }
}
