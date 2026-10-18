import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
  case setup
  case translator
  case learning
  case history
  case vocabulary
  case actions

  var id: String { rawValue }

  var title: String {
    switch self {
    case .setup: L10n.isChinese ? "新手引导" : "Getting Started"
    case .translator: L10n.isChinese ? "翻译" : "Translator"
    case .learning: L10n.isChinese ? "学习中心" : "Study"
    case .history: L10n.isChinese ? "历史记录" : "History"
    case .vocabulary: L10n.isChinese ? "生词本" : "Vocabulary"
    case .actions: L10n.isChinese ? "动作配置" : "Actions"
    }
  }

  var symbol: String {
    switch self {
    case .setup: "checklist"
    case .translator: "character.bubble"
    case .learning: "graduationcap"
    case .history: "clock.arrow.circlepath"
    case .vocabulary: "books.vertical"
    case .actions: "slider.horizontal.3"
    }
  }

  /// One line under the section title in the top bar. Says what the section is
  /// for, so the window never shows a bare noun with no context.
  var caption: String {
    switch self {
    case .setup: L10n.isChinese ? "连接服务商、启用快捷键并体验首次翻译" : "Connect a provider, enable shortcuts, and try a translation"
    case .translator: L10n.isChinese ? "翻译、润色与解析文本" : "Translate, rewrite, and explain text"
    case .learning: L10n.isChinese ? "反复查询、相关词、复习与学习诊断" : "Repeats, related terms, review, and diagnosis"
    case .history: L10n.isChinese ? "保存在本机的所有翻译记录" : "Every translation saved on this Mac"
    case .vocabulary: L10n.isChinese ? "阅读时收集的高频词汇" : "Words you collected while reading"
    case .actions: L10n.isChinese ? "定制每个动作背后的提示词" : "The prompts behind each action"
    }
  }

  /// Whether the top bar spells the caption out under the title.
  ///
  /// A section whose bar carries controls does not: a standing tagline beside
  /// a live control strip is decoration, and it spends the width the controls
  /// need.
  var showsCaption: Bool {
    self != .translator && self != .learning
  }

  /// Sidebar grouping.
  var group: Group {
    switch self {
    case .setup: .configure
    case .translator, .learning: .workspace
    case .history, .vocabulary: .library
    case .actions: .configure
    }
  }

  enum Group: String, CaseIterable, Identifiable {
    case workspace = "Workspace"
    case library = "Library"
    case configure = "Configure"

    var id: String { rawValue }

    var title: String {
      switch self {
      case .workspace: L10n.isChinese ? "工作区" : "Workspace"
      case .library: L10n.isChinese ? "资源库" : "Library"
      case .configure: L10n.isChinese ? "设置" : "Configure"
      }
    }
  }
}

/// How much of the sidebar is showing.
enum SidebarMode {
  /// Full width, labels visible.
  case expanded
  /// Icon rail. Chosen automatically in a narrow window, or pinned by the user.
  case rail
}

struct RootView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  @State private var selection: AppSection = .translator
  /// `nil` means "follow the window width". Set once the user picks a side.
  @State private var pinnedSidebarMode: SidebarMode?

  var body: some View {
    ThemedContainer {
      WidthReader { _, windowWidth in
        Shell(
          selection: $selection,
          mode: sidebarMode(forWindowWidth: windowWidth),
          canToggle: windowWidth >= AppBreakpoints.sidebarRail,
          onToggle: {
            withAnimation(AppMotion.state(reduceMotion: reduceMotion)) {
              pinnedSidebarMode =
                sidebarMode(forWindowWidth: windowWidth) == .expanded ? .rail : .expanded
            }
          }
        )
      }
    }
    // `fullSizeContentView` makes the content view span the title bar, but
    // SwiftUI then insets the content by the bar's height so nothing hides
    // under it. The sidebar reserves that space deliberately, so the inset has
    // to go or it is paid twice.
    .ignoresSafeArea(.container, edges: .top)
    .background(WindowChrome().frame(width: 0, height: 0))
    // Only a view inside the scene can hand out `openWindow`, and the window
    // that needs re-opening is gone by the time it is asked for. Handing the
    // action over while the window is alive is what lets it come back.
    .onAppear {
      WindowCoordinator.registerMainWindowOpener {
        openWindow(id: WindowCoordinator.mainWindowSceneID)
      }
      if settingsStore.shouldShowSetupGuide { selection = .setup }
      #if DEBUG
      // Visual QA: `--preview-section history` opens a section, and
      // `--preview-settings provider` opens Settings on a pane.
      let arguments = CommandLine.arguments
      if let index = arguments.firstIndex(of: "--preview-section"), index + 1 < arguments.count,
        let section = AppSection(rawValue: arguments[index + 1]) {
        selection = section
      }
      if let index = arguments.firstIndex(of: "--preview-learning-tab"), index + 1 < arguments.count,
        let tab = LearningTab(rawValue: arguments[index + 1]) {
        model.learning.tab = tab
      }
      if arguments.contains("--preview-assistant") {
        model.learning.assistantMessages = [
          AssistantMessage(role: .user, text: "我最近学习上卡在哪里？"),
          AssistantMessage(
            role: .assistant,
            text: """
              ## 你卡在哪里
              1. **affect 反复查仍记不住**：4 天查了 4 次，还问过它和 effect 的区别。
                 - 建议：做一张对比卡，affect 主要作动词（影响），effect 主要作名词（效果）。
              2. **形近词对容易混**：affect / effect、adopt / adapt 都还没分清。
              3. **长句结构要靠逐块拆解**：*It was not until the 1990s that…* 这类句型问了 3 次。

              优先复习：affect、勉強、adopt。
              """,
            events: [
              AssistantToolEvent(name: "get_report", summary: "读取学习诊断"),
              AssistantToolEvent(name: "get_stats", summary: "统计最近 14 天"),
              AssistantToolEvent(name: "search_terms", summary: "列出词条（stubborn）"),
            ]
          ),
        ]
      }
      if let index = arguments.firstIndex(of: "--preview-learning-term"), index + 1 < arguments.count {
        let word = arguments[index + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
          if let term = model.learning.terms.first(where: { $0.display == word || $0.headword == word }) {
            model.learning.select(term.id)
          }
        }
      }
      if let index = arguments.firstIndex(of: "--preview-size"), index + 1 < arguments.count {
        let parts = arguments[index + 1].split(separator: "x").compactMap { Double($0) }
        if parts.count == 2 {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            WindowCoordinator.mainWindow()?.setContentSize(NSSize(width: parts[0], height: parts[1]))
          }
        }
      }
      if let index = arguments.firstIndex(of: "--preview-settings"), index + 1 < arguments.count,
        let pane = SettingsPane(rawValue: arguments[index + 1]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
          SettingsNavigation.show(pane) { openSettings() }
        }
      }
      #endif
    }
    .onChange(of: model.translatorFocusToken) { _, _ in selection = .translator }
    .onChange(of: model.actionsFocusToken) { _, _ in selection = .actions }
    .onChange(of: model.learningFocusToken) { _, _ in selection = .learning }
    .preferredColorScheme(settingsStore.settings.theme.preferredColorScheme)
    .environment(\.locale, settingsStore.resolvedLocale)
    .alert(
      "PhraseLens",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      if model.isAccessibilityPermissionError {
        Button(L10n.isChinese ? "打开系统设置" : "Open System Settings") {
          model.errorMessage = nil
          model.openAccessibilitySettings()
        }
        Button(L10n.isChinese ? "以后再说" : "Not Now", role: .cancel) { model.errorMessage = nil }
      } else {
        Button(L10n.isChinese ? "好" : "OK", role: .cancel) { model.errorMessage = nil }
      }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  /// A narrow window collapses the sidebar on its own; once the user has
  /// chosen a mode, that choice wins until the window can no longer hold it.
  private func sidebarMode(forWindowWidth width: CGFloat) -> SidebarMode {
    guard width >= AppBreakpoints.sidebarRail else { return .rail }
    return pinnedSidebarMode ?? .expanded
  }

}

// MARK: - Shell

/// Sidebar plus detail column. Split out from `RootView` so it can read the
/// palette that `ThemedContainer` publishes.
private struct Shell: View {
  @Binding var selection: AppSection
  let mode: SidebarMode
  let canToggle: Bool
  let onToggle: () -> Void

  @Environment(\.palette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 0) {
      SidebarView(
        selection: $selection,
        mode: mode,
        canToggle: canToggle,
        onToggle: onToggle
      )
      .frame(width: mode == .expanded ? AppMetrics.sidebarWidth : AppMetrics.sidebarRailWidth)

      detail
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.canvas)
    .animation(AppMotion.state(reduceMotion: reduceMotion), value: mode == .expanded)
  }

  /// The top bar sits on the window frame with the sidebar, and the section
  /// sits in one inset panel below it. Frame and work are told apart by
  /// material rather than by a grid of hairlines, which is what keeps the
  /// window reading as one piece.
  private var detail: some View {
    VStack(spacing: 0) {
      NavBar(section: selection)
      WidthReader { _, _ in
        switch selection {
        case .setup: SetupGuideView {
          selection = .translator
        }
        case .translator: TranslatorView()
        case .learning: LearningView()
        case .history: HistoryView()
        case .vocabulary: VocabularyView()
        case .actions: ActionsView()
        }
      }
      .insetPanel(palette)
      .padding(.trailing, AppMetrics.panelInset)
      .padding(.bottom, AppMetrics.panelInset)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Sidebar

/// Navigation column: brand, grouped sections, and a provider card that both
/// reports which model answers requests and opens the place to change it.
private struct SidebarView: View {
  @Binding var selection: AppSection
  let mode: SidebarMode
  let canToggle: Bool
  let onToggle: () -> Void

  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @EnvironmentObject private var learning: LearningModel
  @Environment(\.palette) private var palette
  @Environment(\.openSettings) private var openSettings
  @State private var isHoveringProvider = false

  private var isCollapsed: Bool { mode == .rail }

  var body: some View {
    VStack(spacing: 0) {
      // The traffic lights are centred in a bar as tall as the top bar, so
      // the sidebar gives that row to them — and, expanded, to the collapse
      // toggle at its far end, where the lights already draw the eye. The
      // brand starts on the line where the content panel starts.
      HStack {
        Spacer(minLength: 0)
        if !isCollapsed, canToggle {
          IconButton(
            title: L10n.isChinese ? "收起边栏" : "Collapse the sidebar",
            symbol: "sidebar.leading",
            action: onToggle
          )
        }
      }
      .padding(.horizontal, AppSpacing.md)
      .frame(height: AppMetrics.navBarHeight)

      brand
        .padding(.horizontal, isCollapsed ? AppSpacing.sm : AppSpacing.md + 2)
        .padding(.bottom, AppSpacing.lg)

      ScrollView {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
          ForEach(AppSection.Group.allCases) { group in
            // Setup is shown here only on first launch; its persistent entry
            // lives in Settings rather than alongside everyday work.
            let sections = AppSection.allCases.filter { $0.group == group && $0 != .setup }
            if !sections.isEmpty {
              VStack(alignment: .leading, spacing: 2) {
                if !isCollapsed {
                  Eyebrow(text: group.title)
                    .padding(.horizontal, AppSpacing.sm + 2)
                    .padding(.bottom, AppSpacing.xs)
                }
                ForEach(sections) { section in
                  NavRow(
                    title: section.title,
                    symbol: section.symbol,
                    isSelected: selection == section,
                    trailing: badgeText(for: section),
                    collapsed: isCollapsed,
                    raised: true
                  ) {
                    selection = section
                  }
                }
              }
            }
          }
        }
        .padding(.horizontal, isCollapsed ? AppSpacing.sm : AppSpacing.sm + 2)
        .padding(.bottom, AppSpacing.md)
      }
      .scrollIndicators(.never)

      Spacer(minLength: 0)

      providerCard
        .padding(.horizontal, isCollapsed ? AppSpacing.sm : AppSpacing.sm + 2)
        .padding(.bottom, AppSpacing.sm + 2)
    }
    .frame(maxHeight: .infinity)
    .background(palette.canvas)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L10n.tr("sidebar.sections"))
  }

  // MARK: Brand

  // Collapsed used to rely on a double-tap on the logo to re-expand, with no
  // visible control -- a gesture nobody could discover, and not accessible or
  // keyboard-reachable either. The rail now keeps a real, visible toggle
  // button in the logo's place instead, matching the one shown when expanded.
  private var brand: some View {
    HStack(spacing: AppSpacing.sm) {
      if isCollapsed {
        if canToggle {
          IconButton(
            title: L10n.isChinese ? "展开边栏" : "Expand the sidebar",
            symbol: "sidebar.leading",
            action: onToggle
          )
        } else {
          AppLogo(size: 28)
        }
      } else {
        AppLogo(size: 28)

        VStack(alignment: .leading, spacing: 0) {
          Text("PhraseLens")
            .font(AppFont.heading)
            .foregroundStyle(palette.foreground)
          Text(L10n.isChinese ? "语言学习与翻译工作区" : "Language workspace")
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
        }
        .lineLimit(1)

        Spacer(minLength: 0)
      }
    }
    .frame(height: 34)
    .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("PhraseLens")
  }

  private func badgeText(for section: AppSection) -> String? {
    switch section {
    case .setup: nil
    case .history: model.history.isEmpty ? nil : "\(model.history.count)"
    case .vocabulary: model.vocabulary.isEmpty ? nil : "\(model.vocabulary.count)"
    case .actions: model.orderedActions.isEmpty ? nil : "\(model.orderedActions.count)"
    case .translator: nil
    case .learning: learning.dueCount > 0 ? "\(learning.dueCount)" : nil
    }
  }

  // MARK: Provider

  private var isProviderConfigured: Bool {
    model.selectedAction.map { settingsStore.isConfigured($0) } ?? false
  }

  @ViewBuilder
  private var providerCard: some View {
    let resolved = model.selectedAction.flatMap { try? settingsStore.resolve($0) }
    let provider = resolved?.1 ?? settingsStore.settings.provider

    Button {
      SettingsNavigation.show(.provider) { openSettings() }
    } label: {
      Group {
        if isCollapsed {
          StatusDot(color: isProviderConfigured ? palette.success : palette.warning)
            .frame(width: AppMetrics.controlHeight, height: AppMetrics.controlHeight)
        } else {
          HStack(spacing: AppSpacing.sm) {
            StatusDot(color: isProviderConfigured ? palette.success : palette.warning, isActive: isProviderConfigured)
            VStack(alignment: .leading, spacing: 1) {
              Text(resolved?.0.name ?? provider.provider.rawValue)
                .font(AppFont.captionMedium)
                .foregroundStyle(palette.foreground)
              Text(provider.model.isEmpty ? (L10n.isChinese ? "未选择模型" : "No model selected") : provider.model)
                .font(AppFont.caption)
                .foregroundStyle(palette.mutedForeground)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: AppSpacing.xs)
            Image(systemName: "gearshape")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(palette.faintForeground)
          }
          .padding(.horizontal, AppSpacing.sm + 2)
          .padding(.vertical, AppSpacing.sm)
        }
      }
      .frame(maxWidth: .infinity)
      .background(
        isHoveringProvider ? palette.surfaceElevated : palette.surface.opacity(0.55),
        in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
          .strokeBorder(palette.border, lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { isHoveringProvider = $0 }
    .animation(.easeOut(duration: 0.12), value: isHoveringProvider)
    .help(
      isProviderConfigured
        ? (L10n.isChinese
          ? "\(provider.provider.rawValue) · \(provider.model) — 点按前往“设置”修改"
          : "\(provider.provider.rawValue) · \(provider.model) — open Settings to change it")
        : (L10n.isChinese
          ? "前往“设置”完成 \(provider.provider.rawValue) 配置"
          : "Finish configuring \(provider.provider.rawValue) in Settings")
    )
    .accessibilityLabel(
      "Provider \(provider.provider.rawValue), model \(provider.model). Opens Settings."
    )
  }
}

// MARK: - Top bar

/// The window's own bar: where you are, and the commands that belong to the
/// whole window rather than to one pane.
///
/// The top strip doubles as the window's drag region, so the title block stays
/// free of controls.
private struct NavBar: View {
  let section: AppSection

  @EnvironmentObject private var model: AppModel
  @Environment(\.palette) private var palette
  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    HStack(spacing: AppSpacing.md) {
      VStack(alignment: .leading, spacing: 1) {
        Text(section.title)
          .font(AppFont.title)
          .titleTracking()
          .foregroundStyle(palette.foreground)
        if section.showsCaption, !layoutWidth.isCompact {
          Text(section.caption)
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
            .lineLimit(1)
        }
      }
      .fixedSize(horizontal: true, vertical: false)
      .layoutPriority(2)

      // Section controls share the bar with the title rather than opening a
      // band of their own below it: one strip of chrome between the window's
      // edge and the work, not two.
      NavBarControls(section: section)
        .layoutPriority(1)

      Spacer(minLength: AppSpacing.sm)

      if !model.shortcutErrors.isEmpty {
        // A warning with nowhere to go is only an alarm. The badge opens the
        // pane where the conflicting shortcut can be changed.
        Button {
          SettingsNavigation.show(.shortcuts) { openSettings() }
        } label: {
          Badge(
            text: L10n.isChinese ? "快捷键冲突" : "Shortcut conflict",
            variant: .warning,
            symbol: "exclamationmark.triangle.fill"
          )
        }
        .buttonStyle(.plain)
        .help(
          L10n.isChinese
            ? "部分全局快捷键注册失败，点按前往设置修改：\n" + model.shortcutErrors.joined(separator: "\n")
            : "Some global shortcuts could not be registered. Click to change them:\n"
              + model.shortcutErrors.joined(separator: "\n")
        )
        .accessibilityLabel(L10n.isChinese ? "快捷键冲突，前往设置" : "Shortcut conflict. Opens Settings.")
        .layoutPriority(2)
      }
    }
    // In the icon rail the traffic lights run past the rail's edge, so the
    // title keeps a full step of clearance from them.
    .padding(.horizontal, AppSpacing.lg)
    .frame(height: AppMetrics.navBarHeight)
    .frame(maxWidth: .infinity)
    .background(palette.canvas)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L10n.isChinese ? "\(section.title)工具栏" : "\(section.title) toolbar")
  }
}

/// The current section's own controls, in the window's top bar.
///
/// Split out of `NavBar` for the same reason as `NavBarActions`: the strip
/// tracks the model, the bar around it does not have to.
private struct NavBarControls: View {
  let section: AppSection

  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore

  var body: some View {
    switch section {
    case .translator:
      ActionTabBar(
        actions: model.visibleActions,
        selection: actionSelection,
        defaultActionID: settingsStore.settings.defaultActionID,
        setDefault: { settingsStore.setDefaultAction($0) }
      )
    case .learning:
      LearningTabBar()
    case .setup, .history, .vocabulary, .actions:
      EmptyView()
    }
  }

  private var actionSelection: Binding<UUID> {
    Binding(
      get: { model.selectedActionID },
      set: { id in
        model.selectedActionID = id
        if settingsStore.settings.autoTranslate, !model.inputText.isEmpty {
          model.translate()
        }
      }
    )
  }
}
