import SwiftUI

struct ActionsView: View {
  @Environment(\.openSettings) private var openSettings
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @EnvironmentObject private var modelCatalog: ModelCatalogStore
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
      draftBuiltIns = settingsStore.settings.resolvedBuiltInActions
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
    .disabled(!model.isActionLibraryLoaded)
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
          if orderedActions.isEmpty {
            Text(L10n.isChinese ? "还没有动作。添加一个动作，或恢复默认动作。" : "No actions yet. Add an action or restore the defaults.")
              .font(AppFont.body)
              .foregroundStyle(palette.mutedForeground)
              .padding(AppSpacing.md)
          } else {
            group(L10n.isChinese ? "我的动作" : "My Actions", actions: orderedActions)
          }
        }
        .padding(.horizontal, AppSpacing.sm + 2)
        .padding(.vertical, AppSpacing.md)
      }
      .scrollIndicators(.never)

      Hairline()

      if model.canUndoActionDeletion {
        HStack(spacing: AppSpacing.sm) {
          Text(L10n.isChinese ? "已删除“\(model.lastDeletedActionName ?? "")”" : "Deleted \(model.lastDeletedActionName ?? "")")
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
            .lineLimit(1)
          Spacer(minLength: 0)
          Button(L10n.isChinese ? "撤销删除" : "Undo Delete") {
            saveDrafts()
            model.undoActionDeletion()
            reloadDrafts(selecting: model.selectedActionID)
          }
          .appButton(.ghost, size: .sm)
          .help(L10n.isChinese ? "恢复完整配置，包括修改过的提示词。退出应用前可撤销。" : "Restore the full configuration, including edited prompts. Available until the app quits.")
        }
        .padding(.horizontal, AppSpacing.sm + 2)
        .padding(.vertical, AppSpacing.xs)
        Hairline()
      }

      HStack(spacing: AppSpacing.xs) {
        Menu {
          Button(L10n.isChinese ? "新建动作" : "New Action") { addAction() }
          Menu(L10n.isChinese ? "从预置模板添加" : "Add from Templates") {
            ForEach(TranslationAction.builtIns) { action in
              let installed = settingsStore.settings.installedBuiltInActionIDs.contains(action.id)
              Button {
                saveDrafts()
                model.addActionTemplates([action.id])
                reloadDrafts(selecting: action.id)
                if layoutWidth.isCompact { showsEditorInCompact = true }
              } label: {
                Label(action.name, systemImage: installed ? "checkmark" : (action.mode?.symbol ?? "sparkles"))
              }
              .disabled(installed)
            }
          }
        } label: {
          Image(systemName: "plus")
            .frame(width: AppMetrics.controlHeight, height: AppMetrics.controlHeight)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.isChinese ? "添加动作" : "Add Action")
        .accessibilityLabel(L10n.isChinese ? "添加动作" : "Add Action")
        IconButton(
          title: L10n.isChinese ? "删除此动作" : "Delete the selected action",
          symbol: "minus",
          isDisabled: !orderedActions.contains(where: { $0.id == selectedID })
        ) {
          removeSelectedAction()
        }
        Spacer(minLength: 0)
        Button(L10n.isChinese ? "恢复默认动作" : "Restore default actions") { restoreAllDefaults() }
          .appButton(.ghost, size: .sm)
          .disabled(TranslationAction.defaultOrder.allSatisfy { settingsStore.settings.installedBuiltInActionIDs.contains($0) })
          .help(L10n.isChinese ? "补回缺失的预置动作，保留现有配置与顺序" : "Add missing presets, keeping existing configuration and order")
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
        ActionListRow(
          action: action,
          isSelected: action.id == selectedID,
          isHidden: isHidden,
          isDefault: settingsStore.settings.defaultActionID == action.id,
          isWriting: settingsStore.settings.writingActionIDs.contains(action.id),
          canHide: isHidden || visibleActionCount > 1,
          onSelect: {
            selectedID = action.id
            if layoutWidth.isCompact {
              withAnimation(AppMotion.state(reduceMotion: reduceMotion)) {
                showsEditorInCompact = true
              }
            }
          },
          onToggleVisibility: { toggleVisibility(action.id) }
        )
        .dropDestination(for: String.self) { values, _ in
          guard let value = values.first, let sourceID = UUID(uuidString: value) else { return false }
          moveAction(sourceID, before: action.id)
          return true
        }
        .contextMenu {
          Button(L10n.isChinese ? "删除动作" : "Delete Action", role: .destructive) {
            selectedID = action.id
            removeSelectedAction()
          }
        }
        .accessibilityAction(named: L10n.isChinese ? "删除动作" : "Delete Action") {
          selectedID = action.id
          removeSelectedAction()
        }
        .accessibilityAction(named: L10n.isChinese ? "上移" : "Move up") { moveAction(action.id, by: -1) }
        .accessibilityAction(named: L10n.isChinese ? "下移" : "Move down") { moveAction(action.id, by: 1) }
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
      .overlayScrollers()
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
        title: orderedActions.isEmpty ? (L10n.isChinese ? "还没有动作" : "No actions yet") : (L10n.isChinese ? "未选择动作" : "No action selected"),
        message: L10n.isChinese ? "新建动作，或恢复默认动作。从“＋”菜单也可以单独添加预置模板。" : "Create an action or restore the defaults. You can also add individual templates from the + menu."
      ) {
        VStack(spacing: AppSpacing.sm) {
          Button(L10n.isChinese ? "恢复默认动作" : "Restore Default Actions") { restoreAllDefaults() }
            .appButton(.primary, size: .sm)
            .disabled(TranslationAction.defaultOrder.allSatisfy { settingsStore.settings.installedBuiltInActionIDs.contains($0) })
          Text(L10n.isChinese ? "补回缺失动作，保留现有配置。" : "Add missing actions. Keep existing configuration.")
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
          Button(L10n.isChinese ? "新建动作" : "New Action") { addAction() }
            .appButton(.ghost, size: .sm)
        }
      }
    }
  }

  /// Which buttons the answer gets, and which of them is the pill.
  @ViewBuilder
  private func resultCommandsEditor(_ action: Binding<TranslationAction>) -> some View {
    SettingsRow(
      L10n.isChinese ? "结果按钮" : "Result buttons",
      detail: resultCommandsDetail(action.wrappedValue)
    ) {
      HStack(spacing: AppSpacing.xs) {
        ForEach(ResultCommand.allCases) { command in
          Toggle(
            command.title,
            isOn: Binding(
              get: { action.wrappedValue.resultCommands.contains(command) },
              set: { isOn in
                var commands = action.wrappedValue.resultCommands
                commands.removeAll { $0 == command }
                if isOn { commands.append(command) }
                // An answer always keeps at least one way out of the panel.
                guard !commands.isEmpty else { return }
                action.wrappedValue.resultCommands = commands
              }
            )
          )
          .toggleStyle(ChipToggleStyle())
        }
      }
    }
    // With a single button there is nothing to choose between.
    if action.wrappedValue.resultCommands.count > 1 {
      Hairline()
      SettingsRow(
        L10n.isChinese ? "主按钮" : "Primary button",
        detail: L10n.isChinese
          ? "以高亮样式显示。不适用时（例如选中的文字不可编辑），由下一个按钮代替。"
          : "Drawn highlighted. When it does not apply — the selection cannot be edited, say — the next button takes its place."
      ) {
        AppSelect(
          title: L10n.isChinese ? "主按钮" : "Primary button",
          selection: Binding(
            get: { action.wrappedValue.resultCommands.first ?? .copy },
            set: { primary in
              let rest = action.wrappedValue.resultCommands.filter { $0 != primary }
              action.wrappedValue.resultCommands = [primary] + rest
            }
          ),
          options: action.wrappedValue.resultCommands,
          label: { $0.title },
          size: .sm
        )
      }
    }
  }

  private func resultCommandsDetail(_ action: TranslationAction) -> String {
    var detail = L10n.isChinese
      ? "显示在结果下方。“替换”与“插入”仅在文字划选自其他应用的可编辑区域时出现。"
      : "Shown under the answer. Replace and Insert appear only when the text was selected in an editable field in another app."
    // A Markdown answer is written back as its source text, markers and all.
    if action.outputMarkdown, action.resultCommands.contains(where: \.writesToSource) {
      detail += L10n.isChinese
        ? " 此动作以 Markdown 输出，写回的文字会带有 Markdown 标记。"
        : " This action answers in Markdown, so what is written back keeps its Markdown markers."
    }
    return detail
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
      SettingsRow(L10n.isChinese ? "动作来源" : "Action source") {
        Badge(
          text: isBuiltIn
            ? (L10n.isChinese ? "预置" : "Preset")
            : (L10n.isChinese ? "自定义" : "Custom"),
          variant: .neutral
        )
      }
      Hairline()
      actionModelEditor(action)
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
      resultCommandsEditor(action)
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
        L10n.isChinese ? "写作时可用" : "Use when writing",
        detail: L10n.isChinese
          ? "在输入框里按 \(settingsStore.settings.shortcuts.writing) 时，出现在写作浮窗里，处理输入框里写好的文字，回车替换原文。"
          : "Offered in the pop-up that \(settingsStore.settings.shortcuts.writing) opens on a text field, working on what you wrote there. Return puts the result in its place."
      ) {
        Toggle(
          "",
          isOn: Binding(
            get: { settingsStore.settings.writingActionIDs.contains(action.wrappedValue.id) },
            set: { isOn in
              let id = action.wrappedValue.id
              guard settingsStore.settings.writingActionIDs.contains(id) != isOn else { return }
              if isOn {
                settingsStore.settings.writingActionIDs.insert(id)
              } else {
                settingsStore.settings.writingActionIDs.remove(id)
              }
            }
          )
        )
        .toggleStyle(AppSwitchStyle())
        .labelsHidden()
        .accessibilityLabel(L10n.isChinese ? "写作时可用" : "Use when writing")
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
          // Wraps, so a new variable never pushes the row past a narrow editor.
          FlowLayout(spacing: AppSpacing.xs + 2, lineSpacing: AppSpacing.xs) {
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

    optionsEditor(action)

    HStack(spacing: AppSpacing.sm) {
      Button(L10n.isChinese ? "恢复此动作默认提示词" : "Reset to default prompt") {
        restoreAction(action.wrappedValue.id)
      }
      .appButton(.outline, size: .sm)

      if !isBuiltIn {
        Button(L10n.isChinese ? "删除此动作" : "Delete Action") {
          removeSelectedAction()
        }
        .appButton(.destructive, size: .sm)
      }

      Text(
        isBuiltIn
          ? (L10n.isChinese ? "恢复预置的提示词、选项和显示设置，保留模型选择。" : "Restore the preset prompts, options, and display settings, keeping the model choice.")
          : (L10n.isChinese ? "恢复自定义动作模板。" : "Restores the custom action template.")
      )
      .font(AppFont.caption)
      .foregroundStyle(palette.mutedForeground)
    }
  }

  // MARK: - Options

  /// The choices shown under this action in the pop-ups. Each is a name and
  /// what is added to the end of the prompt when it is picked.
  @ViewBuilder
  private func optionsEditor(_ action: Binding<TranslationAction>) -> some View {
    let options = action.wrappedValue.availableOptions
    SettingsCard(
      L10n.isChinese ? "选项" : "Options",
      caption: L10n.isChinese
        ? "浮窗里显示在这个动作下面的一排。点一个，就把它的要求加到提示词最后；再点一下取消。没有选项，就不显示这一排。"
        : "A row under this action in the pop-ups. Clicking one adds its instruction to the end of the prompt; "
          + "clicking it again takes it off. With no options, there is no row."
    ) {
      if options.isEmpty {
        HStack(spacing: AppSpacing.sm) {
          Text(L10n.isChinese ? "这个动作还没有选项。" : "This action has no options yet.")
            .font(AppFont.body)
            .foregroundStyle(palette.mutedForeground)
          Spacer(minLength: 0)
          addOptionButton(action)
        }
        .padding(.vertical, AppSpacing.sm)
      } else {
        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
          if index > 0 { Hairline() }
          optionEditor(action, option: option, index: index, count: options.count)
        }
        Hairline()
        HStack(spacing: AppSpacing.sm) {
          addOptionButton(action)
          Spacer(minLength: 0)
          Text(L10n.isChinese ? "每个应用会记住上次选的选项。" : "Each app remembers the option picked last.")
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
        }
        .padding(.vertical, AppSpacing.xs)
      }
    }
  }

  private func optionEditor(
    _ action: Binding<TranslationAction>,
    option: ActionOption,
    index: Int,
    count: Int
  ) -> some View {
    VStack(alignment: .leading, spacing: AppSpacing.xs + 2) {
      HStack(spacing: AppSpacing.sm) {
        AppTextField(
          placeholder: L10n.isChinese ? "名称，例如：正式" : "Name, such as Formal",
          text: optionField(action, option.id, name: true),
          size: .sm
        )
        .frame(maxWidth: 200)
        Toggle(
          L10n.isChinese ? "默认" : "Default",
          isOn: Binding(
            get: { action.wrappedValue.defaultOptionID == option.id },
            set: { isOn in
              if isOn {
                action.wrappedValue.defaultOptionID = option.id
              } else if action.wrappedValue.defaultOptionID == option.id {
                action.wrappedValue.defaultOptionID = nil
              }
            }
          )
        )
        .toggleStyle(ChipToggleStyle())
        .help(
          L10n.isChinese
            ? "没选过的应用里先选中它。都不设为默认，就默认都不选。"
            : "Picked to begin with in apps where nothing was picked yet. With no default, nothing is."
        )
        Spacer(minLength: 0)
        IconButton(
          title: L10n.isChinese ? "上移" : "Move Up",
          symbol: "chevron.up",
          isDisabled: index == 0
        ) {
          moveOption(action, option.id, by: -1)
        }
        IconButton(
          title: L10n.isChinese ? "下移" : "Move Down",
          symbol: "chevron.down",
          isDisabled: index == count - 1
        ) {
          moveOption(action, option.id, by: 1)
        }
        IconButton(
          title: L10n.isChinese ? "删除选项" : "Delete Option",
          symbol: "trash"
        ) {
          deleteOption(action, option.id)
        }
      }
      AppTextEditor(
        text: optionField(action, option.id, name: false),
        placeholder: L10n.isChinese
          ? "要求，会加到提示词最后。例如：用书面、正式的说法，适合邮件。"
          : "The instruction added to the end of the prompt, such as: formal and written, fit for email.",
        minHeight: 52,
        monospaced: false
      )
    }
    .padding(.vertical, AppSpacing.sm)
  }

  private func addOptionButton(_ action: Binding<TranslationAction>) -> some View {
    Button {
      action.wrappedValue.options = action.wrappedValue.availableOptions + [
        ActionOption(name: L10n.isChinese ? "新选项" : "New Option", instruction: "")
      ]
    } label: {
      Label(L10n.isChinese ? "添加选项" : "Add Option", systemImage: "plus")
    }
    .appButton(.outline, size: .sm)
  }

  /// An option's name or instruction, found by identifier so a deletion
  /// elsewhere in the list cannot point an editor at the wrong option. A
  /// shipped name reads in the interface language until it is edited.
  private func optionField(_ action: Binding<TranslationAction>, _ id: UUID, name: Bool) -> Binding<String> {
    Binding(
      get: {
        guard let option = action.wrappedValue.availableOptions.first(where: { $0.id == id }) else { return "" }
        return name ? option.displayName : option.instruction
      },
      set: { value in
        var options = action.wrappedValue.availableOptions
        guard let index = options.firstIndex(where: { $0.id == id }) else { return }
        if name {
          guard value != options[index].displayName else { return }
          options[index].name = value
        } else {
          guard value != options[index].instruction else { return }
          options[index].instruction = value
        }
        action.wrappedValue.options = options
      }
    )
  }

  private func moveOption(_ action: Binding<TranslationAction>, _ id: UUID, by offset: Int) {
    var options = action.wrappedValue.availableOptions
    guard let index = options.firstIndex(where: { $0.id == id }),
      options.indices.contains(index + offset) else { return }
    options.swapAt(index, index + offset)
    action.wrappedValue.options = options
  }

  private func deleteOption(_ action: Binding<TranslationAction>, _ id: UUID) {
    let options = action.wrappedValue.availableOptions.filter { $0.id != id }
    action.wrappedValue.options = options.isEmpty ? nil : options
    if action.wrappedValue.defaultOptionID == id {
      action.wrappedValue.defaultOptionID = nil
    }
  }

  // MARK: - Editing

  private var allDraftActions: [TranslationAction] {
    draftBuiltIns + draftActions
  }

  private var orderedActions: [TranslationAction] {
    let actionsByID = Dictionary(uniqueKeysWithValues: allDraftActions.map { ($0.id, $0) })
    return AppSettings.completedActionOrder(
      settingsStore.settings.actionOrder, available: allDraftActions.map(\.id)
    ).compactMap { actionsByID[$0] }
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
    settingsStore.settings.actionOrder = AppSettings.completedActionOrder(
      settingsStore.settings.actionOrder, available: allDraftActions.map(\.id)
    )
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

  @ViewBuilder
  private func actionModelEditor(_ action: Binding<TranslationAction>) -> some View {
    let resolved = try? settingsStore.resolve(action.wrappedValue)
    let configuration = resolved?.1 ?? settingsStore.settings.provider
    let override = action.wrappedValue.route?.model
    let useDefault = L10n.isChinese ? "使用全局默认" : "Use global default"
    let defaultConnection = settingsStore.settings.connections.first {
      $0.id == settingsStore.settings.defaultConnectionID
    }
    let defaultSummary = defaultConnection.map {
      "\($0.name) · \(settingsStore.settings.defaultModel ?? $0.configuration.model)"
    } ?? (L10n.isChinese ? "尚未设置" : "Not configured")
    let connectionName = resolved?.0.name ?? (L10n.isChinese ? "连接不可用" : "Connection unavailable")
    SettingsRow(
      L10n.isChinese ? "动作模型" : "Action model",
      detail: L10n.isChinese
        ? "使用 \(connectionName) · \(configuration.model)。后续提问沿用这组连接和模型。"
        : "Uses \(connectionName) · \(configuration.model). Follow-up questions keep this connection and model.",
      stacksControl: true
    ) {
      VStack(alignment: .leading, spacing: AppSpacing.sm) {
        HStack(spacing: AppSpacing.sm) {
          AppSelect(
            title: L10n.isChinese ? "模型选择" : "Model choice",
            selection: Binding(
              get: { override != nil },
              set: { usesOverride in
                let initialModel = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  ? configuration.provider.defaultModel : configuration.model
                action.wrappedValue.route = usesOverride ? resolved.map { ActionRoute(connectionID: $0.0.id, model: initialModel) } : nil
              }
            ),
            options: [false, true],
            label: { usesOverride in
              usesOverride
                ? (L10n.isChinese ? "为此动作选择模型" : "Choose a model for this action")
                : "\(useDefault) (\(defaultSummary))"
            },
            fillsWidth: true
          )
          AppMenuButton(title: L10n.isChinese ? "添加连接" : "Add connection", symbol: "plus") {
            ForEach(ProviderKind.allCases) { provider in
              Button(provider.rawValue) {
                let id = settingsStore.addConnection(provider: provider)
                action.wrappedValue.route = ActionRoute(connectionID: id, model: provider.defaultModel)
                SettingsNavigation.show(.provider) { openSettings() }
              }
            }
          }
        }
        if override != nil {
          AppSelect(
            title: L10n.isChinese ? "连接" : "Connection",
            selection: Binding(
              get: { action.wrappedValue.route?.connectionID ?? settingsStore.settings.defaultConnectionID },
              set: { id in
                if let connection = settingsStore.settings.connections.first(where: { $0.id == id }) {
                  action.wrappedValue.route = ActionRoute(connectionID: connection.id, model: connection.configuration.model)
                }
              }
            ),
            options: settingsStore.settings.connections.map { Optional($0.id) },
            label: { id in
              settingsStore.settings.connections.first { $0.id == id }?.name
                ?? (L10n.isChinese ? "连接不可用" : "Connection unavailable")
            },
            symbol: "point.3.connected.trianglepath.dotted",
            fillsWidth: true
          )
          HStack(spacing: AppSpacing.sm) {
            SearchableSelect(
              title: L10n.isChinese ? "动作模型" : "Action model",
              selection: Binding(
                get: { action.wrappedValue.route?.model ?? "" },
                set: { action.wrappedValue.route?.model = $0 }
              ),
              options: actionModels(for: configuration, current: override),
              placeholder: L10n.tr("sidebar.no_model"),
              searchPrompt: L10n.tr("settings.provider.search_prompt"),
              emptyMessage: L10n.isChinese ? "刷新模型目录，或输入模型 ID。" : "Refresh the catalog, or type a model ID.",
              customValueLabel: { L10n.tr("settings.provider.use_custom_model", $0) }
            )
            Button {
              let store = settingsStore
              let proxy = store.settings.proxy
              modelCatalog.refresh(configuration: configuration, proxy: proxy) {
                guard let connection = resolved?.0 else { throw TranslationError.missingAPIKey }
                return try await store.validCredentials(for: connection, proxy: proxy).accessToken
              }
            } label: {
              AdaptiveLabel(title: L10n.tr("common.refresh"), symbol: "arrow.clockwise")
            }
            .appButton(.outline, size: .sm)
            .disabled(modelCatalog.isFetching(configuration) || !(resolved.map { settingsStore.hasCredential(for: $0.0) } ?? false) || configuration.provider == .azure)
          }
          if let error = modelCatalog.error(for: configuration) {
            InlineNote(text: error, kind: .error)
          }
        }
      }
    }
  }

  private func actionModels(for configuration: ProviderConfiguration, current: String?) -> [String] {
    var models = modelCatalog.models(for: configuration)
    if configuration.provider.supportsOAuth && configuration.authMode == .oauthCodex, models.isEmpty {
      models = CodexBackend.fallbackModels
    }
    for model in [current, configuration.model].compactMap({ $0 }) where !model.isEmpty && !models.contains(model) {
      models.insert(model, at: 0)
    }
    return models
  }

  private func restoreAction(_ id: UUID) {
    if let original = TranslationAction.builtIns.first(where: { $0.id == id }),
      let index = draftBuiltIns.firstIndex(where: { $0.id == id })
    {
      var restored = original
      restored.modelOverrides = draftBuiltIns[index].modelOverrides
      restored.route = draftBuiltIns[index].route
      draftBuiltIns[index] = restored
    } else if let index = draftActions.firstIndex(where: { $0.id == id }) {
      let name = draftActions[index].name
      let route = draftActions[index].route
      let modelOverrides = draftActions[index].modelOverrides
      draftActions[index] = TranslationAction(
        id: id,
        name: name.isEmpty ? (L10n.isChinese ? "自定义动作" : "Custom Action") : name,
        rolePrompt: "You are a helpful language assistant.",
        commandPrompt: "${text}",
        outputMarkdown: false,
        modelOverrides: modelOverrides, route: route
      )
    }
    setAction(id, visible: true)
  }

  private func restoreAllDefaults() {
    saveDrafts()
    model.restoreMissingDefaultActions()
    reloadDrafts()
  }

  /// Commit current editor text before structural edits, so Undo captures it.
  private func saveDrafts() {
    saveTask?.cancel()
    saveTask = nil
    if draftActions != model.customActions { model.saveCustomActions(draftActions) }
    let overrides = draftBuiltIns.filter { TranslationAction.factoryBuiltIn(for: $0.id) != $0 }
    if overrides != settingsStore.settings.builtInActionOverrides {
      settingsStore.settings.builtInActionOverrides = overrides
    }
  }

  private func reloadDrafts(selecting id: UUID? = nil) {
    draftActions = model.customActions
    draftBuiltIns = settingsStore.settings.resolvedBuiltInActions
    if let id, orderedActions.contains(where: { $0.id == id }) { selectedID = id }
    else if !orderedActions.contains(where: { $0.id == selectedID }) {
      selectedID = orderedActions.first?.id
    }
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
  /// nil`, so it no longer inherits a built-in mode's dynamic behavior; its
  /// prompts are exactly
  /// what was visible in the editor at the moment of duplication.
  private func duplicateAction(_ action: TranslationAction) {
    let base = action.name.isEmpty ? (L10n.isChinese ? "未命名动作" : "Untitled Action") : action.name
    let copy = TranslationAction(
      name: L10n.isChinese ? "\(base) 副本" : "\(base) Copy",
      rolePrompt: action.rolePrompt,
      commandPrompt: action.commandPrompt,
      outputMarkdown: action.outputMarkdown,
      resultCommands: action.resultCommands,
      modelOverrides: action.modelOverrides, route: action.route,
      options: action.options,
      defaultOptionID: action.defaultOptionID
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
    saveDrafts()
    model.deleteAction(selectedID)
    reloadDrafts()
    if orderedActions.isEmpty { showsEditorInCompact = false }
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
    guard model.isActionLibraryLoaded else { return }
    saveDrafts()
  }
}

// MARK: - List row

/// One action in the source list: what it is, whether it is the default, and
/// whether the translator shows it.
///
/// The row is one selectable surface, drag handle included, so the selection
/// reads as a single object rather than a highlighted label floating between a
/// grip and an eye. The grip and the visibility switch stay faint until the
/// pointer is on the row; a hidden action keeps its crossed-out eye in sight,
/// because that is the state the row exists to show.
private struct ActionListRow: View {
  let action: TranslationAction
  let isSelected: Bool
  let isHidden: Bool
  let isDefault: Bool
  /// Offered in the writing pop-up.
  let isWriting: Bool
  let canHide: Bool
  let onSelect: () -> Void
  let onToggleVisibility: () -> Void

  @Environment(\.palette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  private var name: String {
    action.name.isEmpty ? (L10n.isChinese ? "未命名动作" : "Untitled Action") : action.name
  }

  private var kind: String {
    action.isBuiltIn ? (L10n.isChinese ? "预置" : "Preset") : (L10n.isChinese ? "自定义" : "Custom")
  }

  var body: some View {
    HStack(spacing: AppSpacing.sm) {
      Image(systemName: "line.3.horizontal")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(palette.faintForeground)
        .opacity(isHovering ? 1 : 0.35)
        .frame(width: 14, height: 30)
        .contentShape(Rectangle())
        .draggable(action.id.uuidString)
        .help(L10n.isChinese ? "拖拽以调整“\(name)”的顺序" : "Drag to reorder \(name)")
        .accessibilityHidden(true)

      Button(action: onSelect) {
        HStack(spacing: AppSpacing.sm + 2) {
          Image(systemName: action.mode?.symbol ?? "sparkles")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isSelected ? palette.foreground : palette.mutedForeground)
            .frame(width: 16)
          VStack(alignment: .leading, spacing: 1) {
            Text(name)
              .font(AppFont.bodyMedium)
              .foregroundStyle(isHidden ? palette.mutedForeground : palette.foreground)
              .lineLimit(1)
              .truncationMode(.tail)
            // The default is a property of the action, so it is said on the
            // action's own line rather than with a badge that takes the width
            // the name needs.
            HStack(spacing: AppSpacing.xs) {
              Text(isHidden ? (L10n.isChinese ? "\(kind) · 已隐藏" : "\(kind) · Hidden") : kind)
                .foregroundStyle(palette.mutedForeground)
              if isWriting {
                Text("·").foregroundStyle(palette.faintForeground)
                Text(L10n.isChinese ? "写作" : "Writing")
                  .foregroundStyle(palette.mutedForeground)
                  .help(L10n.isChinese ? "出现在写作浮窗里" : "Offered in the writing pop-up")
              }
              if isDefault {
                Text("·").foregroundStyle(palette.faintForeground)
                Text(L10n.isChinese ? "默认" : "Default")
                  .fontWeight(.medium)
                  .foregroundStyle(palette.accent)
              }
            }
            .font(AppFont.caption)
            .lineLimit(1)
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(name)
      .accessibilityValue(isDefault ? (L10n.isChinese ? "默认动作" : "Default action") : "")
      .accessibilityAddTraits(isSelected ? [.isSelected] : [])

      IconButton(
        title: L10n.isChinese
          ? (isHidden ? "显示动作" : "隐藏动作")
          : (isHidden ? "Show action" : "Hide action"),
        symbol: isHidden ? "eye.slash" : "eye",
        isDisabled: !canHide
      ) {
        onToggleVisibility()
      }
      .opacity(isHovering || isHidden || isSelected ? 1 : 0)
    }
    .padding(.leading, AppSpacing.xs)
    .padding(.trailing, AppSpacing.xxs)
    .padding(.vertical, AppSpacing.xs + 1)
    .background(fill, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .animation(AppMotion.hover(reduceMotion: reduceMotion), value: isHovering)
    .animation(AppMotion.hover(reduceMotion: reduceMotion), value: isSelected)
  }

  private var fill: Color {
    if isSelected { return palette.accentFill }
    return isHovering ? palette.muted : .clear
  }
}

/// Recovery stays available on translation surfaces even after the last deletion.
struct NoActionsView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    EmptyState(
      symbol: "slider.horizontal.3",
      title: L10n.isChinese ? "还没有动作" : "No actions yet",
      message: L10n.isChinese
        ? "添加一个动作即可继续。恢复默认动作只会补回缺失项，保留现有配置。"
        : "Add an action to continue. Restoring defaults only adds missing actions and keeps existing configuration."
    ) {
      VStack(spacing: AppSpacing.sm) {
        Button(L10n.isChinese ? "恢复默认动作" : "Restore Default Actions") {
          model.restoreMissingDefaultActions()
        }
        .appButton(.primary, size: .sm)
        Button(L10n.isChinese ? "添加动作" : "Add Actions") { model.openActions() }
          .appButton(.ghost, size: .sm)
      }
      .disabled(!model.isActionLibraryLoaded)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
