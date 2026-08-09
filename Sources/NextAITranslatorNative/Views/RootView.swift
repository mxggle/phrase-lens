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
}

struct RootView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @State private var selection: AppSection = .translator

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(
          min: AppMetrics.sidebarMinWidth,
          ideal: AppMetrics.sidebarIdealWidth,
          max: AppMetrics.sidebarMaxWidth
        )
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.balanced)
    .onChange(of: settingsStore.settings.alwaysOnTop) { _, value in
      WindowCoordinator.mainWindow()?.level = value ? .floating : .normal
    }
    .alert(
      "NextAI Translator",
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

  // MARK: - Sidebar

  private var sidebar: some View {
    List(AppSection.allCases, selection: $selection) { section in
      Label(section.title, systemImage: section.symbol)
        .tag(section)
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      providerStatus
    }
  }

  /// The sidebar footer reports which model answers requests and doubles as the
  /// way into Settings, so provider state and the control that changes it stay
  /// in the same place.
  private var providerStatus: some View {
    VStack(spacing: 0) {
      Divider()
      SettingsLink {
        HStack(spacing: AppSpacing.sm) {
          StatusDot(color: isProviderConfigured ? .green : .orange)
          VStack(alignment: .leading, spacing: 1) {
            Text(settingsStore.settings.provider.provider.rawValue)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.primary)
            Text(settingsStore.settings.provider.model)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Spacer(minLength: AppSpacing.xs)
          Image(systemName: "gearshape")
            .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm + 2)
      }
      .buttonStyle(.plain)
      .help(
        isProviderConfigured
          ? "Open Settings to change the provider or model"
          : "No API key saved for this provider — open Settings"
      )
      .accessibilityLabel(
        "Provider \(settingsStore.settings.provider.provider.rawValue), "
          + "model \(settingsStore.settings.provider.model). Opens Settings."
      )
    }
  }

  private var isProviderConfigured: Bool {
    settingsStore.settings.provider.provider == .ollama || !settingsStore.apiKey.isEmpty
  }

  // MARK: - Detail

  private var detail: some View {
    Group {
      switch selection {
      case .translator: TranslatorView()
      case .history: HistoryView()
      case .vocabulary: VocabularyView()
      case .actions: ActionsView()
      }
    }
    .navigationTitle(selection.title)
    .toolbar {
      if !model.shortcutErrors.isEmpty {
        ToolbarItem(placement: .status) {
          Image(systemName: "keyboard.badge.exclamationmark")
            .foregroundStyle(.orange)
            .help(
              "Some global shortcuts could not be registered:\n"
                + model.shortcutErrors.joined(separator: "\n")
            )
            .accessibilityLabel("Shortcut registration problem")
        }
      }
    }
  }
}
