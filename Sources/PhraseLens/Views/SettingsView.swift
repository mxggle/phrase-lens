import AppKit
import SwiftUI

/// Settings panes, in the order the sidebar lists them.
enum SettingsPane: String, CaseIterable, Identifiable {
  case general
  case provider
  case shortcuts
  case speech
  case learning
  case network
  case setup
  case about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: L10n.isChinese ? "常规" : "General"
    case .provider: L10n.isChinese ? "AI 连接" : "AI Connections"
    case .shortcuts: L10n.isChinese ? "快捷键" : "Shortcuts"
    case .speech: L10n.isChinese ? "朗读与写作" : "Speech & Writing"
    case .learning: L10n.isChinese ? "学习助手" : "Study"
    case .network: L10n.isChinese ? "网络代理" : "Network"
    case .setup: L10n.isChinese ? "新手引导" : "Getting Started"
    case .about: L10n.isChinese ? "关于" : "About"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .provider: "cpu"
    case .shortcuts: "keyboard"
    case .speech: "speaker.wave.2"
    case .learning: "graduationcap"
    case .network: "network"
    case .setup: "checklist"
    case .about: "info.circle"
    }
  }

  var caption: String {
    switch self {
    case .general: L10n.isChinese ? "界面语言、翻译行为与窗口外观" : "Languages, translation behavior, and the window"
    case .provider: L10n.isChinese ? "应答模型及 API 密钥配置" : "Which model answers, and the credential it uses"
    case .shortcuts: L10n.isChinese ? "全局快捷键与系统权限" : "Global keys and the permission they need"
    case .speech: L10n.isChinese ? "语音播放引擎、朗读参数与写作" : "Voice playback and writing"
    case .learning: L10n.isChinese ? "学习记录、后台分析与复习" : "The study record, background analysis, and review"
    case .network: L10n.isChinese ? "代理服务器与直连白名单" : "Proxy configuration"
    case .setup: L10n.isChinese ? "连接服务商、启用快捷键并体验首次翻译" : "Connect a provider, enable shortcuts, and try a translation"
    case .about: L10n.isChinese ? "版本、软件更新与开源许可协议" : "Version, software updates, and licensing"
    }
  }
}

@MainActor
enum SettingsNavigation {
  static var requestedPane: SettingsPane?
  static let didRequestPane = Notification.Name("PhraseLensSettingsPaneRequested")

  static func show(_ pane: SettingsPane, openSettings: () -> Void) {
    requestedPane = pane
    openSettings()
    NotificationCenter.default.post(name: didRequestPane, object: nil)
  }
}

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @EnvironmentObject private var modelCatalog: ModelCatalogStore
  @State private var pane: SettingsPane = .general

  var body: some View {
    ThemedContainer {
      SettingsShell(pane: $pane)
    }
    // The width class is measured on the content column, so the 200pt sidebar
    // and its hairline come off the top: a row only reaches AppBreakpoints
    // .regular from 841pt of window. Anything narrower stacks every label above
    // its control, which is the fallback layout, not the intended one.
    .frame(minWidth: 880, idealWidth: 940, minHeight: 520, idealHeight: 620)
    .environmentObject(model)
    .environmentObject(settingsStore)
    .environmentObject(modelCatalog)
    .environment(\.locale, settingsStore.resolvedLocale)
    .preferredColorScheme(settingsStore.settings.theme.preferredColorScheme)
    // macOS may restore the SwiftUI Settings scene on relaunch. Settings is
    // only useful when the user asked for it, so keep its window out of
    // window restoration entirely.
    .background(SettingsWindowConfig().frame(width: 0, height: 0))
    .onAppear { applyRequestedPane() }
    .onReceive(NotificationCenter.default.publisher(for: SettingsNavigation.didRequestPane)) { _ in
      applyRequestedPane()
    }
  }

  private func applyRequestedPane() {
    guard let requested = SettingsNavigation.requestedPane else { return }
    pane = requested
    SettingsNavigation.requestedPane = nil
  }
}

/// Reaches the window hosting the Settings scene to disable restoration.
private struct SettingsWindowConfig: NSViewRepresentable {
  final class Coordinator {
    var trafficLights: TrafficLightPositioner?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async { apply(to: view.window, coordinator: context.coordinator) }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    DispatchQueue.main.async { apply(to: view.window, coordinator: context.coordinator) }
  }

  private func apply(to window: NSWindow?, coordinator: Coordinator) {
    guard let window else { return }
    defer {
      if coordinator.trafficLights?.window !== window {
        coordinator.trafficLights = TrafficLightPositioner(
          window: window,
          barHeight: AppMetrics.navBarHeight
        )
      } else {
        coordinator.trafficLights?.apply()
      }
    }
    window.isRestorable = false
    // The same frame as the main window: no title bar of its own, so the
    // sidebar's frame tone reaches the top edge and the traffic lights sit on
    // it. The sidebar reserves their space.
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.styleMask.insert(.fullSizeContentView)
  }
}

/// Sidebar plus a scrolling pane. Split from `SettingsView` so it can read the
/// palette published by `ThemedContainer`.
private struct SettingsShell: View {
  @Binding var pane: SettingsPane

  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: 200)
      VStack(spacing: 0) {
        header
        // The panel starts below the title bar rather than under it: a
        // scroll view under the bar gets the system's scroll-edge band drawn
        // across its first lines, and the bar's height is the window's drag
        // region besides.
        content
          .insetPanel(palette)
          .padding(.trailing, AppMetrics.panelInset)
          .padding(.bottom, AppMetrics.panelInset)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.canvas)
    .ignoresSafeArea(.container, edges: .top)
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 2) {
      // The traffic lights' row, as tall as the top bar beside it.
      Color.clear.frame(height: AppMetrics.navBarHeight)

      Text(L10n.isChinese ? "设置" : "Settings")
        .font(AppFont.title)
        .titleTracking()
        .foregroundStyle(palette.foreground)
        .frame(height: 34)
        .padding(.horizontal, AppSpacing.sm + 2)
        .padding(.bottom, AppSpacing.sm)

      ForEach(SettingsPane.allCases) { item in
        NavRow(
          title: item.title,
          symbol: item.symbol,
          isSelected: pane == item,
          raised: true
        ) {
          pane = item
        }
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, AppSpacing.sm)
    .padding(.bottom, AppSpacing.sm)
    .frame(maxHeight: .infinity)
    .background(palette.canvas)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L10n.isChinese ? "设置选项" : "Settings sections")
  }

  /// The pane's name in the top bar, the way the main window names its
  /// section: on the frame, beside the traffic lights, out of the scroller.
  private var header: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(pane.title)
        .font(AppFont.title)
        .titleTracking()
        .foregroundStyle(palette.foreground)
      Text(pane.caption)
        .font(AppFont.caption)
        .foregroundStyle(palette.mutedForeground)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, AppSpacing.lg)
    .frame(height: AppMetrics.navBarHeight)
  }

  private var content: some View {
    VStack(spacing: 0) {
      WidthReader { _, _ in
        if pane == .setup {
          ScrollView {
            SetupGuideView {
              pane = .general
              model.openTranslator()
            }
            .frame(minHeight: 540)
          }
        } else {
          ScrollView {
            Group {
              switch pane {
              case .general: GeneralSettingsPane()
              case .provider: ProviderSettingsPane()
              case .shortcuts: ShortcutSettingsPane()
              case .speech: SpeechWritingSettingsPane()
              case .learning: LearningSettingsPane()
              case .network: NetworkSettingsPane()
              case .about: AboutSettingsPane()
              case .setup: EmptyView()
              }
            }
            .padding(.horizontal, AppSpacing.xxl)
            .padding(.top, AppSpacing.xl)
            .padding(.bottom, AppSpacing.xxl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlayScrollers()
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - General

private struct GeneralSettingsPane: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @Environment(\.palette) private var palette

  private var selectableLanguages: [LanguageCode] {
    LanguageCode.allCases.filter { $0 != .auto }
  }

  var body: some View {
    PaneStack {
      SettingsCard(L10n.isChinese ? "语言偏好" : "Languages") {
        SettingsRow(
          L10n.isChinese ? "界面语言" : "App language",
          detail: L10n.isChinese ? "切换 PhraseLens 的显示语言，即时生效。" : "Choose the interface display language."
        ) {
          AppSelect(
            title: L10n.isChinese ? "界面语言" : "App language",
            selection: $settingsStore.settings.appLanguage,
            options: AppLanguage.allCases,
            label: { $0.displayName }
          )
        }
        Hairline()
        SettingsRow(
          L10n.isChinese ? "默认目标语言" : "Default target",
          detail: L10n.isChinese ? "新翻译默认转换的目标语言。" : "The language new translations aim for."
        ) {
          AppSelect(
            title: L10n.isChinese ? "默认目标语言" : "Default target language",
            selection: $settingsStore.settings.targetLanguage,
            options: selectableLanguages,
            label: { $0.displayName }
          )
        }
        Hairline()
        SettingsBlock {
          VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(L10n.isChinese ? "翻译快捷选择语言" : "Languages in the translator")
              .font(AppFont.body)
            Text(
              L10n.isChinese
                ? "至少保留一种可用语言。默认包含中文、日语与英语。"
                : "At least one language stays enabled. Chinese, Japanese, and English are the defaults."
            )
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            favoriteLanguageGrid
              .padding(.top, AppSpacing.xxs)
          }
        }
      }

      SettingsCard(L10n.isChinese ? "翻译与交互" : "Translation") {
        SettingsRow(L10n.isChinese ? "默认动作" : "Default action") {
          AppSelect(
            title: L10n.isChinese ? "默认动作" : "Default action",
            selection: Binding(
              get: { settingsStore.settings.defaultActionID },
              set: { model.setDefaultAction($0) }
            ),
            options: model.visibleActions.map(\.id),
            label: { id in
              model.visibleActions.first { $0.id == id }?.name ?? (L10n.isChinese ? "默认动作" : "Default action")
            }
          )
        }
        Hairline()
        switchRow(
          L10n.isChinese ? "自动开始翻译" : "Translate automatically",
          detail: L10n.isChinese
            ? "划选文字或完成截屏后立即自动执行翻译。"
            : "Runs as soon as text arrives from a selection or from screen capture.",
          isOn: $settingsStore.settings.autoTranslate
        )
        Hairline()
        switchRow(
          L10n.isChinese ? "在划选浮窗中呈现结果" : "Show selections in a pop-up",
          detail: L10n.isChinese
            ? "在光标附近的悬浮面板中呈现译文，而不是激活主窗口。"
            : "Translates selected text in a floating panel instead of the main window.",
          isOn: $settingsStore.settings.useCompactSelectionPreview
        )
        Hairline()
        SettingsRow(
          L10n.isChinese ? "浮窗弹出位置" : "Pop-up position",
          detail: L10n.isChinese
            ? (settingsStore.settings.selectionPanelPlacement == .nearPointer
              ? "在当前屏幕的鼠标光标旁弹出。"
              : "记忆上次拖动的位置，后续弹窗均在固定位置打开。")
            : (settingsStore.settings.selectionPanelPlacement == .nearPointer
              ? "Opens beside the pointer on the active display."
              : "Drag the pop-up once; future pop-ups return to that position.")
        ) {
          AppSelect(
            title: L10n.isChinese ? "浮窗弹出位置" : "Pop-up position",
            selection: $settingsStore.settings.selectionPanelPlacement,
            options: SelectionPanelPlacementMode.allCases,
            label: { mode in
              switch mode {
              case .nearPointer: L10n.isChinese ? "跟随光标" : mode.displayName
              case .fixed: L10n.isChinese ? "固定位置" : mode.displayName
              }
            }
          )
          .disabled(!settingsStore.settings.useCompactSelectionPreview)
        }
        Hairline()
        switchRow(
          L10n.isChinese ? "保持浮窗常驻显示（固定）" : "Keep the pop-up open",
          detail: L10n.isChinese
            ? "点击其他应用窗口时不自动隐藏，按 Escape 键或点按关闭按钮关闭。亦可通过浮窗标题栏的图钉图标快捷切换。"
            : "Stays on screen when you click elsewhere; close it with Escape or the close button. "
              + "The pin in the pop-up's title bar toggles this too.",
          isOn: $settingsStore.settings.selectionPanelPinned
        )
        Hairline()
        switchRow(
          L10n.isChinese ? "剪贴板取词兜底" : "Copy as a fallback",
          detail: L10n.isChinese
            ? "当遇到无法直接读取辅助功能文本的网页或文档时，自动通过模拟拷贝读取。"
            : "Uses the clipboard for web and document selections that cannot be read directly.",
          isOn: $settingsStore.settings.useClipboardFallback
        )
      }

      SettingsCard(L10n.isChinese ? "窗口与外观" : "Window") {
        SettingsRow(L10n.isChinese ? "外观主题" : "Appearance") {
          AppSelect(
            title: L10n.isChinese ? "外观主题" : "Appearance",
            selection: $settingsStore.settings.theme,
            options: AppTheme.allCases,
            label: { theme in
              switch theme {
              case .system: L10n.isChinese ? "跟随系统" : theme.title
              case .light: L10n.isChinese ? "浅色" : theme.title
              case .dark: L10n.isChinese ? "深色" : theme.title
              }
            }
          )
        }
        Hairline()
        switchRow(
          L10n.isChinese ? "主窗口置顶" : "Always on top",
          isOn: $settingsStore.settings.alwaysOnTop
        )
        Hairline()
        switchRow(
          L10n.isChinese ? "失焦自动隐藏" : "Hide when inactive",
          detail: L10n.isChinese
            ? "切换到其他应用程序时自动收起主窗口。"
            : "Puts the window away when you switch to another app.",
          isOn: $settingsStore.settings.autoHideWhenInactive
        )
        Hairline()
        switchRow(
          L10n.isChinese ? "在程序坞 (Dock) 中显示图标" : "Show Dock icon",
          isOn: $settingsStore.settings.showDockIcon
        )
        Hairline()
        switchRow(
          L10n.isChinese ? "登录时自动启动" : "Launch at login",
          isOn: Binding(
            get: { settingsStore.settings.launchAtLogin },
            set: { model.applyLaunchAtLogin($0) }
          )
        )
        Hairline()
        SettingsRow(
          L10n.isChinese ? "文本字体大小" : "Text size",
          detail: L10n.isChinese
            ? "同时应用于原文输入框与译文呈现区。"
            : "Applies to the source text and the result."
        ) {
          HStack(spacing: AppSpacing.sm) {
            Slider(value: $settingsStore.settings.fontSize, in: 12...24, step: 1)
              .frame(width: 200)
              .tint(palette.foreground)
              .accessibilityLabel(L10n.isChinese ? "文本字体大小" : "Text size")
            Text("\(Int(settingsStore.settings.fontSize)) pt")
              .font(AppFont.caption)
              .monospacedDigit()
              .foregroundStyle(palette.mutedForeground)
              .frame(width: 34, alignment: .trailing)
          }
        }
      }
    }
  }

  private func switchRow(
    _ title: String,
    detail: String? = nil,
    isOn: Binding<Bool>
  ) -> some View {
    SettingsRow(title, detail: detail) {
      Toggle("", isOn: isOn)
        .toggleStyle(AppSwitchStyle())
        .labelsHidden()
        .accessibilityLabel(title)
    }
  }

  private var favoriteLanguageGrid: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 130), spacing: AppSpacing.xs + 2)],
      alignment: .leading,
      spacing: AppSpacing.xs + 2
    ) {
      ForEach(selectableLanguages) { language in
        Toggle(
          language.displayName,
          isOn: Binding(
            get: { settingsStore.settings.favoriteLanguages.contains(language) },
            set: { enabled in setFavorite(language, enabled: enabled) }
          )
        )
        .toggleStyle(ChipToggleStyle())
      }
    }
  }

  private func setFavorite(_ language: LanguageCode, enabled: Bool) {
    if enabled {
      if !settingsStore.settings.favoriteLanguages.contains(language) {
        settingsStore.settings.favoriteLanguages.append(language)
      }
    } else if settingsStore.settings.favoriteLanguages.count > 1 {
      settingsStore.settings.favoriteLanguages.removeAll { $0 == language }
      if settingsStore.settings.targetLanguage == language {
        settingsStore.settings.targetLanguage = settingsStore.settings.favoriteLanguages[0]
      }
    }
  }
}

// MARK: - Provider

private struct ProviderSettingsPane: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @EnvironmentObject private var modelCatalog: ModelCatalogStore
  @Environment(\.palette) private var palette

  @State private var connectionError: String?
  @State private var apiKeyDraft = ""
  @State private var isConfirmingKeyRemoval = false
  @State private var endpointStatus: (text: String, isValid: Bool)?

  private var isOAuthMode: Bool {
    settingsStore.settings.provider.provider.supportsOAuth
      && settingsStore.settings.provider.authMode == .oauthCodex
  }

  private var editingConnectionName: String {
    let name = settingsStore.settings.connections
      .first { $0.id == settingsStore.editingConnectionID }?.name ?? ""
    let fallback = L10n.isChinese ? "连接设置" : "Connection"
    return name.trimmingCharacters(in: .whitespaces).isEmpty ? fallback : name
  }

  /// One saved connection. Selecting it opens it in the card below; the
  /// default is marked rather than selected, because choosing what to edit
  /// and choosing what answers are separate decisions.
  private func connectionRow(_ connection: AIConnection) -> some View {
    let isEditing = connection.id == settingsStore.editingConnectionID
    let isDefault = connection.id == settingsStore.settings.defaultConnectionID
    return Button {
      guard !isEditing else { return }
      persistAPIKeyDraft()
      connectionError = nil
      settingsStore.selectConnection(connection.id)
    } label: {
      HStack(spacing: AppSpacing.md) {
        Image(systemName: "point.3.connected.trianglepath.dotted")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(isEditing ? palette.foreground : palette.mutedForeground)
          .frame(width: 28, height: 28)
          .background(palette.muted, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        VStack(alignment: .leading, spacing: 1) {
          Text(connection.name.isEmpty ? connection.configuration.provider.rawValue : connection.name)
            .font(AppFont.bodyMedium)
            .foregroundStyle(palette.foreground)
            .lineLimit(1)
          Text("\(connection.configuration.provider.rawValue) · \(connection.configuration.model.isEmpty ? L10n.tr("sidebar.no_model") : connection.configuration.model)")
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer(minLength: AppSpacing.sm)
        if isDefault {
          Badge(text: L10n.isChinese ? "默认" : "Default", variant: .success)
        }
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(palette.accent)
          .opacity(isEditing ? 1 : 0)
      }
      .padding(.horizontal, AppSpacing.md + 2)
      .padding(.vertical, AppSpacing.sm + 1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(isEditing ? palette.muted.opacity(0.6) : .clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(connection.name)
    .accessibilityValue(isDefault ? (L10n.isChinese ? "全局默认" : "Global default") : "")
    .accessibilityAddTraits(isEditing ? [.isSelected] : [])
  }

  var body: some View {
    PaneStack {
      SettingsCard(
        L10n.isChinese ? "已保存的连接" : "Saved Connections",
        caption: L10n.isChinese
          ? "可以保存多组连接。动作默认使用全局默认连接，也可以在“动作配置”中单独指定。"
          : "Save as many connections as you need. Actions use the global default unless you choose one in Actions."
      ) {
        ForEach(Array(settingsStore.settings.connections.enumerated()), id: \.element.id) { index, connection in
          if index > 0 { Hairline() }
          connectionRow(connection)
        }
        Hairline()
        SettingsBlock {
          HStack(spacing: AppSpacing.sm) {
            AppMenuButton(title: L10n.isChinese ? "添加连接" : "Add Connection", symbol: "plus") {
              ForEach(ProviderKind.allCases) { provider in
                Button(provider.rawValue) {
                  persistAPIKeyDraft()
                  settingsStore.addConnection(provider: provider)
                }
              }
            }
            Spacer(minLength: 0)
          }
        }
        if let connectionError {
          SettingsBlock { InlineNote(text: connectionError, kind: .error) }
        }
      }

      SettingsCard(
        editingConnectionName,
        caption: L10n.isChinese ? "以下设置只作用于这一组连接。" : "These settings apply to this connection only."
      ) {
        if let id = settingsStore.editingConnectionID,
          let index = settingsStore.settings.connections.firstIndex(where: { $0.id == id }) {
          SettingsRow(L10n.isChinese ? "连接名称" : "Name") {
            AppTextField(
              placeholder: L10n.isChinese ? "连接名称" : "Connection name",
              text: $settingsStore.settings.connections[index].name,
              size: .sm
            )
            .frame(maxWidth: 260)
          }
          Hairline()
          SettingsRow(
            L10n.isChinese ? "全局默认" : "Global default",
            detail: settingsStore.settings.defaultConnectionID == id
              ? (L10n.isChinese ? "未单独指定连接的动作都会使用它。" : "Every action without its own connection uses this one.")
              : (L10n.isChinese ? "设为默认后，未单独指定连接的动作将改用它。" : "Actions without their own connection switch to this one.")
          ) {
            HStack(spacing: AppSpacing.xs) {
              if settingsStore.settings.defaultConnectionID == id {
                Badge(text: L10n.isChinese ? "当前默认" : "Default", variant: .success, symbol: "checkmark")
              } else {
                Button(L10n.isChinese ? "设为全局默认" : "Make Default") { settingsStore.makeDefault(id) }
                  .appButton(.outline, size: .sm)
              }
              Button(L10n.isChinese ? "删除" : "Delete") {
                connectionError = settingsStore.deleteConnection(id, actions: model.allActions)
              }
              .appButton(.destructiveGhost, size: .sm)
            }
          }
          Hairline()
        }

        SettingsRow(L10n.isChinese ? "服务商" : "Provider") {
          Text(settingsStore.settings.provider.provider.rawValue)
            .font(AppFont.bodyMedium)
            .foregroundStyle(palette.secondaryForeground)
        }

        if settingsStore.settings.provider.provider.supportsOAuth {
          Hairline()
          SettingsRow(
            L10n.isChinese ? "认证方式" : "Authentication mode",
            detail: L10n.isChinese
              ? "支持使用开放平台 API 密钥或登录 ChatGPT 账号。"
              : "Choose between a Platform API key or your ChatGPT account."
          ) {
            AppSelect(
              title: L10n.isChinese ? "认证方式" : "Authentication mode",
              selection: Binding(
                get: { settingsStore.settings.provider.authMode },
                set: { setAuthMode($0) }
              ),
              options: AuthenticationMode.allCases,
              label: { $0.rawValue }
            )
          }
        }

        Hairline()
        SettingsRow(
          L10n.isChinese ? "模型名称" : "Model name",
          detail: L10n.tr("settings.provider.model_detail"),
          stacksControl: true
        ) {
          VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
              SearchableSelect(
                title: L10n.isChinese ? "模型名称" : "Model name",
                selection: $settingsStore.settings.provider.model,
                options: catalogModels,
                placeholder: L10n.tr("sidebar.no_model"),
                searchPrompt: L10n.tr("settings.provider.search_prompt"),
                emptyMessage: emptyCatalogMessage,
                customValueLabel: { L10n.tr("settings.provider.use_custom_model", $0) }
              )
              Button {
                refreshCatalog()
              } label: {
                if isFetchingCatalog {
                  Spinner(size: 12)
                } else {
                  AdaptiveLabel(title: L10n.tr("common.refresh"), symbol: "arrow.clockwise")
                }
              }
              .appButton(.outline, size: .sm)
              .disabled(isFetchingCatalog || !canFetchCatalog)
              .help(refreshHelp)
              .accessibilityLabel(L10n.tr("settings.provider.refresh_models"))
            }
            if let error = modelCatalog.error(for: settingsStore.settings.provider) {
              InlineNote(text: error, kind: .error)
            } else {
              Text(catalogStatus)
                .font(AppFont.caption)
                .foregroundStyle(palette.mutedForeground)
            }
          }
        }

        if !isOAuthMode {
          Hairline()
          SettingsRow(L10n.isChinese ? "接口地址 (Endpoint)" : "Endpoint URL", stacksControl: true) {
            AppTextField(
              placeholder: "https://…",
              text: $settingsStore.settings.provider.endpoint,
              size: .sm,
              monospaced: true
            )
          }
        }

        if !isOAuthMode && settingsStore.settings.provider.supportsReasoningControl {
          Hairline()
          SettingsRow(
            L10n.isChinese ? "深度思考 / 推理模式" : "Enable reasoning",
            detail: L10n.tr("settings.provider.reasoning_detail")
          ) {
            Toggle("", isOn: $settingsStore.settings.provider.reasoningEnabled)
              .toggleStyle(AppSwitchStyle())
              .labelsHidden()
              .accessibilityLabel(L10n.isChinese ? "深度思考 / 推理模式" : "Enable reasoning")
          }
        }

        if !isOAuthMode && settingsStore.settings.provider.provider == .azure {
          Hairline()
          SettingsRow(L10n.tr("settings.provider.api_version"), stacksControl: true) {
            AppTextField(
                placeholder: "2024-10-21",
              text: $settingsStore.settings.provider.apiVersion,
              size: .sm,
              monospaced: true
            )
          }
        }

        if !isOAuthMode && settingsStore.settings.provider.provider == .openAI {
          Hairline()
          SettingsRow(L10n.tr("settings.provider.organization"), detail: L10n.isChinese ? "可选。" : "Optional.", stacksControl: true) {
            AppTextField(
              placeholder: "org-…",
              text: $settingsStore.settings.provider.organization,
              size: .sm,
              monospaced: true
            )
          }
        }

        if !isOAuthMode && settingsStore.settings.provider.provider == .anthropic {
          Hairline()
          SettingsRow(L10n.isChinese ? "深度思考 / 推理模式" : "Extended thinking") {
            Toggle("", isOn: $settingsStore.settings.provider.extendedThinking)
              .toggleStyle(AppSwitchStyle())
              .labelsHidden()
              .accessibilityLabel(L10n.isChinese ? "深度思考 / 推理模式" : "Extended thinking")
          }
        }
      }

      if isOAuthMode {
        SettingsCard(
          L10n.tr("settings.provider.chatgpt_account"),
          caption: L10n.tr("settings.provider.chatgpt_caption")
        ) {
          SettingsBlock {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
              if let creds = settingsStore.oauthCredentials, !creds.accessToken.isEmpty {
                HStack(spacing: AppSpacing.sm) {
                  Badge(
                    text: creds.isExpired ? L10n.tr("settings.provider.expired") : L10n.tr("settings.provider.signed_in"),
                    variant: creds.isExpired ? .warning : .success,
                    symbol: creds.isExpired ? "exclamationmark.triangle" : "checkmark.circle"
                  )
                  if let email = creds.email, !email.isEmpty {
                    Text(L10n.isChinese ? "已登录账号：\(email)" : "Signed in as \(email)")
                      .font(AppFont.body)
                      .foregroundStyle(palette.foreground)
                  }
                  Spacer()
                  Button(L10n.isChinese ? "退出登录" : "Sign Out") {
                    settingsStore.logoutOAuth()
                  }
                  .appButton(.destructiveGhost, size: .sm)
                }

                Text(
                  L10n.isChinese
                    ? "令牌有效期至 \(creds.expiresAt.formatted(date: .abbreviated, time: .shortened))（需要时自动刷新）"
                    : "Token active until \(creds.expiresAt.formatted(date: .abbreviated, time: .shortened)) (auto-refreshed as needed)"
                )
                .font(AppFont.caption)
                .foregroundStyle(palette.mutedForeground)
              } else {
                HStack(spacing: AppSpacing.sm) {
                  if settingsStore.isAuthenticatingOAuth {
                    Spinner(size: 14)
                    Text(L10n.tr("settings.provider.waiting_browser"))
                      .font(AppFont.caption)
                      .foregroundStyle(palette.mutedForeground)
                    Spacer()
                    Button(L10n.tr("common.cancel")) {
                      settingsStore.cancelOAuthLogin()
                    }
                    .appButton(.outline, size: .sm)
                  } else {
                    Button(L10n.isChinese ? "登录 ChatGPT" : "Sign in with ChatGPT") {
                      settingsStore.startOAuthLogin()
                    }
                    .appButton(.primary, size: .sm)
                  }
                }
              }

              legacyKeychainImportRow

              if let error = settingsStore.oauthError {
                InlineNote(text: error, kind: .error)
              }
            }
          }
        }
      } else if settingsStore.settings.provider.provider.usesAPIKey {
        SettingsCard(
          L10n.tr("settings.provider.credential"),
          caption: L10n.tr("settings.provider.credential_caption")
        ) {
          SettingsBlock {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
              HStack(spacing: AppSpacing.sm) {
                AppTextField(
                  placeholder: L10n.isChinese ? "输入 API 密钥" : "Enter API key",
                  text: $apiKeyDraft,
                  isSecure: true,
                  size: .sm,
                  onSubmit: { saveAPIKeyIfChanged() }
                )

                Button(L10n.tr("settings.provider.save_key")) {
                  saveAPIKeyIfChanged()
                }
                .appButton(.primary, size: .sm)
                .disabled(!hasUnsavedAPIKey)

                if !settingsStore.apiKey.isEmpty {
                  Button(L10n.isChinese ? "清除密钥" : "Remove") { isConfirmingKeyRemoval = true }
                    .appButton(.destructiveGhost, size: .sm)
                  .help(L10n.isChinese ? "删除此服务商已保存的密钥" : "Delete this provider's saved key")
                }
              }

              HStack(spacing: AppSpacing.sm) {
                Badge(
                  text: credentialBadge,
                  variant: settingsStore.apiKey.isEmpty ? .warning : .success,
                  symbol: settingsStore.apiKey.isEmpty ? "exclamationmark" : "checkmark"
                )
                if hasUnsavedAPIKey {
                  Badge(text: L10n.isChinese ? "未保存" : "Unsaved", variant: .warning, symbol: "pencil")
                }
                Text(credentialStatus)
                  .font(AppFont.caption)
                  .foregroundStyle(palette.mutedForeground)
              }

              if settingsStore.settings.provider.provider == .openAI
                || settingsStore.settings.provider.provider == .chatGPT {
                Link(L10n.tr("settings.provider.create_openai_key"), destination: URL(string: "https://platform.openai.com/api-keys")!)
                  .font(AppFont.captionMedium)
              } else {
                Text(L10n.tr("settings.provider.create_other_key"))
                  .font(AppFont.caption)
                  .foregroundStyle(palette.mutedForeground)
              }

              legacyKeychainImportRow

              if let error = settingsStore.credentialError {
                InlineNote(text: error, kind: .error)
              }
            }
          }
        }
      }

      if !isOAuthMode {
        SettingsCard(L10n.tr("settings.provider.endpoint_safety")) {
          SettingsBlock {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
              HStack(spacing: AppSpacing.sm) {
                Button(L10n.isChinese ? "检查地址" : "Check address") { validateEndpoint() }
                  .appButton(.outline, size: .sm)
                if let endpointStatus {
                  InlineNote(
                    text: endpointStatus.text,
                    kind: endpointStatus.isValid ? .success : .error
                  )
                }
              }
              InlineNote(
                text: L10n.tr("settings.provider.https_note"),
                kind: .info
              )
            }
          }
        }
      }
    }
    .onAppear {
      apiKeyDraft = settingsStore.apiKey
      refreshCatalogIfStale()
    }
    .onChange(of: settingsStore.editingConnectionID) { _, _ in
      apiKeyDraft = settingsStore.apiKey
      endpointStatus = nil
      refreshCatalogIfStale()
    }
    .onChange(of: settingsStore.apiKey) { _, value in
      apiKeyDraft = value
    }
    .onChange(of: settingsStore.oauthCredentials) { oldValue, newValue in
      guard isOAuthMode else { return }
      let oldAccount = oldValue?.accountId ?? oldValue?.email ?? oldValue?.accessToken
      let newAccount = newValue?.accountId ?? newValue?.email ?? newValue?.accessToken
      guard oldAccount != newAccount else { return }
      modelCatalog.invalidate(for: settingsStore.settings.provider)
      if newValue != nil { refreshCatalogIfStale() }
    }
    // A typed key is the one setting that does not persist on its own, so
    // leaving the pane must not be the same as discarding it.
    .onDisappear { persistAPIKeyDraft() }
    .confirmationDialog(
      L10n.tr("settings.provider.remove_key_title", settingsStore.settings.provider.provider.rawValue),
      isPresented: $isConfirmingKeyRemoval,
      titleVisibility: .visible
    ) {
      Button(L10n.isChinese ? "清除密钥" : "Remove Key", role: .destructive) {
        apiKeyDraft = ""
        settingsStore.saveAPIKey("")
        modelCatalog.invalidate(for: settingsStore.settings.provider)
      }
      Button(L10n.tr("common.cancel"), role: .cancel) {}
    } message: {
      Text(L10n.tr("settings.provider.remove_key_message"))
    }
  }

  private var hasUnsavedAPIKey: Bool {
    apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines) != settingsStore.apiKey
  }

  /// Files the typed key under whichever provider is selected right now, which
  /// is why a provider switch has to call this before it switches.
  @discardableResult
  private func persistAPIKeyDraft() -> Bool {
    guard hasUnsavedAPIKey else { return false }
    settingsStore.saveAPIKey(apiKeyDraft)
    modelCatalog.invalidate(for: settingsStore.settings.provider)
    return true
  }

  private func saveAPIKeyIfChanged() {
    guard persistAPIKeyDraft() else { return }
    // A provider is only usable once it has both a key and a model, so the
    // catalog is worth loading the moment the key lands rather than after one
    // more click.
    refreshCatalogIfStale()
  }

  // MARK: Model catalog

  private var isFetchingCatalog: Bool {
    modelCatalog.isFetching(settingsStore.settings.provider)
  }

  /// Azure has no catalog endpoint at all — it serves deployment names the
  /// portal defines — and every other provider needs a credential first.
  private var canFetchCatalog: Bool {
    guard settingsStore.settings.provider.provider != .azure else { return false }
    return hasCredential
  }

  private var hasCredential: Bool {
    if isOAuthMode {
      return !(settingsStore.oauthCredentials?.accessToken.isEmpty ?? true)
    }
    return !settingsStore.settings.provider.provider.usesAPIKey || !settingsStore.apiKey.isEmpty
  }

  private var catalogModels: [String] {
    var list = modelCatalog.models(for: settingsStore.settings.provider)
    // A fetched Codex catalog is the whole truth about what a ChatGPT
    // subscription may use, so the built-in names only stand in until one
    // arrives. Merging the two instead offered models the backend rejects.
    if isOAuthMode, list.isEmpty {
      list = CodexBackend.fallbackModels
    }
    let current = settingsStore.settings.provider.model
    if !current.isEmpty, !list.contains(current) {
      list.insert(current, at: 0)
    }
    return list
  }

  private var emptyCatalogMessage: String {
    if settingsStore.settings.provider.provider == .azure {
      return L10n.isChinese ? "Azure 提供的是部署实例而非模型目录。请输入在 Azure 门户中配置的部署名称。" : "Azure serves deployments, not a catalog. Type the deployment name configured in the Azure portal."
    }
    if !hasCredential {
      return L10n.isChinese ? "请先保存密钥，再刷新以载入此服务商的模型。" : "Save a credential first, then refresh to load this provider's models."
    }
    return L10n.isChinese ? "刷新以载入此服务商的模型，或直接输入模型 ID。" : "Refresh to load this provider's models, or type a model id."
  }

  private var catalogStatus: String {
    if isFetchingCatalog { return L10n.tr("settings.provider.loading_catalog") }
    if settingsStore.settings.provider.provider == .azure {
      return L10n.isChinese ? "Azure 使用部署名称；请输入在 Azure 门户中配置的名称。" : "Azure uses deployment names; type the one configured in the Azure portal."
    }
    guard let snapshot = modelCatalog.snapshot(for: settingsStore.settings.provider) else {
      return hasCredential
        ? (L10n.isChinese ? "尚未载入模型目录。" : "No catalog loaded yet.")
        : (L10n.isChinese ? "请保存密钥以载入此服务商的模型目录。" : "Save a credential to load this provider's model catalog.")
    }
    let updated = snapshot.fetchedAt.formatted(.relative(presentation: .named))
    return L10n.isChinese ? "\(snapshot.models.count) 个模型 · 更新于 \(updated)" : "\(snapshot.models.count) models · updated \(updated)"
  }

  private var refreshHelp: String {
    if !canFetchCatalog { return emptyCatalogMessage }
    return isOAuthMode
      ? (L10n.isChinese ? "重新载入 ChatGPT 订阅可用的模型" : "Reload the models your ChatGPT subscription serves")
      : (L10n.isChinese ? "从此服务商重新载入模型目录" : "Reload the model catalog from this provider")
  }

  private func refreshCatalog() {
    let configuration = settingsStore.settings.provider
    let proxy = settingsStore.settings.proxy
    let store = settingsStore
    let connection = store.settings.connections.first { $0.id == store.editingConnectionID }
    modelCatalog.refresh(configuration: configuration, proxy: proxy) {
      guard let connection else { throw TranslationError.missingAPIKey }
      return try await store.validCredentials(for: connection, proxy: proxy).accessToken
    }
  }

  private func refreshCatalogIfStale() {
    guard canFetchCatalog else { return }
    let configuration = settingsStore.settings.provider
    let proxy = settingsStore.settings.proxy
    let store = settingsStore
    let connection = store.settings.connections.first { $0.id == store.editingConnectionID }
    modelCatalog.refreshIfStale(configuration: configuration, proxy: proxy) {
      guard let connection else { throw TranslationError.missingAPIKey }
      return try await store.validCredentials(for: connection, proxy: proxy).accessToken
    }
  }

  /// Offered only when an older build actually left something in the Keychain
  /// for this provider. The read behind the button is the one thing that can
  /// raise the system password panel, so the caption says so before it happens.
  @ViewBuilder private var legacyKeychainImportRow: some View {
    if settingsStore.hasLegacyKeychainCredentials {
      VStack(alignment: .leading, spacing: AppSpacing.xs) {
        HStack(spacing: AppSpacing.sm) {
          Button(L10n.tr("settings.provider.keychain_import")) {
            settingsStore.importLegacyKeychainCredentials()
          }
          .appButton(.outline, size: .sm)
          .disabled(settingsStore.isImportingLegacyCredentials)
          if settingsStore.isImportingLegacyCredentials {
            Spinner(size: 14)
          }
        }
        InlineNote(
          text:
          L10n.isChinese
            ? "旧版 PhraseLens 将此服务商的密钥保存在登录钥匙串中。导入时需要输入一次钥匙串密码；您也可以直接在上方输入密钥。"
            : "An older PhraseLens build saved this provider's credential in your login Keychain. Importing it asks for your Keychain password once; entering the key above instead works just as well.",
          kind: .info
        )
      }
    }
  }

  private var credentialBadge: String {
    settingsStore.apiKey.isEmpty ? L10n.tr("settings.provider.no_key") : L10n.tr("settings.provider.saved")
  }

  private var credentialStatus: String {
    settingsStore.apiKey.isEmpty
      ? (L10n.isChinese ? "未为 \(settingsStore.settings.provider.provider.rawValue) 保存密钥" : "No key saved for \(settingsStore.settings.provider.provider.rawValue)")
      : (L10n.isChinese ? "已为 \(settingsStore.settings.provider.provider.rawValue) 保存密钥" : "Saved for \(settingsStore.settings.provider.provider.rawValue)")
  }

  private func isCodexModel(_ model: String) -> Bool {
    var codex = settingsStore.settings.provider
    codex.authMode = .oauthCodex
    return CodexBackend.fallbackModels.contains(model)
      || modelCatalog.models(for: codex).contains(model)
  }

  private func setAuthMode(_ mode: AuthenticationMode) {
    guard mode != settingsStore.settings.provider.authMode else { return }
    modelCatalog.cancelFetch(for: settingsStore.settings.provider)
    settingsStore.settings.provider.authMode = mode
    // The two modes reach different catalogs, so a model that belongs to the
    // one being left is swapped for the incoming mode's default. What counts as
    // a Codex model is whatever the backend last listed, not only the built-in
    // names — otherwise switching away and back discarded a model the account
    // genuinely serves.
    let model = settingsStore.settings.provider.model
    if mode == .oauthCodex {
      if !isCodexModel(model) {
        settingsStore.settings.provider.model = CodexBackend.defaultModel
      }
    } else if isCodexModel(model) {
      settingsStore.settings.provider.model = settingsStore.settings.provider.provider.defaultModel
    }
    refreshCatalogIfStale()
  }

  private func selectProvider(_ provider: ProviderKind) {
    persistAPIKeyDraft()
    modelCatalog.cancelFetch(for: settingsStore.settings.provider)
    apiKeyDraft = ""
    settingsStore.selectProvider(provider)
    endpointStatus = nil
    // The new provider's catalog is already on disk if it was ever fetched, so
    // this only goes to the network when the cache is missing or a day old.
    refreshCatalogIfStale()
  }

  private func validateEndpoint() {
    do {
      _ = try EndpointValidator.validate(
        settingsStore.settings.provider.endpoint,
        provider: settingsStore.settings.provider.provider
      )
      endpointStatus = (L10n.isChinese ? "连接成功" : "Endpoint reachable", true)
    } catch {
      endpointStatus = (error.localizedDescription, false)
    }
  }

}

// MARK: - Shortcuts

private struct ShortcutSettingsPane: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore

  var body: some View {
    PaneStack {
      SettingsCard(
        L10n.isChinese ? "全局快捷键" : "Global shortcuts",
        caption: L10n.isChinese
          ? "点按快捷键并按下您想要的组合键。设置立即生效。默认 ⌥F 打开浮窗，⌥⇧F 打开完整窗口。"
          : "Click a shortcut and press the keys you want. Shortcuts apply immediately. "
            + "The defaults pair ⌥F for the pop-up with ⌥⇧F for the full window."
      ) {
        shortcutRow(
          L10n.isChinese ? "划选翻译" : "Translate selection",
          detail: L10n.isChinese
            ? "无需打开完整工作区即可翻译选中的文字。"
            : "Translate selected text without opening the full workspace.",
          value: $settingsStore.settings.shortcuts.translateSelection
        )
        Hairline()
        shortcutRow(
          L10n.isChinese ? "切换主窗口" : "Toggle main window",
          detail: L10n.isChinese
            ? "显示或隐藏包含翻译、历史记录与工具的完整工作区。"
            : "Show or hide the complete translator, history, and tools.",
          value: $settingsStore.settings.shortcuts.showWindow
        )
        Hairline()
        shortcutRow(
          L10n.isChinese ? "截屏文字识别" : "Screenshot OCR",
          detail: L10n.isChinese
            ? "框选屏幕区域并识别提取其中的文字。"
            : "Select a screen region and recognize its text.",
          value: $settingsStore.settings.shortcuts.screenshotOCR
        )
        Hairline()
        shortcutRow(
          L10n.isChinese ? "写作" : "Writing",
          detail: L10n.isChinese
            ? "在输入框里写好内容后按下，用写作翻译、润色等动作处理它，再替换回去。"
            : "Run Compose, Polish, or another writing action on what you wrote in the focused field, then put the result in its place.",
          value: $settingsStore.settings.shortcuts.writing
        )
      }

      SettingsCard(
        L10n.isChinese ? "系统权限" : "Permissions",
        caption: L10n.isChinese
          ? "划选读取与写作需要 macOS 辅助功能权限。"
          : "Selection lookup and writing need macOS Accessibility permission."
      ) {
        SettingsRow(
          L10n.isChinese ? "辅助功能权限" : "Accessibility permission",
          detail: L10n.isChinese
            ? "划选读取屏幕文字及在其他应用中自动输入替换文本时必需。"
            : "Required for capturing selected text and typing into other apps."
        ) {
          HStack(spacing: AppSpacing.sm) {
            Badge(
              text: model.isAccessibilityTrusted
                ? (L10n.isChinese ? "已授权" : "Granted")
                : (L10n.isChinese ? "未授权" : "Not granted"),
              variant: model.isAccessibilityTrusted ? .success : .warning,
              symbol: model.isAccessibilityTrusted ? "checkmark" : "exclamationmark"
            )
            Button(L10n.isChinese ? "打开系统设置" : "Open System Settings") {
              model.openAccessibilitySettings()
            }
            .appButton(.outline, size: .sm)
            .help(L10n.isChinese ? "打开系统设置中的辅助功能" : "Open the Accessibility pane of System Settings")
          }
        }
      }

      if !model.shortcutErrors.isEmpty {
        SettingsCard(L10n.isChinese ? "故障排查" : "Problems") {
          SettingsBlock {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
              ForEach(model.shortcutErrors, id: \.self) { error in
                InlineNote(text: error, kind: .warning)
              }
            }
          }
        }
      }
    }
    .onAppear { model.refreshAccessibilityPermission() }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      model.refreshAccessibilityPermission()
    }
  }

  private func shortcutRow(
    _ title: String,
    detail: String,
    value: Binding<String>
  ) -> some View {
    SettingsRow(title, detail: detail) {
      ShortcutRecorder(value: value, accessibilityTitle: title)
    }
  }
}

// MARK: - Speech

private struct SpeechWritingSettingsPane: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @Environment(\.palette) private var palette

  var body: some View {
    PaneStack {
      SettingsCard(L10n.isChinese ? "语音朗读 (TTS)" : "Text-to-speech") {
        SettingsRow(L10n.isChinese ? "发音引擎" : "Voice engine") {
          AppSelect(
            title: L10n.isChinese ? "发音引擎" : "Voice engine",
            selection: Binding(
              get: { settingsStore.settings.resolvedTTSProvider },
              set: { settingsStore.settings.ttsProvider = $0 }
            ),
            options: TTSProvider.allCases,
            label: { $0.displayName }
          )
        }
        Hairline()
        SettingsRow(
          L10n.isChinese ? "选词后自动朗读" : "Automatically speak selected text",
          detail: L10n.isChinese
            ? "翻译完成后自动朗读源文本。"
            : "Reads the source text aloud once a translation completes."
        ) {
          Toggle("", isOn: $settingsStore.settings.autoSpeakSelection)
            .toggleStyle(AppSwitchStyle())
            .labelsHidden()
            .accessibilityLabel(L10n.isChinese ? "选词后自动朗读" : "Automatically speak selected text")
        }
        Hairline()
        SettingsRow(L10n.isChinese ? "语速" : "Speech rate") {
          Slider(value: $settingsStore.settings.speechRate, in: 0.2...0.65)
            .frame(width: 220)
            .tint(palette.foreground)
            .accessibilityLabel(L10n.isChinese ? "语速" : "Speech rate")
        }
        Hairline()
        SettingsRow(L10n.isChinese ? "音量" : "Volume") {
          Slider(value: $settingsStore.settings.speechVolume, in: 0...1)
            .frame(width: 220)
            .tint(palette.foreground)
            .accessibilityLabel(L10n.isChinese ? "音量" : "Volume")
        }
        Hairline()
        SettingsBlock {
          VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Button(L10n.isChinese ? "试听语音" : "Preview Voice") {
              model.speech.speak(
                "PhraseLens is ready.",
                language: settingsStore.settings.targetLanguage,
                rate: settingsStore.settings.speechRate,
                volume: settingsStore.settings.speechVolume,
                provider: settingsStore.settings.resolvedTTSProvider
              )
            }
            .appButton(.outline, size: .sm)

            if settingsStore.settings.resolvedTTSProvider == .edge {
              InlineNote(
                text: L10n.isChinese
                  ? "Edge 神经语音需要网络连接。语音文本将发送至 Microsoft 语音服务。"
                  : "Edge Neural voices require an internet connection. "
                    + "Spoken text is sent to Microsoft's speech service.",
                kind: .warning
              )
            }
          }
        }
      }

      SettingsCard(
        L10n.isChinese ? "写作" : "Writing",
        caption: L10n.isChinese
          ? "在任何输入框里写好内容，按 \(settingsStore.settings.shortcuts.writing)：浮窗里用下面这些动作处理它，"
            + "可以直接修改，回车替换原文。浮窗会按应用记住上次用的动作、语言和语体。"
          : "Write in any text field, then press \(settingsStore.settings.shortcuts.writing). The pop-up runs "
            + "one of the actions below on what you wrote; edit the result if you like, and Return puts it "
            + "in place. It remembers the action, language, and tone you used last in each app."
      ) {
        SettingsRow(
          L10n.isChinese ? "写作时可用的动作" : "Actions when writing",
          detail: L10n.isChinese
            ? "在“动作”里打开或关闭某个动作的“写作时可用”，也可以在那里修改它们的提示词。"
            : "Turn “Use when writing” on or off for an action in Actions, where its prompts can be edited too."
        ) {
          Text(writingActionNames)
            .font(AppFont.body)
            .foregroundStyle(palette.secondaryForeground)
            .lineLimit(2)
            .multilineTextAlignment(.trailing)
        }
        Hairline()
        SettingsRow(
          L10n.isChinese ? "先预览再替换" : "Preview before replacing",
          detail: L10n.isChinese
            ? "关闭后，快捷键会直接用上次的动作处理输入框里的文字并替换。"
            : "When off, the shortcut runs the action used last and replaces the text straight away."
        ) {
          Toggle("", isOn: $settingsStore.settings.writingShowsPreview)
            .toggleStyle(AppSwitchStyle())
            .labelsHidden()
            .accessibilityLabel(L10n.isChinese ? "先预览再替换" : "Preview before replacing")
        }
        Hairline()
        SettingsRow(
          L10n.isChinese ? "目标语言" : "Write in",
          detail: L10n.isChinese
            ? "提示词里的 ${targetLang}。浮窗里按 ⌘L 切换。"
            : "What ${targetLang} becomes. Press ⌘L in the pop-up to switch."
        ) {
          AppSelect(
            title: L10n.isChinese ? "目标语言" : "Write in",
            selection: $settingsStore.settings.writingTargetLanguage,
            options: LanguageCode.allCases.filter { $0 != .auto },
            label: { $0.displayName }
          )
        }
        if !settingsStore.settings.writingTones.isEmpty {
          Hairline()
          SettingsRow(
            L10n.isChinese ? "默认语体" : "Default tone",
            detail: L10n.isChinese
              ? "在没用过的应用里先用这个。浮窗里按 ⇥ 随时切换。"
              : "Used in apps you have not written in yet. Press Tab in the pop-up to switch."
          ) {
            AppSelect(
              title: L10n.isChinese ? "默认语体" : "Default tone",
              selection: Binding(
                get: { settingsStore.settings.writingTone(settingsStore.settings.writingToneID)?.id ?? settingsStore.settings.writingToneID },
                set: { settingsStore.settings.writingToneID = $0 }
              ),
              options: settingsStore.settings.writingTones.map(\.id),
              label: { id in settingsStore.settings.writingTones.first { $0.id == id }?.displayName ?? "" }
            )
          }
        }
      }

      WritingTonesCard()
    }
  }

  /// The actions the writing pop-up offers, by name, in its order.
  private var writingActionNames: String {
    let names = settingsStore.settings.writingActions(customActions: model.customActions).map(\.name)
    guard !names.isEmpty else { return L10n.isChinese ? "还没有" : "None yet" }
    return names.joined(separator: L10n.isChinese ? "、" : ", ")
  }
}

/// The tones the writing pop-up offers, each a name and what `${tone}`
/// becomes when it is picked.
private struct WritingTonesCard: View {
  @EnvironmentObject private var settingsStore: SettingsStore
  @Environment(\.palette) private var palette

  private var tones: [WritingTone] { settingsStore.settings.writingTones }

  var body: some View {
    SettingsCard(
      L10n.isChinese ? "语体" : "Tones",
      caption: L10n.isChinese
        ? "写作浮窗里按“发给谁”切换的语体。提示词里用到 ${tone} 的动作才会显示它们，${tone} 会换成所选语体的说明。"
        : "Who the message is for, picked in the writing pop-up. Only actions whose prompt uses ${tone} show them, "
          + "and ${tone} becomes the picked tone's instruction."
    ) {
      ForEach(Array(tones.enumerated()), id: \.element.id) { index, tone in
        if index > 0 { Hairline() }
        toneEditor(tone, index: index)
      }
      Hairline()
      HStack(spacing: AppSpacing.sm) {
        Button {
          addTone()
        } label: {
          Label(L10n.isChinese ? "添加语体" : "Add Tone", systemImage: "plus")
        }
        .appButton(.outline, size: .sm)
        Spacer(minLength: 0)
        Button(L10n.isChinese ? "恢复默认语体" : "Restore Default Tones") {
          restoreDefaults()
        }
        .appButton(.ghost, size: .sm)
        .disabled(tones == WritingTone.defaults)
      }
      .padding(.vertical, AppSpacing.xs)
    }
  }

  private func toneEditor(_ tone: WritingTone, index: Int) -> some View {
    VStack(alignment: .leading, spacing: AppSpacing.xs + 2) {
      HStack(spacing: AppSpacing.sm) {
        AppTextField(
          placeholder: L10n.isChinese ? "名称，例如：客户" : "Name, such as Clients",
          text: field(tone.id, name: true),
          size: .sm
        )
        .frame(maxWidth: 200)
        if tone.id == settingsStore.settings.writingToneID {
          Badge(text: L10n.isChinese ? "默认" : "Default", variant: .neutral)
        }
        Spacer(minLength: 0)
        IconButton(
          title: L10n.isChinese ? "上移" : "Move Up",
          symbol: "chevron.up",
          isDisabled: index == 0
        ) {
          move(tone.id, by: -1)
        }
        IconButton(
          title: L10n.isChinese ? "下移" : "Move Down",
          symbol: "chevron.down",
          isDisabled: index == tones.count - 1
        ) {
          move(tone.id, by: 1)
        }
        IconButton(
          title: L10n.isChinese ? "删除语体" : "Delete Tone",
          symbol: "trash",
          // The pop-up always has a tone to start from.
          isDisabled: tones.count == 1
        ) {
          delete(tone.id)
        }
      }
      AppTextEditor(
        text: field(tone.id, name: false),
        placeholder: L10n.isChinese
          ? "${tone} 换成的说明，例如：polite and warm, to a client"
          : "What ${tone} becomes, such as: polite and warm, to a client",
        minHeight: 52,
        monospaced: false
      )
    }
    .padding(.vertical, AppSpacing.sm)
  }

  /// A tone's name or instruction, found by identifier so a deletion
  /// elsewhere in the list cannot point an editor at the wrong tone. A
  /// shipped name reads in the interface language until it is edited.
  private func field(_ id: UUID, name: Bool) -> Binding<String> {
    Binding(
      get: {
        guard let tone = tones.first(where: { $0.id == id }) else { return "" }
        return name ? tone.displayName : tone.instruction
      },
      set: { value in
        guard let index = tones.firstIndex(where: { $0.id == id }) else { return }
        var tone = tones[index]
        if name {
          guard value != tone.displayName else { return }
          tone.name = value
        } else {
          guard value != tone.instruction else { return }
          tone.instruction = value
        }
        settingsStore.settings.writingTones[index] = tone
      }
    )
  }

  private func addTone() {
    settingsStore.settings.writingTones.append(
      WritingTone(name: L10n.isChinese ? "新语体" : "New Tone", instruction: "")
    )
  }

  private func move(_ id: UUID, by offset: Int) {
    var list = tones
    guard let index = list.firstIndex(where: { $0.id == id }),
      list.indices.contains(index + offset) else { return }
    list.swapAt(index, index + offset)
    settingsStore.settings.writingTones = list
  }

  private func delete(_ id: UUID) {
    guard tones.count > 1 else { return }
    var settings = settingsStore.settings
    settings.writingTones.removeAll { $0.id == id }
    if settings.writingToneID == id, let first = settings.writingTones.first {
      settings.writingToneID = first.id
    }
    settingsStore.settings = settings
  }

  private func restoreDefaults() {
    var settings = settingsStore.settings
    settings.writingTones = WritingTone.defaults
    if !settings.writingTones.contains(where: { $0.id == settings.writingToneID }) {
      settings.writingToneID = WritingTone.coworkersID
    }
    settingsStore.settings = settings
  }
}

// MARK: - Network

private struct NetworkSettingsPane: View {
  @EnvironmentObject private var settingsStore: SettingsStore

  var body: some View {
    PaneStack {
      SettingsCard(L10n.isChinese ? "网络代理" : "Proxy configuration") {
        SettingsRow(L10n.isChinese ? "启用代理" : "Enable proxy") {
          Toggle("", isOn: $settingsStore.settings.proxy.enabled)
            .toggleStyle(AppSwitchStyle())
            .labelsHidden()
            .accessibilityLabel(L10n.isChinese ? "启用代理" : "Enable proxy")
        }
        Hairline()
        SettingsRow(L10n.isChinese ? "协议类型" : "Proxy protocol") {
          AppSelect(
            title: L10n.isChinese ? "协议类型" : "Proxy protocol",
            selection: $settingsStore.settings.proxy.scheme,
            options: ["http", "https"],
            label: { $0.uppercased() }
          )
        }
        .disabled(!settingsStore.settings.proxy.enabled)
        Hairline()
        SettingsRow(L10n.isChinese ? "服务器地址" : "Host", stacksControl: true) {
          AppTextField(
            placeholder: "proxy.example.com",
            text: $settingsStore.settings.proxy.host,
            size: .sm,
            monospaced: true
          )
        }
        .disabled(!settingsStore.settings.proxy.enabled)
        Hairline()
        SettingsRow(L10n.isChinese ? "端口" : "Port") {
          TextField(
            L10n.isChinese ? "端口" : "Port",
            value: $settingsStore.settings.proxy.port,
            format: .number.grouping(.never)
          )
          .textFieldStyle(.roundedBorder)
          .frame(width: 100)
          .accessibilityLabel(L10n.isChinese ? "端口" : "Port")
        }
        .disabled(!settingsStore.settings.proxy.enabled)
        Hairline()
        SettingsRow(
          L10n.isChinese ? "用户名" : "Username",
          detail: L10n.isChinese ? "可选。" : "Optional.",
          stacksControl: true
        ) {
          AppTextField(
            placeholder: "username",
            text: $settingsStore.settings.proxy.username,
            size: .sm
          )
        }
        .disabled(!settingsStore.settings.proxy.enabled)
        Hairline()
        SettingsRow(
          L10n.isChinese ? "绕过代理域名 (白名单)" : "Bypass proxy for",
          detail: L10n.isChinese ? "绕过代理的主机列表，以英文逗号分隔。" : "Hosts that bypass the proxy, separated by commas.",
          stacksControl: true
        ) {
          AppTextField(
            placeholder: "localhost, 127.0.0.1",
            text: $settingsStore.settings.proxy.noProxy,
            size: .sm,
            monospaced: true
          )
        }
        .disabled(!settingsStore.settings.proxy.enabled)
        Hairline()
        SettingsBlock {
          InlineNote(
            text: L10n.isChinese
              ? "出于安全考虑，代理认证凭据不会保存在应用设置中。请通过 macOS“系统设置”>“网络”配置需要认证的代理。"
              : "Proxy credentials are intentionally not persisted in preferences. "
                + "Configure authenticated proxies through macOS Network settings.",
            kind: .info
          )
        }
      }
    }
  }
}

// MARK: - About

private struct AboutSettingsPane: View {
  @Environment(\.palette) private var palette
  @EnvironmentObject private var appUpdater: AppUpdater

  var body: some View {
    PaneStack {
      SettingsCard("PhraseLens") {
        SettingsBlock {
          HStack(alignment: .top, spacing: AppSpacing.lg) {
            AppLogo(size: 56)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
              HStack(spacing: AppSpacing.sm) {
                Text("PhraseLens")
                  .font(AppFont.display)
                Badge(
                  text: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.7.0",
                  variant: .outline
                )
                .accessibilityLabel(L10n.isChinese ? "版本" : "Version")
              }
              Text(L10n.isChinese ? "适用于 macOS 的原生 SwiftUI 语言学习与翻译工作区。" : "A native SwiftUI language workspace for macOS.")
                .font(AppFont.body)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }

      SettingsCard(L10n.isChinese ? "软件更新" : "Software Updates") {
        SettingsRow(
          L10n.isChinese ? "检查新版本" : "Check for a new version",
          detail: appUpdater.lastUpdateCheckDate.map {
            (L10n.isChinese ? "上次检查：" : "Last checked: ") + $0.formatted(date: .abbreviated, time: .shortened)
          } ?? (L10n.isChinese ? "下载更新后可直接安装并重新启动。" : "Download an update, then install and relaunch.")
        ) {
          Button(L10n.isChinese ? "检查更新…" : "Check for Updates…") { appUpdater.checkForUpdates() }
            .appButton(.outline, size: .sm)
            .disabled(!appUpdater.canCheckForUpdates)
        }
        Hairline()
        SettingsRow(
          L10n.isChinese ? "自动检查更新" : "Check automatically",
          detail: L10n.isChinese ? "定期检查新版本；有更新时通知您。" : "Check periodically and notify you when an update is available."
        ) {
          Toggle(L10n.isChinese ? "自动检查更新" : "Check automatically", isOn: Binding(
            get: { appUpdater.automaticallyChecksForUpdates },
            set: { appUpdater.setAutomaticallyChecksForUpdates($0) }
          ))
          .labelsHidden()
          .disabled(!appUpdater.isAvailable)
        }
        Hairline()
        SettingsRow(
          L10n.isChinese ? "自动下载并安装更新" : "Download and install automatically",
          detail: L10n.isChinese
            ? "在后台下载已验证的更新，并在退出时安装；也可按提示立即重启。"
            : "Download verified updates in the background and install when you quit, or relaunch when prompted."
        ) {
          Toggle(L10n.isChinese ? "自动下载并安装更新" : "Download and install automatically", isOn: Binding(
            get: { appUpdater.automaticallyDownloadsUpdates },
            set: { appUpdater.setAutomaticallyDownloadsUpdates($0) }
          ))
          .labelsHidden()
          .disabled(!appUpdater.isAvailable || !appUpdater.allowsAutomaticUpdates)
        }
        if let error = appUpdater.startupError {
          SettingsBlock { InlineNote(text: error, kind: .warning) }
        } else if !appUpdater.isAvailable {
          SettingsBlock {
            InlineNote(text: L10n.isChinese ? "请使用已打包的应用来检查更新。" : "Use the packaged app to check for updates.", kind: .info)
          }
        }
      }

      SettingsCard(L10n.isChinese ? "项目信息" : "Project") {
        SettingsRow(L10n.isChinese ? "版本" : "Version") {
          Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.7.0")
            .font(AppFont.bodyMedium)
            .foregroundStyle(palette.foreground)
        }
        Hairline()
        SettingsRow(L10n.isChinese ? "源码仓库" : "Source") {
          Link(
            "mxggle/phrase-lens",
            destination: URL(string: "https://github.com/mxggle/phrase-lens")!
          )
          .font(AppFont.bodyMedium)
          .foregroundStyle(palette.foreground)
        }
        Hairline()
        SettingsRow(
          L10n.isChinese ? "致谢与数据来源" : "Attribution",
          detail: L10n.isChinese ? "灵感来自 nextai-translator 项目。" : "Inspired by the nextai-translator project."
        ) {
          Link(
            "nextai-translator",
            destination: URL(string: "https://github.com/nextai-translator/nextai-translator")!
          )
          .font(AppFont.bodyMedium)
          .foregroundStyle(palette.foreground)
        }
        Hairline()
        SettingsRow(L10n.isChinese ? "开源协议" : "License") {
          Badge(text: "AGPL-3.0-or-later", variant: .neutral)
        }
      }
    }
  }
}

/// Vertical rhythm between the cards of one settings pane. Each pane owns its
/// stack so it can attach its own observers without repeating them per row.
private struct PaneStack<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: AppSpacing.xl + AppSpacing.xs) {
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
