import AppKit
import SwiftUI

/// Settings panes, in the order the sidebar lists them.
private enum SettingsPane: String, CaseIterable, Identifiable {
  case general
  case provider
  case shortcuts
  case speech
  case network
  case about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .provider: "Provider"
    case .shortcuts: "Shortcuts"
    case .speech: "Speech"
    case .network: "Network"
    case .about: "About"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .provider: "cpu"
    case .shortcuts: "keyboard"
    case .speech: "speaker.wave.2"
    case .network: "network"
    case .about: "info.circle"
    }
  }

  var caption: String {
    switch self {
    case .general: "Languages, translation behavior, and the window"
    case .provider: "Which model answers, and the credential it uses"
    case .shortcuts: "Global keys and the permission they need"
    case .speech: "Voice playback and writing replacement"
    case .network: "Proxy configuration"
    case .about: "Version and licensing"
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @State private var pane: SettingsPane = .general

  var body: some View {
    ThemedContainer {
      SettingsShell(pane: $pane)
    }
    .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 620)
    .environmentObject(model)
    .environmentObject(settingsStore)
    .preferredColorScheme(settingsStore.settings.theme.preferredColorScheme)
  }
}

/// Sidebar plus a scrolling pane. Split from `SettingsView` so it can read the
/// palette published by `ThemedContainer`.
private struct SettingsShell: View {
  @Binding var pane: SettingsPane

  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: 200)
      Hairline(axis: .vertical)
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.background)
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Settings")
        .font(AppFont.title)
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, AppSpacing.sm + 2)
        .padding(.top, AppSpacing.md)
        .padding(.bottom, AppSpacing.sm)

      ForEach(SettingsPane.allCases) { item in
        NavRow(
          title: item.title,
          symbol: item.symbol,
          isSelected: pane == item
        ) {
          pane = item
        }
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, AppSpacing.sm)
    .padding(.bottom, AppSpacing.sm)
    .frame(maxHeight: .infinity)
    .background(palette.chrome)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Settings sections")
  }

  private var content: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 1) {
        Text(pane.title)
          .font(AppFont.display)
          .foregroundStyle(palette.foreground)
        Text(pane.caption)
          .font(AppFont.caption)
          .foregroundStyle(palette.mutedForeground)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, AppSpacing.xl)
      .padding(.top, AppSpacing.lg)
      .padding(.bottom, AppSpacing.md)

      Hairline()

      WidthReader { _, _ in
        ScrollView {
          Group {
            switch pane {
            case .general: GeneralSettingsPane()
            case .provider: ProviderSettingsPane()
            case .shortcuts: ShortcutSettingsPane()
            case .speech: SpeechWritingSettingsPane()
            case .network: NetworkSettingsPane()
            case .about: AboutSettingsPane()
            }
          }
          .padding(AppSpacing.xl)
          .frame(maxWidth: .infinity, alignment: .leading)
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
      SettingsCard("Languages") {
        SettingsRow("Default target", detail: "The language new translations aim for.") {
          AppSelect(
            title: "Default target language",
            selection: $settingsStore.settings.targetLanguage,
            options: selectableLanguages,
            label: { $0.displayName }
          )
        }
        Hairline()
        SettingsBlock {
          VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Languages in the translator")
              .font(AppFont.body)
            Text(
              "At least one language stays enabled. Chinese, Japanese, and English are the defaults."
            )
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            favoriteLanguageGrid
              .padding(.top, AppSpacing.xxs)
          }
        }
      }

      SettingsCard("Translation") {
        SettingsRow("Default action") {
          AppSelect(
            title: "Default action",
            selection: Binding(
              get: { settingsStore.settings.defaultActionID },
              set: { model.setDefaultAction($0) }
            ),
            options: model.visibleActions.map(\.id),
            label: { id in
              model.visibleActions.first { $0.id == id }?.name ?? "Default action"
            }
          )
        }
        Hairline()
        switchRow(
          "Translate automatically",
          detail: "Runs as soon as text arrives from a selection or from screen capture.",
          isOn: $settingsStore.settings.autoTranslate
        )
        Hairline()
        switchRow(
          "Show selections in a pop-up",
          detail: "Translates selected text in a floating panel instead of the main window.",
          isOn: $settingsStore.settings.useCompactSelectionPreview
        )
        Hairline()
        SettingsRow(
          "Pop-up position",
          detail: settingsStore.settings.selectionPanelPlacement == .nearPointer
            ? "Opens beside the pointer on the active display."
            : "Drag the pop-up once; future pop-ups return to that position."
        ) {
          AppSelect(
            title: "Pop-up position",
            selection: $settingsStore.settings.selectionPanelPlacement,
            options: SelectionPanelPlacementMode.allCases,
            label: { $0.displayName }
          )
          .disabled(!settingsStore.settings.useCompactSelectionPreview)
        }
        Hairline()
        switchRow(
          "Copy as a fallback",
          detail:
            "Uses the clipboard for web and document selections that cannot be read directly.",
          isOn: $settingsStore.settings.useClipboardFallback
        )
      }

      SettingsCard("Window") {
        SettingsRow("Appearance") {
          AppSelect(
            title: "Appearance",
            selection: $settingsStore.settings.theme,
            options: AppTheme.allCases,
            label: { $0.title }
          )
        }
        Hairline()
        switchRow("Always on top", isOn: $settingsStore.settings.alwaysOnTop)
        Hairline()
        switchRow(
          "Hide when inactive",
          detail: "Puts the window away when you switch to another app.",
          isOn: $settingsStore.settings.autoHideWhenInactive
        )
        Hairline()
        switchRow(
          "Show Dock icon",
          isOn: $settingsStore.settings.showDockIcon
        )
        Hairline()
        switchRow(
          "Launch at login",
          isOn: Binding(
            get: { settingsStore.settings.launchAtLogin },
            set: { model.applyLaunchAtLogin($0) }
          )
        )
        Hairline()
        SettingsRow("Text size", detail: "Applies to the source text and the result.") {
          HStack(spacing: AppSpacing.sm) {
            Slider(value: $settingsStore.settings.fontSize, in: 12...24, step: 1)
              .frame(width: 200)
              .tint(palette.foreground)
              .accessibilityLabel("Text size")
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
  @EnvironmentObject private var settingsStore: SettingsStore
  @Environment(\.palette) private var palette

  @State private var apiKeyDraft = ""
  @State private var endpointStatus: (text: String, isValid: Bool)?
  @State private var availableModels: [String] = []
  @State private var modelCatalogStatus: String?
  @State private var isFetchingModels = false
  @State private var modelFetchID = UUID()

  var body: some View {
    PaneStack {
      SettingsCard("AI provider") {
        SettingsRow("Provider") {
          AppSelect(
            title: "Provider",
            selection: Binding(
              get: { settingsStore.settings.provider.provider },
              set: { selectProvider($0) }
            ),
            options: ProviderKind.allCases,
            label: { $0.rawValue }
          )
        }
        Hairline()
        SettingsRow("Model", stacksControl: true) {
          VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
              AppSelect(
                title: "Model",
                selection: $settingsStore.settings.provider.model,
                options: selectableModels,
                label: { $0.isEmpty ? "No model selected" : $0 },
                fillsWidth: true
              )
              Button {
                fetchModels()
              } label: {
                if isFetchingModels {
                  Spinner(size: 12)
                } else {
                  AdaptiveLabel(title: "Fetch", symbol: "arrow.clockwise")
                }
              }
              .appButton(.outline, size: .sm)
              .disabled(isFetchModelsDisabled)
              .help("Load the model catalog from this provider")
              .accessibilityLabel("Fetch models")
            }
            if let modelCatalogStatus {
              InlineNote(
                text: modelCatalogStatus,
                kind: availableModels.isEmpty ? .error : .success
              )
            }
          }
        }
        Hairline()
        SettingsRow(
          "Model ID override",
          detail: "Use this when a provider does not expose a model catalog endpoint.",
          stacksControl: true
        ) {
          AppTextField(
            placeholder: "model-id",
            text: $settingsStore.settings.provider.model,
            size: .sm,
            monospaced: true
          )
        }
        Hairline()
        SettingsRow("API endpoint", stacksControl: true) {
          AppTextField(
            placeholder: "https://…",
            text: $settingsStore.settings.provider.endpoint,
            size: .sm,
            monospaced: true
          )
        }

        if settingsStore.settings.provider.supportsReasoningControl {
          Hairline()
          SettingsRow(
            "Enable reasoning",
            detail: "Off by default. When off, the request tells the model not to think."
          ) {
            Toggle("", isOn: $settingsStore.settings.provider.reasoningEnabled)
              .toggleStyle(AppSwitchStyle())
              .labelsHidden()
              .accessibilityLabel("Enable reasoning")
          }
        }

        if settingsStore.settings.provider.provider == .azure {
          Hairline()
          SettingsRow("API version", stacksControl: true) {
            AppTextField(
              placeholder: "2024-10-21",
              text: $settingsStore.settings.provider.apiVersion,
              size: .sm,
              monospaced: true
            )
          }
        }

        if settingsStore.settings.provider.provider == .openAI {
          Hairline()
          SettingsRow("Organization", detail: "Optional.", stacksControl: true) {
            AppTextField(
              placeholder: "org-…",
              text: $settingsStore.settings.provider.organization,
              size: .sm,
              monospaced: true
            )
          }
        }

        if settingsStore.settings.provider.provider == .anthropic {
          Hairline()
          SettingsRow("Extended thinking") {
            Toggle("", isOn: $settingsStore.settings.provider.extendedThinking)
              .toggleStyle(AppSwitchStyle())
              .labelsHidden()
              .accessibilityLabel("Extended thinking")
          }
        }
      }

      if settingsStore.settings.provider.provider.usesAPIKey {
        SettingsCard("Credential", caption: "Keys are stored per provider in the macOS Keychain.") {
          SettingsBlock {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
              HStack(spacing: AppSpacing.sm) {
                AppTextField(
                  placeholder: "API key",
                  text: $apiKeyDraft,
                  isSecure: true,
                  size: .sm,
                  onSubmit: { settingsStore.saveAPIKey(apiKeyDraft) }
                )
                .disabled(settingsStore.isLoadingAPIKey || settingsStore.isSavingAPIKey)

                Button("Save Key") {
                  settingsStore.saveAPIKey(apiKeyDraft)
                }
                .appButton(.primary, size: .sm)
                .disabled(settingsStore.isLoadingAPIKey || settingsStore.isSavingAPIKey)
              }

              HStack(spacing: AppSpacing.sm) {
                Badge(
                  text: credentialBadge,
                  variant: settingsStore.apiKey.isEmpty ? .warning : .success,
                  symbol: settingsStore.apiKey.isEmpty ? "exclamationmark" : "checkmark"
                )
                Text(credentialStatus)
                  .font(AppFont.caption)
                  .foregroundStyle(palette.mutedForeground)
              }

              if let error = settingsStore.keychainError {
                InlineNote(text: error, kind: .error)
              }
            }
          }
        }
      }

      SettingsCard("Endpoint safety") {
        SettingsBlock {
          VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
              Button("Validate Configuration") { validateEndpoint() }
                .appButton(.outline, size: .sm)
              if let endpointStatus {
                InlineNote(
                  text: endpointStatus.text,
                  kind: endpointStatus.isValid ? .success : .error
                )
              }
            }
            InlineNote(
              text: "HTTPS is required. Plain HTTP is accepted only for Ollama on this Mac.",
              kind: .info
            )
          }
        }
      }
    }
    .onAppear { apiKeyDraft = settingsStore.apiKey }
    .onChange(of: settingsStore.apiKey) { _, value in
      apiKeyDraft = value
    }
  }

  private var isFetchModelsDisabled: Bool {
    isFetchingModels || settingsStore.isLoadingAPIKey
      || (settingsStore.settings.provider.provider.usesAPIKey && settingsStore.apiKey.isEmpty)
  }

  private var selectableModels: [String] {
    let current = settingsStore.settings.provider.model
    guard !current.isEmpty, !availableModels.contains(current) else {
      return availableModels.isEmpty ? [current] : availableModels
    }
    return [current] + availableModels
  }

  private var credentialBadge: String {
    settingsStore.apiKey.isEmpty ? "No key" : "Saved"
  }

  private var credentialStatus: String {
    if settingsStore.isLoadingAPIKey { return "Loading this provider’s key from Keychain…" }
    if settingsStore.isSavingAPIKey { return "Saving this provider’s key to Keychain…" }
    return settingsStore.apiKey.isEmpty
      ? "No key saved for \(settingsStore.settings.provider.provider.rawValue)"
      : "In the Keychain for \(settingsStore.settings.provider.provider.rawValue)"
  }

  private func selectProvider(_ provider: ProviderKind) {
    apiKeyDraft = ""
    availableModels = []
    modelCatalogStatus = nil
    isFetchingModels = false
    modelFetchID = UUID()
    settingsStore.selectProvider(provider)
    endpointStatus = nil
  }

  private func validateEndpoint() {
    do {
      _ = try EndpointValidator.validate(
        settingsStore.settings.provider.endpoint,
        provider: settingsStore.settings.provider.provider
      )
      endpointStatus = ("Endpoint format is valid.", true)
    } catch {
      endpointStatus = (error.localizedDescription, false)
    }
  }

  private func fetchModels() {
    let configuration = settingsStore.settings.provider
    let provider = configuration.provider
    let apiKey = settingsStore.apiKey
    let proxy = settingsStore.settings.proxy
    let requestID = UUID()
    modelFetchID = requestID
    isFetchingModels = true
    modelCatalogStatus = nil
    Task {
      do {
        let models = try await ModelCatalogClient().fetchModels(
          configuration: configuration,
          apiKey: apiKey,
          proxy: proxy
        )
        guard requestID == modelFetchID,
          provider == settingsStore.settings.provider.provider
        else { return }
        availableModels = models
        modelCatalogStatus = "Fetched \(models.count) models from \(provider.rawValue)."
      } catch {
        guard requestID == modelFetchID,
          provider == settingsStore.settings.provider.provider
        else { return }
        availableModels = []
        modelCatalogStatus = error.localizedDescription
      }
      if requestID == modelFetchID,
        provider == settingsStore.settings.provider.provider
      {
        isFetchingModels = false
      }
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
        "Global shortcuts",
        caption: "Click a shortcut and press the keys you want. Shortcuts apply immediately. "
          + "The defaults pair ⌥F for the pop-up with ⌥⇧F for the full window."
      ) {
        shortcutRow(
          "Selection pop-up",
          detail: "Translate selected text without opening the full workspace.",
          value: $settingsStore.settings.shortcuts.translateSelection
        )
        Hairline()
        shortcutRow(
          "Full translator window",
          detail: "Open the complete translator, history, and tools.",
          value: $settingsStore.settings.shortcuts.showWindow
        )
        Hairline()
        shortcutRow(
          "Screenshot OCR",
          detail: "Select a screen region and recognize its text.",
          value: $settingsStore.settings.shortcuts.screenshotOCR
        )
        Hairline()
        shortcutRow(
          "Translate focused input",
          detail: "Replace text in the focused editable control.",
          value: $settingsStore.settings.shortcuts.writing
        )
      }

      SettingsCard(
        "Permission",
        caption: "Selection lookup and writing replacement need macOS Accessibility permission."
      ) {
        SettingsRow("Accessibility access") {
          HStack(spacing: AppSpacing.sm) {
            Badge(
              text: model.isAccessibilityTrusted ? "Granted" : "Not granted",
              variant: model.isAccessibilityTrusted ? .success : .warning,
              symbol: model.isAccessibilityTrusted ? "checkmark" : "exclamationmark"
            )
            Button("Open Settings…") {
              model.openAccessibilitySettings()
            }
            .appButton(.outline, size: .sm)
            .help("Open the Accessibility pane of System Settings")
          }
        }
      }

      if !model.shortcutErrors.isEmpty {
        SettingsCard("Problems") {
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
      SettingsCard("Text to speech") {
        SettingsRow("Voice engine") {
          AppSelect(
            title: "Voice engine",
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
          "Speak after translating",
          detail: "Reads the source text aloud once a translation completes."
        ) {
          Toggle("", isOn: $settingsStore.settings.autoSpeakSelection)
            .toggleStyle(AppSwitchStyle())
            .labelsHidden()
            .accessibilityLabel("Automatically speak source text after translation")
        }
        Hairline()
        SettingsRow("Rate") {
          Slider(value: $settingsStore.settings.speechRate, in: 0.2...0.65)
            .frame(width: 220)
            .tint(palette.foreground)
            .accessibilityLabel("Speech rate")
        }
        Hairline()
        SettingsRow("Volume") {
          Slider(value: $settingsStore.settings.speechVolume, in: 0...1)
            .frame(width: 220)
            .tint(palette.foreground)
            .accessibilityLabel("Speech volume")
        }
        Hairline()
        SettingsBlock {
          VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Button("Preview Voice") {
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
                text: "Edge Neural voices require an internet connection. "
                  + "Spoken text is sent to Microsoft's speech service.",
                kind: .warning
              )
            }
          }
        }
      }

      SettingsCard(
        "Writing replacement",
        caption: "Press the writing shortcut while an editable control is focused. The app "
          + "translates its text and replaces it through the Accessibility API."
      ) {
        SettingsRow("Writing target language") {
          AppSelect(
            title: "Writing target language",
            selection: $settingsStore.settings.writingTargetLanguage,
            options: LanguageCode.allCases.filter { $0 != .auto },
            label: { $0.displayName }
          )
        }
      }
    }
  }
}

// MARK: - Network

private struct NetworkSettingsPane: View {
  @EnvironmentObject private var settingsStore: SettingsStore

  var body: some View {
    PaneStack {
      SettingsCard("Proxy") {
        SettingsRow("Use proxy") {
          Toggle("", isOn: $settingsStore.settings.proxy.enabled)
            .toggleStyle(AppSwitchStyle())
            .labelsHidden()
            .accessibilityLabel("Use proxy")
        }
        Hairline()
        SettingsRow("Protocol") {
          AppSelect(
            title: "Protocol",
            selection: $settingsStore.settings.proxy.scheme,
            options: ["http", "https"],
            label: { $0.uppercased() }
          )
        }
        .disabled(!settingsStore.settings.proxy.enabled)
        Hairline()
        SettingsRow("Server", stacksControl: true) {
          AppTextField(
            placeholder: "proxy.example.com",
            text: $settingsStore.settings.proxy.host,
            size: .sm,
            monospaced: true
          )
        }
        .disabled(!settingsStore.settings.proxy.enabled)
        Hairline()
        SettingsRow("Port") {
          TextField(
            "Port",
            value: $settingsStore.settings.proxy.port,
            format: .number.grouping(.never)
          )
          .textFieldStyle(.roundedBorder)
          .frame(width: 100)
          .accessibilityLabel("Proxy port")
        }
        .disabled(!settingsStore.settings.proxy.enabled)
        Hairline()
        SettingsRow("Username", detail: "Optional.", stacksControl: true) {
          AppTextField(
            placeholder: "username",
            text: $settingsStore.settings.proxy.username,
            size: .sm
          )
        }
        .disabled(!settingsStore.settings.proxy.enabled)
        Hairline()
        SettingsRow(
          "No proxy",
          detail: "Hosts that bypass the proxy, separated by commas.",
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
            text: "Proxy credentials are intentionally not persisted in preferences. "
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

  var body: some View {
    PaneStack {
      SettingsCard("PhraseLens") {
        SettingsBlock {
          HStack(alignment: .top, spacing: AppSpacing.lg) {
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
              .fill(palette.primary)
              .frame(width: 56, height: 56)
              .overlay {
                Image(systemName: "character.bubble.fill")
                  .font(.system(size: 24, weight: .semibold))
                  .foregroundStyle(palette.primaryForeground)
              }
              .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
              HStack(spacing: AppSpacing.sm) {
                Text("PhraseLens")
                  .font(AppFont.display)
                Badge(text: "0.1.0", variant: .outline)
              }
              Text("A native SwiftUI language workspace for macOS.")
                .font(AppFont.body)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }

      SettingsCard("Project") {
        SettingsRow("Source", detail: "The project this app is a native port of.") {
          Link(
            "nextai-translator",
            destination: URL(string: "https://github.com/nextai-translator/nextai-translator")!
          )
          .font(AppFont.bodyMedium)
          .foregroundStyle(palette.foreground)
        }
        Hairline()
        SettingsRow("License") {
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
    VStack(alignment: .leading, spacing: AppSpacing.lg) {
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
