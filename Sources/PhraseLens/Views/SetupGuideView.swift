import AppKit
import SwiftUI

/// A short, resumable path to a first translation. It describes saved local
/// configuration as such; only a real translation can prove the provider works.
struct SetupGuideView: View {
  let showTranslator: () -> Void

  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @EnvironmentObject private var modelCatalog: ModelCatalogStore
  @Environment(\.openSettings) private var openSettings
  @Environment(\.palette) private var palette
  @State private var step = 0
  @State private var unlockedStep = 0
  @State private var choice: ConnectionChoice?
  @State private var otherProviderSelection: ProviderKind?
  @State private var apiKeyDraft = ""

  private enum ConnectionChoice: String, CaseIterable, Identifiable {
    case chatGPT = "I have a ChatGPT account"
    case openAIKey = "I have an OpenAI API key"
    case otherKey = "I have an API key from another service"
    case ollama = "I use Ollama on this Mac"

    var id: String { rawValue }

    var explanation: String {
      switch self {
      case .chatGPT: "Use your ChatGPT or Codex account. No key to paste."
      case .openAIKey: "Use a key from OpenAI Platform, including Codex CLI keys."
      case .otherKey: "Choose the service that issued your key."
      case .ollama: "Use a local model. No account or API key."
      }
    }
  }

  private var provider: ProviderConfiguration { settingsStore.settings.provider }
  private var isOAuth: Bool {
    provider.provider.supportsOAuth && provider.authMode == .oauthCodex
  }
  private var needsEndpoint: Bool {
    !isOAuth && (try? EndpointValidator.validate(provider.endpoint, provider: provider.provider)) == nil
  }
  private var hasUnsavedKey: Bool {
    choice == .openAIKey || choice == .otherKey
      ? apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines) != settingsStore.apiKey
      : false
  }
  private var canContinue: Bool {
    (choice != .otherKey || otherProviderSelection != nil)
      && settingsStore.hasBasicProviderConfiguration && !hasUnsavedKey
  }

  private let tabNames = ["Account", "Connect", "Model", "Shortcuts", "Try it"]

  var body: some View {
    VStack(alignment: .leading, spacing: AppSpacing.md) {
      HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
          Text("Set up PhraseLens")
            .font(AppFont.display)
            .foregroundStyle(palette.foreground)
          Text("Five small steps to your first translation")
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
        }
        Spacer(minLength: AppSpacing.sm)
        Button("Skip for now") {
          settingsStore.dismissSetupGuide()
          showTranslator()
        }
        .appButton(.ghost, size: .sm)
      }

      HStack(spacing: AppSpacing.xs) {
        ForEach(0..<tabNames.count, id: \.self) { index in
          Button {
            guard index <= unlockedStep else { return }
            step = index
          } label: {
            HStack(spacing: AppSpacing.xs) {
              Text("\(index + 1)")
                .font(AppFont.captionMedium)
              Text(tabNames[index])
                .font(AppFont.captionMedium)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
            .foregroundStyle(step == index ? palette.foreground : palette.secondaryForeground)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(step == index ? palette.accentFill : palette.surface,
                        in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay {
              RoundedRectangle(cornerRadius: AppRadius.md)
                .strokeBorder(step == index ? palette.borderStrong : palette.border)
            }
          }
          .buttonStyle(.plain)
          .disabled(index > unlockedStep)
          .accessibilityLabel("Step \(index + 1): \(tabNames[index])")
          .accessibilityAddTraits(step == index ? .isSelected : [])
        }
      }

      Group {
        switch step {
        case 0: accountStep
        case 1: connectStep
        case 2: modelStep
        case 3: permissionStep
        default: tryStep
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      HStack(spacing: AppSpacing.sm) {
        Text(footerStatus)
          .font(AppFont.caption)
          .foregroundStyle(palette.mutedForeground)
          .lineLimit(1)
        Spacer(minLength: AppSpacing.xs)
        if step > 0 {
          Button("Back") { step -= 1 }
            .appButton(.outline, size: .sm)
        }
        if step < tabNames.count - 1 {
          Button("Next: \(tabNames[step + 1])") { goNext() }
            .appButton(.primary, size: .sm)
            .disabled(!canGoNext)
        }
      }
    }
    .frame(maxWidth: 620, maxHeight: .infinity, alignment: .topLeading)
    .padding(.horizontal, AppSpacing.lg)
    .padding(.vertical, AppSpacing.md)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      model.refreshAccessibilityPermission()
      apiKeyDraft = settingsStore.apiKey
      if choice == nil, settingsStore.hasProviderCredential {
        choice = currentChoice
        if choice == .otherKey { otherProviderSelection = provider.provider }
        unlockedStep = settingsStore.hasBasicProviderConfiguration ? 4 : 2
        refreshCatalogIfReady()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      model.refreshAccessibilityPermission()
    }
    .onChange(of: settingsStore.apiKey) { _, value in apiKeyDraft = value }
    .onChange(of: settingsStore.oauthCredentials) { oldValue, newValue in
      guard isOAuth else { return }
      let oldAccount = oldValue?.accountId ?? oldValue?.email ?? oldValue?.accessToken
      let newAccount = newValue?.accountId ?? newValue?.email ?? newValue?.accessToken
      guard oldAccount != newAccount else { return }
      modelCatalog.invalidate(for: provider)
      if newValue != nil { refreshCatalogIfReady() }
    }
    .onChange(of: modelCatalog.snapshots) { _, _ in chooseAvailableOAuthModel() }
  }

  private var canGoNext: Bool {
    switch step {
    case 0: choice != nil
    case 1:
      (choice != .otherKey || otherProviderSelection != nil)
        && settingsStore.hasProviderCredential && !hasUnsavedKey
    case 2: canContinue
    default: true
    }
  }

  private var footerStatus: String {
    switch step {
    case 0: return choice == nil ? "Choose one option" : "You can change this later"
    case 1:
      if choice == .otherKey, otherProviderSelection == nil { return "Choose your AI service" }
      if hasUnsavedKey { return "Save your new key to continue" }
      if choice == .ollama { return "No key needed; start Ollama before trying" }
      return settingsStore.hasProviderCredential ? "Credential saved locally" : "Sign in or save a key"
    case 2: return canContinue ? "Ready for a test translation" : missingSetupMessage
    case 3: return "This permission is optional"
    default: return "A result will confirm the connection"
    }
  }

  private func goNext() {
    guard canGoNext, step < tabNames.count - 1 else { return }
    unlockedStep = max(unlockedStep, step + 1)
    step += 1
  }

  private var accountStep: some View {
    SettingsCard("What do you already have?", caption: "ChatGPT accounts and OpenAI Platform API keys use different sign-in methods.") {
      SettingsBlock {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
          ForEach(ConnectionChoice.allCases) { option in
            Button { choose(option) } label: {
              HStack(alignment: .center, spacing: AppSpacing.sm) {
                Image(systemName: choice == option ? "largecircle.fill.circle" : "circle")
                  .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                  Text(option.rawValue).font(AppFont.bodyMedium)
                  Text(option.explanation)
                    .font(AppFont.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(2)
                }
                Spacer(minLength: 0)
              }
              .foregroundStyle(palette.foreground)
              .padding(.horizontal, AppSpacing.sm)
              .padding(.vertical, AppSpacing.xs + 2)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(choice == option ? palette.accentFill : palette.surface,
                          in: RoundedRectangle(cornerRadius: AppRadius.md))
              .overlay {
                RoundedRectangle(cornerRadius: AppRadius.md)
                  .strokeBorder(choice == option ? palette.borderStrong : palette.border)
              }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(choice == option ? .isSelected : [])
          }
        }
      }
    }
  }

  private var connectStep: some View {
    SettingsCard("Connect your account", caption: "Follow the instructions for the option you selected.") {
      SettingsBlock {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
          if let choice {
            connectionInstructions(for: choice)
          }
          if let error = modelCatalog.error(for: provider) {
            InlineNote(text: "Model list unavailable: \(error). You can retry in the next tab.", kind: .warning)
          }
          HStack(spacing: AppSpacing.sm) {
            Badge(
              text: canGoNext ? (choice == .ollama ? "No key needed" : "Credential saved") : "Needs setup",
              variant: canGoNext ? .success : .warning,
              symbol: canGoNext ? "checkmark" : "exclamationmark"
            )
            Button("Advanced Provider Settings") {
              SettingsNavigation.show(.provider) { openSettings() }
            }
            .appButton(.ghost, size: .sm)
          }
        }
      }
    }
  }

  private var modelStep: some View {
    SettingsCard("Choose a model", caption: "The model is the AI that will answer your translation requests.") {
      SettingsBlock {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
          if let choice { modelPicker(for: choice) }
          if needsEndpoint {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
              Text("Service address").font(AppFont.bodyMedium)
              Text("Copy the API endpoint from your service's instructions. Use HTTPS unless Ollama runs on this Mac.")
                .font(AppFont.caption)
                .foregroundStyle(palette.mutedForeground)
              AppTextField(placeholder: "https://…", text: $settingsStore.settings.provider.endpoint, size: .sm)
            }
          }
          if let error = modelCatalog.error(for: provider) {
            InlineNote(text: "Could not load models: \(error). Retry or enter a model name.", kind: .warning)
          }
          InlineNote(
            text: canContinue
              ? "Settings are saved. The sample translation will check the connection."
              : missingSetupMessage,
            kind: canContinue ? .success : .info
          )
        }
      }
    }
  }

  private var currentChoice: ConnectionChoice {
    if provider.provider == .ollama { return .ollama }
    if provider.provider == .openAI || provider.provider == .chatGPT {
      return isOAuth ? .chatGPT : .openAIKey
    }
    return .otherKey
  }

  @ViewBuilder private func connectionInstructions(for choice: ConnectionChoice) -> some View {
    if choice == .otherKey {
      VStack(alignment: .leading, spacing: AppSpacing.sm) {
        Text("1. Which service gave you the key?").font(AppFont.bodyMedium)
        AppSelect(
          title: "AI service",
          selection: Binding(
            get: { otherProviderSelection },
            set: { selection in
              guard let selection else { return }
              otherProviderSelection = selection
              settingsStore.selectProvider(selection)
              apiKeyDraft = settingsStore.apiKey
              refreshCatalogIfReady()
            }
          ),
          options: ProviderKind.allCases
            .filter { $0 != .openAI && $0 != .chatGPT && $0 != .ollama }
            .map(Optional.some),
          label: { $0?.rawValue ?? "Choose a service" }
        )
        Text("No match? Choose OpenAI-compatible and enter its address on the Model tab.")
          .font(AppFont.caption)
          .foregroundStyle(palette.mutedForeground)
          .fixedSize(horizontal: false, vertical: true)
      }
    }

    if choice == .chatGPT {
      VStack(alignment: .leading, spacing: AppSpacing.sm) {
        Text("1. Sign in to ChatGPT").font(AppFont.bodyMedium)
        Text("Click below, finish sign-in in your browser, then return to PhraseLens.")
          .font(AppFont.caption)
          .foregroundStyle(palette.mutedForeground)
        if let credentials = settingsStore.oauthCredentials, !credentials.accessToken.isEmpty {
          Badge(text: credentials.isExpired ? "Session needs renewal" : "Signed in",
                variant: credentials.isExpired ? .warning : .success,
                symbol: credentials.isExpired ? "exclamationmark" : "checkmark")
          if let email = credentials.email, !email.isEmpty {
            Text(email).font(AppFont.caption).foregroundStyle(palette.secondaryForeground)
          }
        } else if settingsStore.isAuthenticatingOAuth {
          HStack(spacing: AppSpacing.sm) {
            Spinner(size: 14)
            Text("Waiting for browser sign-in…").font(AppFont.caption)
            Button("Cancel") { settingsStore.cancelOAuthLogin() }
              .appButton(.outline, size: .sm)
          }
        } else {
          Button("Sign in with ChatGPT") { settingsStore.startOAuthLogin() }
            .appButton(.primary, size: .md)
        }
        if let error = settingsStore.oauthError { InlineNote(text: error, kind: .error) }
      }
    } else if choice == .ollama {
      VStack(alignment: .leading, spacing: AppSpacing.sm) {
        Text("1. Start Ollama and download a model").font(AppFont.bodyMedium)
        Text("Open Ollama on this Mac and make sure it is running. Download a model there before trying a translation.")
          .font(AppFont.caption)
          .foregroundStyle(palette.mutedForeground)
          .fixedSize(horizontal: false, vertical: true)
        Link("Get Ollama", destination: URL(string: "https://ollama.com/download")!)
          .font(AppFont.captionMedium)
      }
    } else if choice != .otherKey || otherProviderSelection != nil {
      VStack(alignment: .leading, spacing: AppSpacing.sm) {
        Text(choice == .otherKey ? "2. Paste and save your API key" : "1. Paste and save your API key")
          .font(AppFont.bodyMedium)
        if choice == .openAIKey {
          Link("Get an OpenAI Platform API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
            .font(AppFont.captionMedium)
          InlineNote(text: "OpenAI Platform API use has separate billing from a ChatGPT subscription. Your ChatGPT password is not an API key.", kind: .info)
        } else {
          Text("Copy the API key from your service's website and paste it here. Keep the key private.")
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
        }
        HStack(spacing: AppSpacing.sm) {
          AppTextField(placeholder: "Paste API key", text: $apiKeyDraft,
                       isSecure: true, size: .sm, onSubmit: saveKey)
          Button("Save Key") { saveKey() }
            .appButton(.primary, size: .sm)
            .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || !hasUnsavedKey)
        }
        Badge(text: settingsStore.apiKey.isEmpty ? "No key saved" : "Key saved",
              variant: settingsStore.apiKey.isEmpty ? .warning : .success,
              symbol: settingsStore.apiKey.isEmpty ? "exclamationmark" : "checkmark")
        if hasUnsavedKey, !settingsStore.apiKey.isEmpty {
          Button("Keep saved key") { apiKeyDraft = settingsStore.apiKey }
            .appButton(.ghost, size: .sm)
        }
        if let error = settingsStore.credentialError { InlineNote(text: error, kind: .error) }
      }
    }
  }

  private func modelPicker(for choice: ConnectionChoice) -> some View {
    VStack(alignment: .leading, spacing: AppSpacing.sm) {
      Text("Model name")
        .font(AppFont.bodyMedium)
      Text(modelExplanation(for: choice))
        .font(AppFont.caption)
        .foregroundStyle(palette.mutedForeground)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: AppSpacing.sm) {
        SearchableSelect(
          title: "AI model",
          selection: $settingsStore.settings.provider.model,
          options: availableModels,
          placeholder: "Choose a model",
          searchPrompt: "Search or type a model name",
          emptyMessage: "No models loaded. Enter a name from your service.",
          customValueLabel: { "Use “\($0)”" }
        )
        if provider.provider != .azure {
          Button("Reload models") { refreshCatalog() }
            .appButton(.outline, size: .sm)
            .disabled(!settingsStore.hasProviderCredential || modelCatalog.isFetching(provider))
        }
      }
      if modelCatalog.isFetching(provider) {
        Text("Loading available models…").font(AppFont.caption)
          .foregroundStyle(palette.mutedForeground)
      }
    }
  }

  private func modelExplanation(for choice: ConnectionChoice) -> String {
    if choice == .ollama { return "Use the exact name of a model you downloaded in Ollama. The suggested name is only an example." }
    if provider.provider == .azure { return "Enter the deployment name shown in your Azure portal." }
    if choice == .chatGPT { return "After signing in, choose from the models your account provides. You can usually leave the suggested model." }
    return "A starting model is selected. Leave it or choose another model your service provides."
  }

  private var availableModels: [String] {
    var models = modelCatalog.models(for: provider)
    if isOAuth, models.isEmpty { models = CodexBackend.fallbackModels }
    if !provider.model.isEmpty, !models.contains(provider.model) {
      models.insert(provider.model, at: 0)
    }
    return models
  }

  private var missingSetupMessage: String {
    if choice == .otherKey, otherProviderSelection == nil {
      return "Choose your AI service on the Connect tab."
    }
    if hasUnsavedKey { return "Click Save Key before continuing. The new key has not been saved yet." }
    if !settingsStore.hasProviderCredential {
      return choice == .chatGPT ? "Finish signing in to continue." : "Save your API key to continue."
    }
    if provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Choose or enter a model name to continue."
    }
    return "Enter a valid service address to continue. Advanced Provider Settings has more options."
  }

  private func choose(_ choice: ConnectionChoice) {
    let previousChoice = self.choice
    self.choice = choice
    unlockedStep = max(unlockedStep, 1)
    switch choice {
    case .chatGPT, .openAIKey:
      otherProviderSelection = nil
      let openAI: ProviderKind = provider.provider == .chatGPT ? .chatGPT : .openAI
      settingsStore.selectProvider(openAI)
      let mode: AuthenticationMode = choice == .chatGPT ? .oauthCodex : .apiKey
      if provider.authMode != mode {
        settingsStore.settings.provider.authMode = mode
        settingsStore.settings.provider.model = mode == .oauthCodex
          ? CodexBackend.defaultModel : openAI.defaultModel
      }
    case .otherKey:
      if previousChoice != .otherKey {
        otherProviderSelection = nil
      }
    case .ollama:
      otherProviderSelection = nil
      settingsStore.selectProvider(.ollama)
    }
    apiKeyDraft = settingsStore.apiKey
    chooseAvailableOAuthModel()
    refreshCatalogIfReady()
  }

  private func saveKey() {
    let value = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value != settingsStore.apiKey else { return }
    settingsStore.saveAPIKey(value)
    modelCatalog.invalidate(for: provider)
    refreshCatalogIfReady()
  }

  private func refreshCatalogIfReady() {
    guard settingsStore.hasProviderCredential, provider.provider != .azure else { return }
    let configuration = provider
    let store = settingsStore
    modelCatalog.refreshIfStale(configuration: configuration, proxy: settingsStore.settings.proxy) {
      try await store.validToken()
    }
  }

  private func refreshCatalog() {
    guard settingsStore.hasProviderCredential, provider.provider != .azure else { return }
    let configuration = provider
    let store = settingsStore
    modelCatalog.refresh(configuration: configuration, proxy: settingsStore.settings.proxy) {
      try await store.validToken()
    }
  }

  private func chooseAvailableOAuthModel() {
    guard choice == .chatGPT, isOAuth else { return }
    let models = modelCatalog.models(for: provider)
    guard !models.isEmpty, !models.contains(provider.model) else { return }
    settingsStore.settings.provider.model = models[0]
  }

  private var permissionStep: some View {
    SettingsCard("Use text from other apps", caption: "Optional. Typing directly into PhraseLens works without this permission.") {
      SettingsBlock {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
          Text("To translate selected text or replace writing in another app, allow PhraseLens in System Settings → Privacy & Security → Accessibility.")
            .font(AppFont.body)
            .foregroundStyle(palette.secondaryForeground)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: AppSpacing.sm) {
            Badge(
              text: model.isAccessibilityTrusted ? "Granted" : "Not granted",
              variant: model.isAccessibilityTrusted ? .success : .warning,
              symbol: model.isAccessibilityTrusted ? "checkmark" : "exclamationmark"
            )
            if !model.isAccessibilityTrusted {
              Button("Open Accessibility Settings") {
                model.openAccessibilitySettings()
              }
              .appButton(.outline, size: .md)
            }
          }
          HStack(spacing: AppSpacing.sm) {
            InlineNote(text: "Screenshot OCR asks for Screen Recording access when first used.", kind: .info)
            Button("Screen Recording Settings") {
              if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
              }
            }
            .appButton(.outline, size: .sm)
          }
        }
      }
    }
  }

  private var tryStep: some View {
    SettingsCard("Try a translation", caption: "A sample is ready in the translator.") {
      SettingsBlock {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
          Text("Open the translator and press Translate or ⌘↩. A returned result confirms the service responds.")
            .font(AppFont.body)
            .foregroundStyle(palette.secondaryForeground)
            .fixedSize(horizontal: false, vertical: true)
          if !settingsStore.hasBasicProviderConfiguration {
            InlineNote(text: "Finish the connection and model tabs before trying the sample.", kind: .warning)
          }
          Button("Open Translator with Sample") {
            let translationActionID = TranslationAction.builtIns[0].id
            if model.visibleActions.contains(where: { $0.id == translationActionID }) {
              model.selectedActionID = translationActionID
            }
            model.editInputText("Hello, how are you?")
            settingsStore.dismissSetupGuide()
            showTranslator()
          }
          .appButton(.primary, size: .md)
          .disabled(!settingsStore.hasBasicProviderConfiguration)
        }
      }
    }
  }
}
