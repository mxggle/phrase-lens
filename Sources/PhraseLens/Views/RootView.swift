import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
  case translator
  case history
  case vocabulary
  case actions

  var id: String { rawValue }

  var title: String {
    switch self {
    case .translator: "Translator"
    case .history: "History"
    case .vocabulary: "Vocabulary"
    case .actions: "Actions"
    }
  }

  var symbol: String {
    switch self {
    case .translator: "character.bubble"
    case .history: "clock.arrow.circlepath"
    case .vocabulary: "books.vertical"
    case .actions: "slider.horizontal.3"
    }
  }

  /// One line under the section title in the top bar. Says what the section is
  /// for, so the window never shows a bare noun with no context.
  var caption: String {
    switch self {
    case .translator: "Translate, rewrite, and explain text"
    case .history: "Every translation saved on this Mac"
    case .vocabulary: "Words you collected while reading"
    case .actions: "The prompts behind each action"
    }
  }

  /// Sidebar grouping.
  var group: Group {
    switch self {
    case .translator: .workspace
    case .history, .vocabulary: .library
    case .actions: .configure
    }
  }

  enum Group: String, CaseIterable, Identifiable {
    case workspace = "Workspace"
    case library = "Library"
    case configure = "Configure"

    var id: String { rawValue }
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
    .preferredColorScheme(settingsStore.settings.theme.preferredColorScheme)
    .alert(
      "PhraseLens",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      if model.isAccessibilityPermissionError {
        Button("Open System Settings") {
          model.errorMessage = nil
          model.openAccessibilitySettings()
        }
        Button("Not Now", role: .cancel) { model.errorMessage = nil }
      } else {
        Button("OK", role: .cancel) { model.errorMessage = nil }
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

      Hairline(axis: .vertical)

      detail
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.background)
    .animation(AppMotion.state(reduceMotion: reduceMotion), value: mode == .expanded)
  }

  private var detail: some View {
    VStack(spacing: 0) {
      NavBar(section: selection)
      Hairline()
      WidthReader { _, _ in
        switch selection {
        case .translator: TranslatorView()
        case .history: HistoryView()
        case .vocabulary: VocabularyView()
        case .actions: ActionsView()
        }
      }
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
  @Environment(\.palette) private var palette

  private var isCollapsed: Bool { mode == .rail }

  var body: some View {
    VStack(spacing: 0) {
      // The window has no title bar, so this gap is what keeps the traffic
      // lights from landing on the brand mark.
      Color.clear.frame(height: AppMetrics.trafficLightInset)

      brand
        .padding(.horizontal, isCollapsed ? AppSpacing.sm : AppSpacing.md)
        .padding(.bottom, AppSpacing.md)

      ScrollView {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
          ForEach(AppSection.Group.allCases) { group in
            let sections = AppSection.allCases.filter { $0.group == group }
            if !sections.isEmpty {
              VStack(alignment: .leading, spacing: 2) {
                if !isCollapsed {
                  Eyebrow(text: group.rawValue)
                    .padding(.horizontal, AppSpacing.sm + 2)
                    .padding(.bottom, AppSpacing.xs)
                }
                ForEach(sections) { section in
                  NavRow(
                    title: section.title,
                    symbol: section.symbol,
                    isSelected: selection == section,
                    trailing: badgeText(for: section),
                    collapsed: isCollapsed
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
    .background(palette.chrome)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Sections")
  }

  // MARK: Brand

  private var brand: some View {
    HStack(spacing: AppSpacing.sm) {
      RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
        .fill(palette.primary)
        .frame(width: 26, height: 26)
        .overlay {
          Image(systemName: "character.bubble.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.primaryForeground)
        }
        .accessibilityHidden(true)

      if !isCollapsed {
        VStack(alignment: .leading, spacing: 0) {
          Text("PhraseLens")
            .font(AppFont.bodyMedium)
            .foregroundStyle(palette.foreground)
          Text("Language workspace")
            .font(AppFont.caption)
            .foregroundStyle(palette.faintForeground)
        }
        .lineLimit(1)

        Spacer(minLength: AppSpacing.xs)

        if canToggle {
          IconButton(
            title: "Collapse the sidebar",
            symbol: "sidebar.leading",
            action: onToggle
          )
        }
      }
    }
    .frame(height: 34)
    .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
      if isCollapsed { onToggle() }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("PhraseLens")
  }

  private func badgeText(for section: AppSection) -> String? {
    switch section {
    case .history: model.history.isEmpty ? nil : "\(model.history.count)"
    case .vocabulary: model.vocabulary.isEmpty ? nil : "\(model.vocabulary.count)"
    case .actions: model.customActions.isEmpty ? nil : "\(model.customActions.count)"
    case .translator: nil
    }
  }

  // MARK: Provider

  private var isProviderConfigured: Bool {
    settingsStore.settings.provider.provider == .ollama || !settingsStore.apiKey.isEmpty
  }

  @ViewBuilder
  private var providerCard: some View {
    let provider = settingsStore.settings.provider

    SettingsLink {
      Group {
        if isCollapsed {
          StatusDot(color: isProviderConfigured ? palette.success : palette.warning)
            .frame(width: AppMetrics.controlHeight, height: AppMetrics.controlHeight)
        } else {
          HStack(spacing: AppSpacing.sm) {
            StatusDot(color: isProviderConfigured ? palette.success : palette.warning)
            VStack(alignment: .leading, spacing: 1) {
              Text(provider.provider.rawValue)
                .font(AppFont.captionMedium)
                .foregroundStyle(palette.foreground)
              Text(provider.model.isEmpty ? "No model selected" : provider.model)
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
        palette.surface, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
          .strokeBorder(palette.border, lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
    }
    .buttonStyle(.plain)
    .help(
      isProviderConfigured
        ? "\(provider.provider.rawValue) · \(provider.model) — open Settings to change it"
        : "No API key saved for \(provider.provider.rawValue) — open Settings"
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

  var body: some View {
    HStack(spacing: AppSpacing.md) {
      VStack(alignment: .leading, spacing: 1) {
        Text(section.title)
          .font(AppFont.title)
          .foregroundStyle(palette.foreground)
        if !layoutWidth.isCompact {
          Text(section.caption)
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
            .lineLimit(1)
        }
      }

      Spacer(minLength: AppSpacing.sm)

      if !model.shortcutErrors.isEmpty {
        Badge(text: "Shortcuts", variant: .warning, symbol: "exclamationmark.triangle.fill")
          .help(
            "Some global shortcuts could not be registered:\n"
              + model.shortcutErrors.joined(separator: "\n")
          )
          .accessibilityLabel("Shortcut registration problem")
      }

      NavBarActions(section: section)
    }
    .padding(.horizontal, AppSpacing.lg)
    .frame(height: AppMetrics.navBarHeight)
    .frame(maxWidth: .infinity)
    .background(palette.chrome)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(section.title) toolbar")
  }
}

/// Window-level commands for the current section. Kept out of `NavBar` so the
/// bar itself does not rebuild on every keystroke in the translator.
private struct NavBarActions: View {
  let section: AppSection

  @EnvironmentObject private var model: AppModel
  @Environment(\.layoutWidth) private var layoutWidth

  var body: some View {
    switch section {
    case .translator:
      translateButton
    case .history, .vocabulary, .actions:
      EmptyView()
    }
  }

  private var isInputEmpty: Bool {
    model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var translateButton: some View {
    Button {
      if model.isTranslating {
        model.stopTranslation()
      } else {
        model.translate()
      }
    } label: {
      HStack(spacing: AppSpacing.xs + 2) {
        Image(systemName: model.isTranslating ? "stop.fill" : "arrow.turn.down.left")
          .font(.system(size: 11, weight: .semibold))
          .contentTransition(.symbolEffect(.replace))
        if !layoutWidth.isCompact {
          Text(model.isTranslating ? "Stop" : "Translate")
        }
      }
    }
    .appButton(.primary, size: .md)
    .keyboardShortcut(.return, modifiers: [.command])
    .disabled(!model.isTranslating && isInputEmpty)
    .help(model.isTranslating ? "Stop translating (⌘.)" : "Translate (⌘↩)")
    .accessibilityLabel(model.isTranslating ? "Stop translating" : "Translate")
  }
}
