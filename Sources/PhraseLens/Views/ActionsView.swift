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
      L10n.isChinese ? "确认删除动作“\(selectedActionName)”？" : "Delete \(selectedActionName)?",
      isPresented: $isConfirmingRemove,
      titleVisibility: .visible
    ) {
      Button(L10n.isChinese ? "删除动作" : "Delete Action", role: .destructive) { removeSelectedAction() }
      Button(L10n.isChinese ? "取消" : "Cancel", role: .cancel) {}
    } message: {
      Text(L10n.isChinese ? "该动作的角色提示词与执行命令将被一并删除，此操作无法撤销。" : "Its role prompt and command prompt are deleted with it. There is no undo.")
    }
    .confirmationDialog(
      L10n.isChinese ? "恢复所有内置动作？" : "Restore the built-in actions?",
      isPresented: $isConfirmingRestore,
      titleVisibility: .visible
    ) {
      Button(L10n.isChinese ? "恢复默认设置" : "Restore Defaults", role: .destructive) { restoreAllDefaults() }
      Button(L10n.isChinese ? "取消" : "Cancel", role: .cancel) {}
    } message: {
      Text(
        L10n.isChinese
          ? "对内置动作提示词所做的所有修改将被丢弃，动作的显示顺序与隐藏状态也将恢复默认。您自建的自定义动作将得到保留。"
          : "Every edit you have made to a built-in prompt is discarded, and the actions you hid and the order you arranged them in go back to the defaults. Your own custom actions are kept."
      )
    }
  }

  /// Named in the delete prompt so the dialog says what is about to go.
  private var selectedActionName: String {
    if let action = draftActions.first(where: { $0.id == selectedID }) {
      return action.name.isEmpty ? (L10n.isChinese ? "未命名动作" : "Untitled Action") : action.name
    }
    if let builtIn = draftBuiltIns.first(where: { $0.id == selectedID }) {
      return builtIn.name.isEmpty ? (L10n.isChinese ? "未命名动作" : "Untitled Action") : builtIn.name
    }
    return L10n.isChinese ? "此动作" : "this action"
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
            AdaptiveLabel(
              title: L10n.isChinese ? "所有动作" : "All Actions",
              symbol: "chevron.left"
            )
          }
          .appButton(.ghost, size: .sm)
          .accessibilityLabel(L10n.isChinese ? "返回动作列表" : "Back to all actions")
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
          group(L10n.isChinese ? "展示顺序与显示设置" : "Display order", actions: orderedActions)
        }
        .padding(.horizontal, AppSpacing.sm + 2)
        .padding(.vertical, AppSpacing.md)
      }
      .scrollIndicators(.never)

      Hairline()

      HStack(spacing: AppSpacing.xs) {
        IconButton(
          title: L10n.isChinese ? "新建动作" : "New action",
          symbol: "plus"
        ) {
          addAction()
        }
        IconButton(
          title: L10n.isChinese ? "删除此动作" : "Delete the selected action",
          symbol: "minus",
          isDisabled: !draftActions.contains(where: { $0.id == selectedID })
        ) {
          isConfirmingRemove = true
        }
        Spacer(minLength: 0)
        Button(L10n.isChinese ? "恢复默认动作" : "Restore default actions") { isConfirmingRestore = true }
          .appButton(.ghost, size: .sm)
          .help(L10n.isChinese ? "恢复内置动作、显示状态与展示顺序" : "Restore built-in actions, visibility, and display order")
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
        let isHidden = isActionHidden(action.id)
        HStack(spacing: AppSpacing.xs) {
          Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.faintForeground)
            .frame(width: 24, height: 34)
            .contentShape(Rectangle())
            .draggable(action.id.uuidString)
            .help(L10n.isChinese ? "拖拽以调整“\(action.name)”的顺序" : "Drag to reorder \(action.name)")
            .accessibilityHidden(true)
          NavRow(
            title: action.name.isEmpty ? (L10n.isChinese ? "未命名动作" : "Untitled Action") : action.name,
            symbol: action.mode?.symbol ?? "sparkles",
            isSelected: action.id == selectedID,
            subtitle: actionSubtitle(for: action),
            trailing: settingsStore.settings.defaultActionID == action.id
              ? (L10n.isChinese ? "默认" : "Default")
              : nil
          ) {
            selectedID = action.id
            if layoutWidth.isCompact {
              withAnimation(AppMotion.state(reduceMotion: reduceMotion)) {
                showsEditorInCompact = true
              }
            }
          }
          IconButton(
            title: L10n.isChinese
              ? (isHidden ? "显示动作" : "隐藏动作")
              : (isHidden ? "Show action" : "Hide action"),
            symbol: isHidden ? "eye.slash" : "eye",
            isDisabled: !isHidden && visibleActionCount == 1,
            isOn: isHidden
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
        .accessibilityAction(named: L10n.isChinese ? "上移" : "Move up") { moveAction(action.id, by: -1) }
        .accessibilityAction(named: L10n.isChinese ? "下移" : "Move down") { moveAction(action.id, by: 1) }
      }
    }
  }

  private func actionSubtitle(for action: TranslationAction) -> String {
    if isActionHidden(action.id) {
      return L10n.isChinese ? "已隐藏" : "Hidden"
    }
    return action.isBuiltIn
      ? (L10n.isChinese ? "内置" : "Built-in")
      : (L10n.isChinese ? "自定义" : "Custom")
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
        title: L10n.isChinese ? "未选择动作" : "No action selected",
        message: L10n.isChinese ? "请在左侧选择一个动作，或添加自定义动作。" : "Choose an action on the left, or add a custom one."
      ) {
        Button(L10n.isChinese ? "添加自定义动作" : "Add a Custom Action") { addAction() }
          .appButton(.primary, size: .sm)
      }
    }
  }

  @ViewBuilder
  private func actionEditor(action: Binding<TranslationAction>, isBuiltIn: Bool) -> some View {
    SettingsCard(
      L10n.isChinese ? "动作设置" : "Action",
      caption: L10n.isChinese ? "所做修改将自动保存。" : "Changes are saved automatically."
    ) {
      SettingsRow(L10n.isChinese ? "动作名称" : "Action name") {
        AppTextField(
          placeholder: L10n.isChinese ? "动作名称" : "Name",
          text: action.name,
          size: .sm
        )
        .frame(maxWidth: 260)
      }
      Hairline()
      SettingsRow(L10n.isChinese ? "执行模式" : "Execution mode") {
        Badge(
          text: isBuiltIn
            ? (L10n.isChinese ? "内置" : "Built-in")
            : (L10n.isChinese ? "自定义" : "Custom"),
          variant: .neutral
        )
      }
      Hairline()
      SettingsRow(
        L10n.isChinese ? "以 Markdown 格式渲染结果" : "Render as Markdown",
        detail: L10n.isChinese
          ? "支持渲染标题、加粗文本、代码块与列表项。"
          : "Formats headings, bold text, code blocks, and bullet points."
      ) {
        Toggle("", isOn: action.outputMarkdown)
          .toggleStyle(AppSwitchStyle())
          .labelsHidden()
          .accessibilityLabel(L10n.isChinese ? "以 Markdown 格式渲染结果" : "Render as Markdown")
      }
      Hairline()
      SettingsRow(
        L10n.isChinese ? "在翻译器中显示" : "Show in translator",
        detail: L10n.isChinese ? "隐藏的动作仍保留配置，但不会出现在动作选择器中。" : "Hidden actions stay configured but do not appear in the action picker."
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
        .accessibilityLabel(L10n.isChinese ? "在翻译器中显示" : "Show in translator")
      }
      Hairline()
      SettingsRow(
        L10n.isChinese ? "默认动作" : "Default action",
        detail: L10n.isChinese ? "新翻译开始时默认使用此动作。" : "Use this action when a new translation starts."
      ) {
        Button(
          settingsStore.settings.defaultActionID == action.wrappedValue.id
            ? (L10n.isChinese ? "默认" : "Default") : (L10n.isChinese ? "设为默认" : "Set as Default")
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
        L10n.isChinese ? "制作动作副本" : "Duplicate action",
        detail: L10n.isChinese ? "基于此动作当前的提示词创建一个新的自定义动作。" : "Creates a new custom action starting from this one's current prompts."
      ) {
        Button(L10n.isChinese ? "制作副本" : "Duplicate") { duplicateAction(action.wrappedValue) }
          .appButton(.outline, size: .sm)
      }
    }

    SettingsCard(
      L10n.isChinese ? "系统提示词 (Role Prompt)" : "System prompt",
      caption: L10n.isChinese ? "设定模型在查看文本前回答所扮演的角色。" : "Sets the role the model answers in, before it sees the text.",
      showsChrome: false
    ) {
      AppTextEditor(
        text: action.rolePrompt,
        placeholder: L10n.isChinese ? "设定 AI 的角色定位与行为原则…" : "System prompt instructions…",
        minHeight: 100
      )
    }

    SettingsCard(
      L10n.isChinese ? "用户提示词模板 (Command Prompt)" : "User prompt template",
      caption: L10n.isChinese ? "要求模型如何处理文本。" : "What the model is asked to do with the text.",
      showsChrome: false
    ) {
      VStack(alignment: .leading, spacing: AppSpacing.sm) {
        AppTextEditor(
          text: action.commandPrompt,
          placeholder: L10n.isChinese ? "输入发送给 AI 的提示词内容…" : "Command prompt template…",
          minHeight: 140
        )
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
          HStack(spacing: AppSpacing.xs + 2) {
            Text(L10n.isChinese ? "可用变量：" : "Available variables:")
              .font(AppFont.caption)
              .foregroundStyle(palette.mutedForeground)
            ForEach(
              ["${text}", "${sourceLang}", "${targetLang}", "${context}"], id: \.self
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
                .help("\(variable): \(variableHint(variable))")
            }
          }
          Text(
            [
              "${text}: \(variableHint("${text}"))",
              "${sourceLang}: \(variableHint("${sourceLang}"))",
              "${targetLang}: \(variableHint("${targetLang}"))",
              "${context}: \(variableHint("${context}"))",
            ].joined(separator: " · ")
          )
          .font(AppFont.caption)
          .foregroundStyle(palette.faintForeground)
        }
      }
    }

    HStack(spacing: AppSpacing.sm) {
      Button(L10n.isChinese ? "恢复此动作默认提示词" : "Reset to default prompt") {
        restoreAction(action.wrappedValue.id)
      }
      .appButton(.outline, size: .sm)

      if !isBuiltIn {
        Button(L10n.isChinese ? "删除此动作" : "Delete Action") {
          isConfirmingRemove = true
        }
        .appButton(.destructive, size: .sm)
      }

      Text(
        isBuiltIn
          ? (L10n.isChinese ? "恢复内置提示词与显示选项。" : "Restores the built-in prompt and display options.")
          : (L10n.isChinese ? "恢复自定义动作模板。" : "Restores the custom action template.")
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
        name: name.isEmpty ? (L10n.isChinese ? "自定义动作" : "Custom Action") : name,
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
      name: L10n.isChinese ? "自定义动作" : "Custom Action",
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
    let base = action.name.isEmpty ? (L10n.isChinese ? "未命名动作" : "Untitled Action") : action.name
    let copy = TranslationAction(
      name: L10n.isChinese ? "\(base) 副本" : "\(base) Copy",
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
    case "${text}":
      return L10n.isChinese ? "选中的文本" : "selected text"
    case "${sourceLang}":
      return L10n.isChinese ? "源语言" : "source language"
    case "${targetLang}":
      return L10n.isChinese ? "目标语言" : "target language"
    case "${context}":
      return L10n.isChinese ? "选区周围上下文" : "surrounding context"
    default:
      return variable
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
