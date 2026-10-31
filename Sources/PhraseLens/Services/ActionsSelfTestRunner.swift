import Foundation

/// Action collection regressions use isolated preferences and library files.
/// No network requests, real credentials, hotkeys, or user data are involved.
@MainActor
enum ActionsSelfTestRunner {
  static func run() async -> [String] {
    var failures: [String] = []
    func check(_ value: Bool, _ message: String) {
      if !value { failures.append("Action collection: " + message) }
    }
    let suite = "PhraseLens-actions-test-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    let credentials = CredentialStore(directory: directory, defaults: defaults)
    let store = SettingsStore(defaults: defaults, credentials: credentials, loadStoredCredentials: false)
    let library = LibraryStore(directory: directory)
    let model = AppModel(settingsStore: store, library: library, integrateWithSystem: false)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let translate = TranslationAction.builtIn(for: .translate)
    let definition = TranslationAction.builtIn(for: .definition)
    let polish = TranslationAction.builtIn(for: .polishing)
    let compose = TranslationAction.builtIn(for: .compose)
    // Compose comes too, for the writing shortcut, but stays off the lookup surfaces.
    check(model.orderedActions.map(\.id) == [translate.id, definition.id, compose.id, polish.id],
      "new installations did not start with the three lookup actions and Compose")
    check(model.visibleActions.map(\.id) == [translate.id, definition.id, polish.id],
      "Compose showed up among the lookup actions of a new installation")
    check(store.settings.writingActions(customActions: model.customActions).map(\.id) == [compose.id, polish.id],
      "the writing pop-up did not start with Compose and Polish")

    do {
      // Legacy documents keep the full collection and all user configuration.
      var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.settings)) as! [String: Any]
      legacyObject.removeValue(forKey: "installedBuiltInActionIDs")
      let migrated = try JSONDecoder().decode(AppSettings.self,
        from: JSONSerialization.data(withJSONObject: legacyObject))
      check(migrated.resolvedBuiltInActions.count == TranslationAction.builtIns.count,
        "legacy presets disappeared during migration")
      check(migrated.actionOrder == store.settings.actionOrder,
        "migration changed the existing presentation order")

      // Undo must restore authored prompts, route, hidden state and position.
      var edited = definition
      edited.name = "My Definition"
      edited.rolePrompt = "Keep my edited instructions"
      edited.commandPrompt = "Explain ${text} briefly"
      edited.route = ActionRoute(connectionID: UUID(), model: "pinned-model")
      edited.outputMarkdown = false
      edited.resultCommands = [.insert, .copy]
      model.updateAction(edited)
      model.moveAction(edited.id, to: 0)
      model.setActionHidden(edited.id, hidden: true)
      let beforeDeletion = store.settings
      model.deleteAction(edited.id)
      check(!model.orderedActions.contains { $0.id == edited.id }, "deleted preset stayed in the list")
      let persisted = SettingsStore(defaults: defaults, credentials: credentials, loadStoredCredentials: false)
      check(!persisted.settings.resolvedBuiltInActions.contains { $0.id == edited.id },
        "deleted preset returned after reloading settings")
      model.undoActionDeletion()
      check(store.settings == beforeDeletion, "undo did not restore exact configuration")
      check(model.orderedActions.first == edited, "undo lost edited prompts, route, or position")

      model.deleteAction(polish.id)
      var unrelatedEdit = translate
      unrelatedEdit.commandPrompt = "Keep this later edit: ${text}"
      model.updateAction(unrelatedEdit)
      model.undoActionDeletion()
      check(model.orderedActions.contains(unrelatedEdit), "undo overwrote a later edit to another action")

      // Restoring missing presets preserves every existing item's configuration.
      model.deleteAction(polish.id)
      let priorOrder = model.orderedActions.map(\.id)
      let priorDefault = store.settings.defaultActionID
      model.restoreMissingDefaultActions()
      check(model.orderedActions.map(\.id).prefix(priorOrder.count) == priorOrder[...],
        "restoration changed the existing order")
      check(store.settings.defaultActionID == priorDefault
        && store.settings.hiddenActionIDs.contains(edited.id)
        && model.orderedActions.first == edited,
        "restoration overwrote edits, visibility, or the current default")
      let onceRestored = store.settings
      model.restoreMissingDefaultActions()
      check(store.settings == onceRestored, "repeated restoration was not a no-op")

      // The current default moves to a remaining visible item after deletion.
      model.setDefaultAction(translate.id)
      model.deleteAction(translate.id)
      check(model.selectedAction?.id != translate.id && model.selectedAction != nil
        && store.settings.defaultActionID != translate.id,
        "deleting the default left a dangling selection")
      model.undoActionDeletion()
      check(model.selectedAction?.id == translate.id && store.settings.defaultActionID == translate.id,
        "undo failed to restore the default and selection")

      // A custom deletion uses the same undo path and is persisted to the library.
      var custom = TranslationAction(name: "Edited custom", rolePrompt: "Custom role", commandPrompt: "${text}")
      custom.route = ActionRoute(connectionID: UUID(), model: "custom-model")
      model.saveCustomActions([custom])
      model.moveAction(custom.id, to: 1)
      model.setDefaultAction(custom.id)
      let customOrder = model.orderedActions.map(\.id)
      model.deleteAction(custom.id)
      check(model.customActions.isEmpty, "custom deletion did not update the model immediately")
      model.undoActionDeletion()
      check(model.customActions == [custom] && model.orderedActions.map(\.id) == customOrder
        && model.selectedAction == custom, "custom undo lost content, order, or the default")

      // Explicitly empty collections survive serialization and do not execute a fallback.
      for action in model.orderedActions { model.deleteAction(action.id) }
      check(model.visibleActions.isEmpty && model.selectedAction == nil, "empty collection used a phantom action")
      model.inputText = "This must not be sent"
      model.translate()
      model.translateWithAI()
      check(!model.isTranslating && model.errorMessage == nil && model.outputText.isEmpty,
        "empty collection attempted translation")
      model.translateFocusedInput()
      check(model.errorMessage != nil && !model.isTranslating,
        "writing shortcut did not explain that no action is set up for writing")
      model.errorMessage = nil
      let empty = SettingsStore(defaults: defaults, credentials: credentials, loadStoredCredentials: false)
      check(empty.settings.resolvedBuiltInActions.isEmpty, "empty collection was reseeded on reload")
      let reloaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(empty.settings))
      check(reloaded.resolvedBuiltInActions.isEmpty, "empty collection was reseeded on decode")

      // Undo every deletion, then restore one template without restoring all of them.
      while model.canUndoActionDeletion { model.undoActionDeletion() }
      check(model.customActions == [custom] && model.orderedActions.count == TranslationAction.builtIns.count + 1,
        "consecutive undo lost actions")
      for action in model.orderedActions { model.deleteAction(action.id) }
      model.addActionTemplates([definition.id])
      check(model.orderedActions == [definition] && model.selectedAction == definition,
        "adding a single template restored unrelated presets or stale edits")
      model.addActionTemplates([definition.id])
      check(model.orderedActions == [definition], "adding the same template created a duplicate")

      // Verify the final snapshot after all queued writes, without timing guesses.
      await model.flushActionPersistence()
      let diskActions = try await library.customActions()
      check(diskActions.isEmpty, "custom deletion was not persisted")
    } catch { failures.append("Action collection checks threw: \(error)") }
    return failures
  }
}
