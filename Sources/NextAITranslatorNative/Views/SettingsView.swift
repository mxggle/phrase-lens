import AppKit
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore

  var body: some View {
    TabView {
      GeneralSettingsPane()
        .tabItem { Label("General", systemImage: "gearshape") }

      ProviderSettingsPane()
        .tabItem { Label("Provider", systemImage: "cpu") }

      ShortcutSettingsPane()
        .tabItem { Label("Shortcuts", systemImage: "keyboard") }

      SpeechWritingSettingsPane()
        .tabItem { Label("Speech", systemImage: "speaker.wave.2") }

      NetworkSettingsPane()
        .tabItem { Label("Network", systemImage: "network") }

      AboutSettingsPane()
        .tabItem { Label("About", systemImage: "info.circle") }
    }
    // Settings panes size themselves; the window only sets the shared width so
    // switching tabs does not change how wide the window is.
    .frame(width: 620, height: 540)
    .environmentObject(model)
    .environmentObject(settingsStore)
  }
}

private struct GeneralSettingsPane: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore

  var body: some View {
    Form {
      Section("Languages") {
        Picker("Default target", selection: $settingsStore.settings.targetLanguage) {
          ForEach(LanguageCode.allCases.filter { $0 != .auto }) { language in
            Text(language.displayName).tag(language)
          }
        }
      }

      Section {
        favoriteLanguageGrid
      } header: {
        Text("Languages in the Translator")
      } footer: {
        Text("At least one language stays enabled. Chinese, Japanese, and English are the defaults.")
      }

      Section("Translation") {
        Picker("Default action", selection: $settingsStore.settings.defaultActionID) {
          ForEach(model.allActions) { action in
            Text(action.name).tag(action.id)
          }
        }
        .onChange(of: settingsStore.settings.defaultActionID) { _, value in
          model.selectedActionID = value
        }
        Toggle(
          "Translate automatically after selection and OCR",
          isOn: $settingsStore.settings.autoTranslate)
        Toggle(
          "Show selected-text translations in a pop-up",
          isOn: $settingsStore.settings.useCompactSelectionPreview)
        Toggle(
          "Copy web and document selections when direct lookup is unavailable",
          isOn: $settingsStore.settings.useClipboardFallback)
      }

      Section("Window") {
        Picker("Appearance", selection: $settingsStore.settings.theme) {
          ForEach(AppTheme.allCases) { theme in
            Text(theme.title).tag(theme)
          }
        }
        Toggle("Always on top", isOn: $settingsStore.settings.alwaysOnTop)
        Toggle("Hide when inactive", isOn: $settingsStore.settings.autoHideWhenInactive)
        Toggle("Show Dock icon", isOn: $settingsStore.settings.showDockIcon)
          .onChange(of: settingsStore.settings.showDockIcon) { _, visible in
            NSApp.setActivationPolicy(visible ? .regular : .accessory)
          }
        Toggle(
          "Launch at login",
          isOn: Binding(
            get: { settingsStore.settings.launchAtLogin },
            set: { model.applyLaunchAtLogin($0) }
          )
        )
        LabeledContent("Text size") {
          Slider(value: $settingsStore.settings.fontSize, in: 12...24, step: 1)
            .frame(width: 220)
          Text("\(Int(settingsStore.settings.fontSize)) pt")
            .monospacedDigit()
            .frame(width: 42, alignment: .trailing)
        }
      }
    }
    .formStyle(.grouped)
  }

  private var favoriteLanguageGrid: some View {
    VStack(alignment: .leading, spacing: AppSpacing.sm) {
      LazyVGrid(
        columns: [
          GridItem(.adaptive(minimum: 118), spacing: AppSpacing.sm)
        ], alignment: .leading, spacing: AppSpacing.sm
      ) {
        ForEach(LanguageCode.allCases.filter { $0 != .auto }) { language in
          Toggle(
            language.displayName,
            isOn: Binding(
              get: {
                settingsStore.settings.favoriteLanguages.contains(language)
              },
              set: { enabled in
                if enabled {
                  if !settingsStore.settings.favoriteLanguages.contains(language) {
                    settingsStore.settings.favoriteLanguages.append(language)
                  }
                } else if settingsStore.settings.favoriteLanguages.count > 1 {
                  settingsStore.settings.favoriteLanguages.removeAll { $0 == language }
                  if settingsStore.settings.targetLanguage == language {
                    settingsStore.settings.targetLanguage =
                      settingsStore.settings.favoriteLanguages[0]
                  }
                }
              }
            )
          )
          .toggleStyle(.button)
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
    }
    .padding(.vertical, AppSpacing.xs)
  }
}

private struct ProviderSettingsPane: View {
  @EnvironmentObject private var settingsStore: SettingsStore
  @State private var apiKeyDraft = ""
  @State private var endpointStatus: String?
  @State private var availableModels: [String] = []
  @State private var modelCatalogStatus: String?
  @State private var isFetchingModels = false
  @State private var modelFetchID = UUID()

  var body: some View {
    Form {
      Section("AI provider") {
        Picker(
          "Provider",
          selection: Binding(
            get: { settingsStore.settings.provider.provider },
            set: { provider in
              apiKeyDraft = ""
              availableModels = []
              modelCatalogStatus = nil
              isFetchingModels = false
              modelFetchID = UUID()
              settingsStore.selectProvider(provider)
              endpointStatus = nil
            }
          )
        ) {
          ForEach(ProviderKind.allCases) { provider in
            Text(provider.rawValue).tag(provider)
          }
        }

        LabeledContent("Model") {
          HStack(spacing: 8) {
            Picker("Model", selection: $settingsStore.settings.provider.model) {
              ForEach(selectableModels, id: \.self) { model in
                Text(model).tag(model)
              }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Button {
              fetchModels()
            } label: {
              if isFetchingModels {
                ProgressView().controlSize(.small)
              } else {
                Label("Fetch Models", systemImage: "arrow.clockwise")
              }
            }
            .disabled(
              isFetchingModels || settingsStore.isLoadingAPIKey
                || (settingsStore.settings.provider.provider.usesAPIKey
                  && settingsStore.apiKey.isEmpty)
            )
          }
        }
        if let modelCatalogStatus {
          Text(modelCatalogStatus)
            .font(.caption)
            .foregroundStyle(availableModels.isEmpty ? .red : .secondary)
        }
        TextField("Model ID override", text: $settingsStore.settings.provider.model)
          .textFieldStyle(.roundedBorder)
          .help("Use this when a provider does not expose a model catalog endpoint.")
        TextField("API endpoint", text: $settingsStore.settings.provider.endpoint)
          .textFieldStyle(.roundedBorder)

        if settingsStore.settings.provider.supportsReasoningControl {
          Toggle(
            "Enable reasoning",
            isOn: $settingsStore.settings.provider.reasoningEnabled
          )
          .help("Off by default. When off, the request tells the model not to think.")
        }

        if settingsStore.settings.provider.provider == .azure {
          TextField("API version", text: $settingsStore.settings.provider.apiVersion)
        }
        if settingsStore.settings.provider.provider == .openAI {
          TextField("Organization (optional)", text: $settingsStore.settings.provider.organization)
        }
        if settingsStore.settings.provider.provider == .anthropic {
          Toggle(
            "Extended thinking",
            isOn: $settingsStore.settings.provider.extendedThinking
          )
        }
      }

      if settingsStore.settings.provider.provider.usesAPIKey {
        Section("Credential") {
          SecureField("API key", text: $apiKeyDraft)
            .textFieldStyle(.roundedBorder)
            .onSubmit { settingsStore.saveAPIKey(apiKeyDraft) }
            .disabled(settingsStore.isLoadingAPIKey || settingsStore.isSavingAPIKey)
          HStack {
            Text(credentialStatus)
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("Save Key") {
              settingsStore.saveAPIKey(apiKeyDraft)
            }
            .buttonStyle(.borderedProminent)
            .disabled(settingsStore.isLoadingAPIKey || settingsStore.isSavingAPIKey)
          }
          if let error = settingsStore.keychainError {
            Label(error, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
          }
        }
      }

      Section("Endpoint safety") {
        HStack {
          Button("Validate Configuration") {
            do {
              _ = try EndpointValidator.validate(
                settingsStore.settings.provider.endpoint,
                provider: settingsStore.settings.provider.provider
              )
              endpointStatus = "Endpoint format is valid."
            } catch {
              endpointStatus = error.localizedDescription
            }
          }
          if let endpointStatus {
            Text(endpointStatus)
              .font(.caption)
              .foregroundStyle(endpointStatus.contains("valid") ? .green : .red)
          }
        }
        Text("HTTPS is required. Plain HTTP is accepted only for Ollama on this Mac.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .onAppear { apiKeyDraft = settingsStore.apiKey }
    .onChange(of: settingsStore.apiKey) { _, value in
      apiKeyDraft = value
    }
  }

  private var selectableModels: [String] {
    let current = settingsStore.settings.provider.model
    guard !current.isEmpty, !availableModels.contains(current) else { return availableModels }
    return [current] + availableModels
  }

  private var credentialStatus: String {
    if settingsStore.isLoadingAPIKey { return "Loading this provider’s key from Keychain…" }
    if settingsStore.isSavingAPIKey { return "Saving this provider’s key to Keychain…" }
    return settingsStore.apiKey.isEmpty
      ? "No key saved for this provider"
      : "Saved for \(settingsStore.settings.provider.provider.rawValue) in macOS Keychain"
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

private struct ShortcutSettingsPane: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore

  var body: some View {
    Form {
      Section {
        shortcutRow(
          "Selection pop-up",
          detail: "Translate selected text without opening the full workspace.",
          value: $settingsStore.settings.shortcuts.translateSelection
        )
        shortcutRow(
          "Full translator window",
          detail: "Open the complete translator, history, and tools.",
          value: $settingsStore.settings.shortcuts.showWindow
        )
        shortcutRow(
          "Screenshot OCR",
          detail: "Select a screen region and recognize its text.",
          value: $settingsStore.settings.shortcuts.screenshotOCR
        )
        shortcutRow(
          "Translate focused input",
          detail: "Replace text in the focused editable control.",
          value: $settingsStore.settings.shortcuts.writing
        )
      } header: {
        Text("Global Shortcuts")
      } footer: {
        Text(
          "Click a shortcut and press the keys you want. Shortcuts apply immediately. "
            + "The defaults pair ⌥F for the pop-up with ⌥⇧F for the full window."
        )
      }

      Section {
        LabeledContent {
          Label(
            model.isAccessibilityTrusted ? "Granted" : "Not granted",
            systemImage: model.isAccessibilityTrusted
              ? "checkmark.circle.fill"
              : "exclamationmark.triangle.fill"
          )
          .foregroundStyle(model.isAccessibilityTrusted ? .green : .orange)
        } label: {
          Text("Accessibility access")
        }
        Button("Open Accessibility Settings…") {
          model.openAccessibilitySettings()
        }
      } header: {
        Text("Permission")
      } footer: {
        Text("Selection lookup and writing replacement need macOS Accessibility permission.")
      }

      if !model.shortcutErrors.isEmpty {
        Section("Problems") {
          ForEach(model.shortcutErrors, id: \.self) { error in
            Label(error, systemImage: "keyboard.badge.exclamationmark")
              .foregroundStyle(.orange)
          }
        }
      }
    }
    .formStyle(.grouped)
    .onChange(of: settingsStore.settings.shortcuts) { _, _ in
      model.configureHotKeys()
    }
    .onAppear {
      model.refreshAccessibilityPermission()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) {
      _ in
      model.refreshAccessibilityPermission()
    }
  }

  private func shortcutRow(
    _ title: String,
    detail: String,
    value: Binding<String>
  ) -> some View {
    LabeledContent {
      ShortcutRecorder(value: value, accessibilityTitle: title)
    } label: {
      VStack(alignment: .leading, spacing: AppSpacing.xxs) {
        Text(title)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct SpeechWritingSettingsPane: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore

  var body: some View {
    Form {
      Section("Text to speech") {
        Picker(
          "Voice engine",
          selection: Binding(
            get: { settingsStore.settings.resolvedTTSProvider },
            set: { settingsStore.settings.ttsProvider = $0 }
          )
        ) {
          ForEach(TTSProvider.allCases) { provider in
            Text(provider.displayName).tag(provider)
          }
        }
        Toggle(
          "Automatically speak source text after translation",
          isOn: $settingsStore.settings.autoSpeakSelection
        )
        LabeledContent("Rate") {
          Slider(value: $settingsStore.settings.speechRate, in: 0.2...0.65)
            .frame(width: 250)
        }
        LabeledContent("Volume") {
          Slider(value: $settingsStore.settings.speechVolume, in: 0...1)
            .frame(width: 250)
        }
        Button("Preview Voice") {
          model.speech.speak(
            "PhraseLens is ready.",
            language: settingsStore.settings.targetLanguage,
            rate: settingsStore.settings.speechRate,
            volume: settingsStore.settings.speechVolume,
            provider: settingsStore.settings.resolvedTTSProvider
          )
        }
        if settingsStore.settings.resolvedTTSProvider == .edge {
          Text("Edge Neural voices require an internet connection. Spoken text is sent to Microsoft's speech service.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section("Writing replacement") {
        Picker(
          "Writing target language",
          selection: $settingsStore.settings.writingTargetLanguage
        ) {
          ForEach(LanguageCode.allCases.filter { $0 != .auto }) { language in
            Text(language.displayName).tag(language)
          }
        }
        Text(
          "Press the writing shortcut while an editable control is focused. The app translates its text and replaces it through the Accessibility API."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

private struct NetworkSettingsPane: View {
  @EnvironmentObject private var settingsStore: SettingsStore

  var body: some View {
    Form {
      Section("Proxy") {
        Toggle("Use proxy", isOn: $settingsStore.settings.proxy.enabled)
        Picker("Protocol", selection: $settingsStore.settings.proxy.scheme) {
          Text("HTTP").tag("http")
          Text("HTTPS").tag("https")
        }
        TextField("Server", text: $settingsStore.settings.proxy.host)
        TextField(
          "Port",
          value: $settingsStore.settings.proxy.port,
          format: .number.grouping(.never)
        )
        TextField("Username (optional)", text: $settingsStore.settings.proxy.username)
        TextField("No proxy", text: $settingsStore.settings.proxy.noProxy)
      }
      Section {
        Text(
          "Proxy credentials are intentionally not persisted in preferences. Configure authenticated proxies through macOS Network settings."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

private struct AboutSettingsPane: View {
  var body: some View {
    VStack(spacing: AppSpacing.lg) {
      Image(systemName: "character.bubble.fill")
        .font(.system(size: 64))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.tint)
        .accessibilityHidden(true)

      VStack(spacing: AppSpacing.xs) {
        Text("PhraseLens")
          .font(.title2.weight(.semibold))
        Text("Version 0.1.0")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Text("A native SwiftUI language workspace for macOS.")
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 340)

      Link(
        "Original project",
        destination: URL(string: "https://github.com/nextai-translator/nextai-translator")!
      )

      Text("AGPL-3.0-or-later")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(AppSpacing.xxl)
  }
}
