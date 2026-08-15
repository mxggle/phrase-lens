import SwiftUI

struct ActionsView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @Environment(\.palette) private var palette
  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var draftActions: [TranslationAction] = []
  @State private var draftBuiltIns: [TranslationAction] = []
  @State private var selectedID: UUID?
  @State private var saveTask: Task<Void, Never>?
  @State private var splitFraction = 0.32
  /// Compact layouts show one column at a time; this is which one.
  @State private var showsEditorInCompact = false
  @State private var isConfirmingRemove = false
  @State private var isConfirmingRestore = false

  var body: some View {
    Group {
      if layoutWidth.isCompact {
        compactLayout
      } else {
        ResizableSplit(
          fraction: $splitFraction,
          leadingMin: AppMetrics.actionListMinWidth,
          trailingMin: AppMetrics.actionEditorMinWidth,
          // Already inside a compact check, so this split never stacks: the
          // section switches to one column at a time instead.
          stacksBelow: 0
        ) {
          actionList
        } trailing: {
          editorColumn
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.background)
    .onAppear {
      draftActions = model.customActions
      let overrides = Dictionary(
        settingsStore.settings.builtInActionOverrides.map { ($0.id, $0) },
        uniquingKeysWith: { _, latest in latest }
      )
      draftBuiltIns = TranslationAction.builtIns.map { overrides[$0.id] ?? $0 }
      selectedID = selectedID ?? orderedActions.first?.id
    }
    .onDisappear { flushPendingSave() }
    .onChange(of: draftActions) { _, actions in
      scheduleSave(actions)
    }
    .onChange(of: model.customActions) { _, actions in
      // The library loads asynchronously. If this screen opened before that
      // completed, hydrate the still-empty draft when the actions arrive.
      guard draftActions.isEmpty, !actions.isEmpty else { return }
      draftActions = actions
      normalizeActionOrder()
      selectedID = selectedID ?? orderedActions.first?.id
    }
    .onChange(of: draftBuiltIns) { _, actions in
      let overrides = actions.compactMap { action in
        TranslationAction.builtIns.first(where: { $0.id == action.id }) == action ? nil : action
      }
      // Loading the drafts is not an edit. Avoid publishing an identical
      // settings value while custom actions are still loading, because that
      // could temporarily invalidate a saved custom default.
      guard overrides != settingsStore.settings.builtInActionOverrides else { return }
      settingsStore.settings.builtInActionOverrides = overrides
    }
    // Both of these discard prompts the user wrote by hand, and neither can be
    // taken back, so neither happens on a single click.
    .confirmationDialog(
      "Delete \(selectedActionName)?",
      isPresented: $isConfirmingRemove,
      titleVisibility: .visible
    ) {
      Button("Delete Action", role: .destructive) { removeSelectedAction() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Its role prompt and command prompt are deleted with it. There is no undo.")
    }
    .confirmationDialog(
      "Restore the built-in actions?",
      isPresented: $isConfirmingRestore,
      titleVisibility: .visible
    ) {
      Button("Restore Defaults", role: .destructive) { restoreAllDefaults() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Every edit you have made to a built-in prompt is discarded, and the "
          + "actions you hid and the order you arranged them in go back to the "
          + "defaults. Your own custom actions are kept."
      )
    }
  }

  /// Named in the delete prompt so the dialog says what is about to go.
  private var selectedActionName: String {
    draftActions.first { $0.id == selectedID }?.name ?? "this action"
  }

  // MARK: - Compact

  /// One column at a time, with a back button, because neither the list nor
  /// the prompt editor is usable at half of a narrow window.
  @ViewBuilder
  private var compactLayout: some View {
    if showsEditorInCompact {
      VStack(spacing: 0) {
        HStack(spacing: AppSpacing.sm) {
          Button {
            withAnimation(AppMotion.state(reduceMotion: reduceMotion)) {
              showsEditorInCompact = false
            }
          } label: {
            AdaptiveLabel(title: "All Actions", symbol: "chevron.left")
          }
          .appButton(.ghost, size: .sm)
          .accessibilityLabel("Back to all actions")
          Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(palette.chrome)
        Hairline()
        editorColumn
      }
      .transition(.opacity)
    } else {
      actionList.transition(.opacity)
    }
  }

  // MARK: - List

  /// A source list with its add/remove bar underneath, which is where macOS
  /// puts list editing. Nothing here is a window-level command, so nothing
  /// here belongs in the top bar.
  private var actionList: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
          group("Display order", actions: orderedActions)
        }
        .padding(.horizontal, AppSpacing.sm + 2)
        .padding(.vertical, AppSpacing.md)
      }
      .scrollIndicators(.never)

      Hairline()

      HStack(spacing: AppSpacing.xs) {
        IconButton(title: "Add a custom action", symbol: "plus") {
          addAction()
        }
        IconButton(
          title: "Delete the selected action",
          symbol: "minus",
          isDisabled: !draftActions.contains(where: { $0.id == selectedID })
        ) {
          isConfirmingRemove = true
        }
        Spacer(minLength: 0)
        Button("Restore Defaults") { isConfirmingRestore = true }
          .appButton(.ghost, size: .sm)
          .help("Restore built-in actions, visibility, and display order")
      }
      .padding(.horizontal, AppSpacing.sm + 2)
      .frame(height: AppMetrics.paneFooterHeight)
      .background(palette.chrome)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.chrome.opacity(0.6))
  }

  private func group(
    _ title: String,
    actions: [TranslationAction]
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Eyebrow(text: title)
        .padding(.horizontal, AppSpacing.sm + 2)
        .padding(.bottom, AppSpacing.xs)
      ForEach(actions) { action in
        HStack(spacing: AppSpacing.xs) {
          Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.faintForeground)
            .frame(width: 24, height: 34)
            .contentShape(Rectangle())
            .draggable(action.id.uuidString)
            .help("Drag to reorder \(action.name)")
            .accessibilityHidden(true)
          NavRow(
            title: action.name.isEmpty ? "Untitled Action" : action.name,
            symbol: action.mode?.symbol ?? "sparkles",
            isSelected: action.id == selectedID,
            subtitle: isActionHidden(action.id) ? "Hidden" : nil,
            trailing: settingsStore.settings.defaultActionID == action.id ? "Default" : nil
          ) {
            selectedID = action.id
            if layoutWidth.isCompact {
              withAnimation(AppMotion.state(reduceMotion: reduceMotion)) {
                showsEditorInCompact = true
              }
            }
          }
          IconButton(
            title: isActionHidden(action.id) ? "Show \(action.name)" : "Hide \(action.name)",
            symbol: isActionHidden(action.id) ? "eye.slash" : "eye",
            isDisabled: !isActionHidden(action.id) && visibleActionCount == 1,
            isOn: isActionHidden(action.id)
          ) {
            toggleVisibility(action.id)
          }
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { values, _ in
          guard let value = values.first, let sourceID = UUID(uuidString: value) else { return false }
          moveAction(sourceID, before: action.id)
          return true
        }
        .accessibilityAction(named: "Move up") { moveAction(action.id, by: -1) }
        .accessibilityAction(named: "Move down") { moveAction(action.id, by: 1) }
      }
    }
  }

  // MARK: - Editor

  private var editorColumn: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppSpacing.lg) {
        editor
      }
      .padding(AppSpacing.lg)
      .frame(maxWidth: 720, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var editor: some View {
    if let index = draftActions.firstIndex(where: { $0.id == selectedID }) {
      actionEditor(action: $draftActions[index], isBuiltIn: false)
    } else if let index = draftBuiltIns.firstIndex(where: { $0.id == selectedID }) {
      actionEditor(action: $draftBuiltIns[index], isBuiltIn: true)
    } else {
      EmptyState(
        symbol: "slider.horizontal.3",
        title: "No action selected",
        message: "Choose an action on the left, or add a custom one."
      ) {
        Button("Add a Custom Action") { addAction() }
          .appButton(.primary, size: .sm)
      }
    }
  }

  @ViewBuilder
  private func actionEditor(action: Binding<TranslationAction>, isBuiltIn: Bool) -> some View {
    SettingsCard("Action", caption: "Changes are saved automatically.") {
      SettingsRow("Name") {
        AppTextField(
          placeholder: "Action name",
          text: action.name,
          size: .sm
        )
        .frame(maxWidth: 260)
      }
      Hairline()
      SettingsRow(
        "Render the result as Markdown",
        detail: "Headings, lists, tables, and fenced code are laid out instead of shown as text."
      ) {
        Toggle("", isOn: action.outputMarkdown)
          .toggleStyle(AppSwitchStyle())
          .labelsHidden()
          .accessibilityLabel("Render the result as Markdown")
      }
      Hairline()
      SettingsRow(
        "Show in translator",
        detail: "Hidden actions stay configured but do not appear in the action picker."
      ) {
        Toggle(
          "",
          isOn: Binding(
            get: { !isActionHidden(action.wrappedValue.id) },
            set: { setAction(action.wrappedValue.id, visible: $0) }
          )
        )
        .toggleStyle(AppSwitchStyle())
        .labelsHidden()
        .disabled(!isActionHidden(action.wrappedValue.id) && visibleActionCount == 1)
        .accessibilityLabel("Show in translator")
      }
      Hairline()
      SettingsRow(
        "Default action",
        detail: "Use this action when a new translation starts."
      ) {
        Button(
          settingsStore.settings.defaultActionID == action.wrappedValue.id
            ? "Default" : "Set as Default"
        ) {
          setDefaultAction(action.wrappedValue.id)
        }
        .appButton(
          settingsStore.settings.defaultActionID == action.wrappedValue.id
            ? .secondary : .outline,
          size: .sm
        )
        .disabled(settingsStore.settings.defaultActionID == action.wrappedValue.id)
      }
      Hairline()
      SettingsRow(
        "Duplicate action",
        detail: "Creates a new custom action starting from this one's current prompts."
      ) {
        Button("Duplicate") { duplicateAction(action.wrappedValue) }
          .appButton(.outline, size: .sm)
      }
    }

    SettingsCard(
      "System prompt",
      caption: "Sets the role the model answers in, before it sees the text.",
      showsChrome: false
    ) {
      AppTextEditor(
        text: action.rolePrompt,
        placeholder: "You are a helpful language assistant.",
        minHeight: 100
      )
    }

    SettingsCard(
      "Command prompt",
      caption: "What the model is asked to do with the text.",
      showsChrome: false
    ) {
      VStack(alignment: .leading, spacing: AppSpacing.sm) {
        AppTextEditor(
          text: action.commandPrompt,
          placeholder: "${text}",
          minHeight: 140
        )
        HStack(spacing: AppSpacing.xs + 2) {
          Text("Variables")
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
          ForEach(
            ["${sourceLang}", "${targetLang}", "${text}", "${context}"], id: \.self
          ) { variable in
            Text(variable)
              .font(AppFont.monoSmall)
              .foregroundStyle(palette.mutedForeground)
              .padding(.horizontal, 5)
              .padding(.vertical, 1.5)
              .background(
                palette.muted,
                in: RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous)
              )
              .help(variableHint(variable))
          }
        }
      }
    }

    HStack(spacing: AppSpacing.sm) {
      Button("Restore Default") { restoreAction(action.wrappedValue.id) }
        .appButton(.outline, size: .sm)
      Text(
        isBuiltIn
          ? "Restores the built-in prompt and display options."
          : "Restores the custom action template."
      )
        .font(AppFont.caption)
        .foregroundStyle(palette.mutedForeground)
    }
  }

  // MARK: - Editing

  private var allDraftActions: [TranslationAction] {
    draftBuiltIns + draftActions
  }

  private var orderedActions: [TranslationAction] {
    let actionsByID = Dictionary(uniqueKeysWithValues: allDraftActions.map { ($0.id, $0) })
    let ordered = settingsStore.settings.actionOrder.compactMap { actionsByID[$0] }
    let included = Set(ordered.map(\.id))
    return ordered + allDraftActions.filter { !included.contains($0.id) }
  }

  private var visibleActionCount: Int {
    allDraftActions.reduce(into: 0) { count, action in
      if !isActionHidden(action.id) { count += 1 }
    }
  }

  private func isActionHidden(_ id: UUID) -> Bool {
    settingsStore.settings.hiddenActionIDs.contains(id)
  }

  private func setAction(_ id: UUID, visible: Bool) {
    var hidden = settingsStore.settings.hiddenActionIDs
    if visible {
      hidden.remove(id)
    } else {
      guard visibleActionCount > 1 else { return }
      hidden.insert(id)
      if settingsStore.settings.defaultActionID == id,
        let replacement = orderedActions.first(where: { !hidden.contains($0.id) })
      {
        setDefaultAction(replacement.id)
      }
    }
    settingsStore.settings.hiddenActionIDs = hidden
  }

  private func toggleVisibility(_ id: UUID) {
    setAction(id, visible: isActionHidden(id))
  }

  private func setDefaultAction(_ id: UUID) {
    setAction(id, visible: true)
    settingsStore.setDefaultAction(id)
    model.selectedActionID = id
  }

  private func normalizeActionOrder() {
    let knownIDs = Set(allDraftActions.map(\.id))
    var seen = Set<UUID>()
    let saved = settingsStore.settings.actionOrder.filter {
      knownIDs.contains($0) && seen.insert($0).inserted
    }
    let missing = allDraftActions.map(\.id).filter { !seen.contains($0) }
    settingsStore.settings.actionOrder = saved + missing
  }

  private func moveAction(_ sourceID: UUID, before destinationID: UUID) {
    guard sourceID != destinationID else { return }
    var ids = orderedActions.map(\.id)
    guard let source = ids.firstIndex(of: sourceID),
      let destination = ids.firstIndex(of: destinationID)
    else { return }
    ids.remove(at: source)
    // Dropping downward places the source after the targeted row; dropping
    // upward places it before. This makes adjacent rows reorder instead of
    // turning a downward drop into a no-op.
    ids.insert(sourceID, at: min(destination, ids.count))
    settingsStore.settings.actionOrder = ids
  }

  private func moveAction(_ id: UUID, by offset: Int) {
    var ids = orderedActions.map(\.id)
    guard let source = ids.firstIndex(of: id) else { return }
    let destination = min(max(source + offset, 0), ids.count - 1)
    guard source != destination else { return }
    ids.swapAt(source, destination)
    settingsStore.settings.actionOrder = ids
  }

  private func restoreAction(_ id: UUID) {
    if let original = TranslationAction.builtIns.first(where: { $0.id == id }),
      let index = draftBuiltIns.firstIndex(where: { $0.id == id })
    {
      draftBuiltIns[index] = original
    } else if let index = draftActions.firstIndex(where: { $0.id == id }) {
      let name = draftActions[index].name
      draftActions[index] = TranslationAction(
        id: id,
        name: name.isEmpty ? "Custom Action" : name,
        rolePrompt: "You are a helpful language assistant.",
        commandPrompt: "${text}",
        outputMarkdown: false
      )
    }
    setAction(id, visible: true)
  }

  private func restoreAllDefaults() {
    draftBuiltIns = TranslationAction.builtIns
    model.resetActionConfiguration()
  }

  private func addAction() {
    let action = TranslationAction(
      name: "Custom Action",
      rolePrompt: "You are a helpful language assistant.",
      commandPrompt: "${text}",
      outputMarkdown: false
    )
    draftActions.append(action)
    settingsStore.settings.actionOrder.append(action.id)
    selectedID = action.id
    if layoutWidth.isCompact {
      showsEditorInCompact = true
    }
  }

  /// Copies any action — built-in or custom — into a new, independent custom
  /// action seeded with its current prompts. The copy always has `mode ==
  /// nil`, so it no longer inherits a built-in mode's dynamic behavior (e.g.
  /// Translate's single-word dictionary lookup); its prompts are exactly
  /// what was visible in the editor at the moment of duplication.
  private func duplicateAction(_ action: TranslationAction) {
    let base = action.name.isEmpty ? "Untitled Action" : action.name
    let copy = TranslationAction(
      name: "\(base) Copy",
      rolePrompt: action.rolePrompt,
      commandPrompt: action.commandPrompt,
      outputMarkdown: action.outputMarkdown
    )
    draftActions.append(copy)
    var order = settingsStore.settings.actionOrder
    if let index = order.firstIndex(of: action.id) {
      order.insert(copy.id, at: index + 1)
    } else {
      order.append(copy.id)
    }
    settingsStore.settings.actionOrder = order
    selectedID = copy.id
    if layoutWidth.isCompact {
      showsEditorInCompact = true
    }
  }

  private func variableHint(_ variable: String) -> String {
    switch variable {
    case "${sourceLang}": "The source language, e.g. \"Japanese\"."
    case "${targetLang}": "The target language, e.g. \"English\"."
    case "${text}": "The selected or entered text."
    case "${context}": "Surrounding text captured with the selection, when available."
    default: variable
    }
  }

  private func removeSelectedAction() {
    guard let selectedID else { return }
    let index = draftActions.firstIndex { $0.id == selectedID }
    draftActions.removeAll { $0.id == selectedID }
    settingsStore.settings.actionOrder.removeAll { $0 == selectedID }
    settingsStore.settings.hiddenActionIDs.remove(selectedID)
    if settingsStore.settings.defaultActionID == selectedID {
      setDefaultAction(orderedActions.first?.id ?? TranslationAction.builtIns[0].id)
    }
    self.selectedID =
      index.flatMap {
        draftActions.indices.contains($0) ? draftActions[$0].id : draftActions.last?.id
      }
      ?? orderedActions.first?.id
  }

  /// Typing in a prompt should not write to disk on every keystroke, and the
  /// user should not have to remember a Save button either.
  private func scheduleSave(_ actions: [TranslationAction]) {
    // Loading the drafts on appear is not an edit.
    guard actions != model.customActions else { return }
    saveTask?.cancel()
    saveTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled else { return }
      model.saveCustomActions(actions)
    }
  }

  private func flushPendingSave() {
    guard saveTask != nil else { return }
    saveTask?.cancel()
    saveTask = nil
    guard draftActions != model.customActions else { return }
    model.saveCustomActions(draftActions)
  }
}
