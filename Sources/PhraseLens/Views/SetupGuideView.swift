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

    var title: String {
      switch self {
      case .chatGPT: L10n.isChinese ? "我有 ChatGPT 账号" : "I have a ChatGPT account"
      case .openAIKey: L10n.isChinese ? "我有 OpenAI API Key" : "I have an OpenAI API key"
      case .otherKey: L10n.isChinese ? "我有其他大模型平台的 API Key" : "I have an API key from another service"
      case .ollama: L10n.isChinese ? "我在本机运行 Ollama" : "I use Ollama on this Mac"
      }
    }

    var explanation: String {
      switch self {
      case .chatGPT:
        L10n.isChinese
          ? "使用您的 ChatGPT 或 Codex 订阅账号，直接网页登录授权，无需拷贝填写 Key。"
          : "Use your ChatGPT or Codex account. No key to paste."
      case .openAIKey:
        L10n.isChinese
          ? "使用来自 OpenAI 平台的 API 密钥（包括 Codex CLI Key）。"
          : "Use a key from OpenAI Platform, including Codex CLI keys."
      case .otherKey:
        L10n.isChinese
          ? "选择提供 API Key 的服务商（如 DeepSeek、Claude、Gemini、Moonshot 等）。"
          : "Choose the service that issued your key."
      case .ollama:
        L10n.isChinese
          ? "使用本地离线部署的大模型，无需账号或 API 密钥，完全私密。"
          : "Use a local model. No account or API key."
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

  private var tabNames: [String] {
    L10n.isChinese
      ? ["账号", "连接", "模型", "快捷键", "体验"]
      : ["Account", "Connect", "Model", "Shortcuts", "Try it"]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: AppSpacing.md) {
      HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
          Text(L10n.isChinese ? "欢迎配置 PhraseLens" : "Set up PhraseLens")
            .font(AppFont.display)
            .foregroundStyle(palette.foreground)
          Text(L10n.isChinese ? "5 个轻松步骤，开启第一次翻译体验" : "Five small steps to your first translation")
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
        }
        Spacer(minLength: AppSpacing.sm)
        Button(L10n.isChinese ? "暂且跳过" : "Skip for now") {
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
          .accessibilityLabel(
            L10n.isChinese
              ? "第 \(index + 1) 步：\(tabNames[index])"
              : "Step \(index + 1): \(tabNames[index])"
          )
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
          Button(L10n.isChinese ? "上一步" : "Back") { step -= 1 }
            .appButton(.outline, size: .sm)
        }
        if step < tabNames.count - 1 {
          Button(L10n.isChinese ? "下一步：\(tabNames[step + 1])" : "Next: \(tabNames[step + 1])") { goNext() }
            .appButton(.primary, size: .sm)
            .disabled(!canGoNext)
        } else {
          Button(L10n.isChinese ? "开始使用" : "Get started") {
            settingsStore.dismissSetupGuide()
            showTranslator()
          }
          .appButton(.primary, size: .sm)
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
    case 0:
      return choice == nil
        ? (L10n.isChinese ? "请选择一种连接方式" : "Choose one option")
        : (L10n.isChinese ? "稍后也可在设置中更改" : "You can change this later")
    case 1:
      if choice == .otherKey, otherProviderSelection == nil {
        return L10n.isChinese ? "请选择大模型服务商" : "Choose your AI service"
      }
      if hasUnsavedKey {
        return L10n.isChinese ? "保存新密钥后继续" : "Save your new key to continue"
      }
      if choice == .ollama {
        return L10n.isChinese ? "无需密钥；体验前请先启动 Ollama" : "No key needed; start Ollama before trying"
      }
      return settingsStore.hasProviderCredential
        ? (L10n.isChinese ? "凭证已保存在本地" : "Credential saved locally")
        : (L10n.isChinese ? "请登录或保存密钥" : "Sign in or save a key")
    case 2:
      return canContinue
        ? (L10n.isChinese ? "已就绪，可体验测试翻译" : "Ready for a test translation")
        : missingSetupMessage
    case 3:
      return L10n.isChinese ? "此权限为可选项" : "This permission is optional"
    default:
      return L10n.isChinese ? "返回结果即代表连接成功" : "A result will confirm the connection"
    }
  }

  private func goNext() {
    guard canGoNext, step < tabNames.count - 1 else { return }
    unlockedStep = max(unlockedStep, step + 1)
    step += 1
  }

  private var accountStep: some View {
    SettingsCard(
      L10n.isChinese ? "选择连接大模型的方式" : "Choose how you want to connect to AI",
      caption: L10n.isChinese
        ? "ChatGPT 账号与 OpenAI 平台 API Key 采用不同的登录授权方式。"
        : "ChatGPT accounts and OpenAI Platform API keys use different sign-in methods."
    ) {
      SettingsBlock {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
          ForEach(ConnectionChoice.allCases) { option in
            Button { choose(option) } label: {
              HStack(alignment: .center, spacing: AppSpacing.sm) {
                Image(systemName: choice == option ? "largecircle.fill.circle" : "circle")
                  .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                  Text(option.title).font(AppFont.bodyMedium)
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
    SettingsCard(
      L10n.isChinese ? "连接您的账号" : "Connect your account",
      caption: L10n.isChinese
        ? "根据所选连接方式完成以下指引。"
        : "Follow the instructions for the option you selected."
    ) {
      SettingsBlock {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
          if let choice {
            connectionInstructions(for: choice)
          }
          if let error = modelCatalog.error(for: provider) {
            InlineNote(
              text: L10n.isChinese
                ? "模型列表不可用：\(error)。您可以在下一个标签页重试。"
                : "Model list unavailable: \(error). You can retry in the next tab.",
              kind: .warning
            )
          }
          HStack(spacing: AppSpacing.sm) {
            Badge(
              text: canGoNext
                ? (choice == .ollama ? (L10n.isChinese ? "无需密钥" : "No key needed") : (L10n.isChinese ? "凭证已保存" : "Credential saved"))
                : (L10n.isChinese ? "需要配置" : "Needs setup"),
              variant: canGoNext ? .success : .warning,
              symbol: canGoNext ? "checkmark" : "exclamationmark"
            )
            Button(L10n.isChinese ? "高级服务商设置" : "Advanced Provider Settings") {
              SettingsNavigation.show(.provider) { openSettings() }
            }
            .appButton(.ghost, size: .sm)
          }
        }
      }
    }
  }

  private var modelStep: some View {
    SettingsCard(
      L10n.isChinese ? "选择模型" : "Choose a model",
      caption: L10n.isChinese
        ? "模型是负责响应和处理翻译请求的 AI。"
        : "The model is the AI that will answer your translation requests."
    ) {
      SettingsBlock {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
          if let choice { modelPicker(for: choice) }
          if needsEndpoint {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
              Text(L10n.isChinese ? "服务地址" : "Service address").font(AppFont.bodyMedium)
              Text(L10n.isChinese
                ? "从服务商指引中拷贝 API 接口地址。除非在本地运行 Ollama，否则请使用 HTTPS。"
                : "Copy the API endpoint from your service's instructions. Use HTTPS unless Ollama runs on this Mac.")
                .font(AppFont.caption)
                .foregroundStyle(palette.mutedForeground)
              AppTextField(placeholder: "https://…", text: $settingsStore.settings.provider.endpoint, size: .sm)
            }
          }
          if let error = modelCatalog.error(for: provider) {
            InlineNote(
              text: L10n.isChinese
                ? "无法加载模型列表：\(error)。请重试或直接输入模型名称。"
                : "Could not load models: \(error). Retry or enter a model name.",
              kind: .warning
            )
          }
          InlineNote(
            text: canContinue
              ? (L10n.isChinese ? "设置已保存。样例翻译将检测连接状态。" : "Settings are saved. The sample translation will check the connection.")
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
        Text(L10n.isChinese ? "1. 请选择提供 API Key 的服务商" : "1. Which service gave you the key?")
          .font(AppFont.bodyMedium)
        AppSelect(
          title: L10n.isChinese ? "大模型服务" : "AI service",
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
          label: { $0?.rawValue ?? (L10n.isChinese ? "选择服务商" : "Choose a service") }
        )
        Text(L10n.isChinese
          ? "未找到对应服务商？请选择 OpenAI-compatible 并在“模型”页填写其服务地址。"
          : "No match? Choose OpenAI-compatible and enter its address on the Model tab.")
          .font(AppFont.caption)
          .foregroundStyle(palette.mutedForeground)
          .fixedSize(horizontal: false, vertical: true)
      }
    }

    if choice == .chatGPT {
      VStack(alignment: .leading, spacing: AppSpacing.sm) {
        Text(L10n.isChinese ? "1. 登录 ChatGPT" : "1. Sign in to ChatGPT")
          .font(AppFont.bodyMedium)
        Text(L10n.isChinese
          ? "点击下方按钮，在浏览器中完成登录授权，然后返回 PhraseLens。"
          : "Click below, finish sign-in in your browser, then return to PhraseLens.")
          .font(AppFont.caption)
          .foregroundStyle(palette.mutedForeground)
        if let credentials = settingsStore.oauthCredentials, !credentials.accessToken.isEmpty {
          Badge(
            text: credentials.isExpired
              ? (L10n.isChinese ? "会话需要刷新" : "Session needs renewal")
              : (L10n.isChinese ? "已登录" : "Signed in"),
            variant: credentials.isExpired ? .warning : .success,
            symbol: credentials.isExpired ? "exclamationmark" : "checkmark"
          )
          if let email = credentials.email, !email.isEmpty {
            Text(email).font(AppFont.caption).foregroundStyle(palette.secondaryForeground)
          }
        } else if settingsStore.isAuthenticatingOAuth {
          HStack(spacing: AppSpacing.sm) {
            Spinner(size: 14)
            Text(L10n.isChinese ? "等待浏览器登录完成…" : "Waiting for browser sign-in…")
              .font(AppFont.caption)
            Button(L10n.isChinese ? "取消" : "Cancel") { settingsStore.cancelOAuthLogin() }
              .appButton(.outline, size: .sm)
          }
        } else {
          Button(L10n.isChinese ? "登录 ChatGPT" : "Sign in with ChatGPT") {
            settingsStore.startOAuthLogin()
          }
          .appButton(.primary, size: .md)
        }
        if let error = settingsStore.oauthError { InlineNote(text: error, kind: .error) }
      }
    } else if choice == .ollama {
      VStack(alignment: .leading, spacing: AppSpacing.sm) {
        Text(L10n.isChinese ? "1. 启动 Ollama 并下载模型" : "1. Start Ollama and download a model")
          .font(AppFont.bodyMedium)
        Text(L10n.isChinese
          ? "在 Mac 上打开 Ollama 并确保其正在运行。在尝试翻译前，请先在其中下载一个模型。"
          : "Open Ollama on this Mac and make sure it is running. Download a model there before trying a translation.")
          .font(AppFont.caption)
          .foregroundStyle(palette.mutedForeground)
          .fixedSize(horizontal: false, vertical: true)
        Link(L10n.isChinese ? "获取 Ollama" : "Get Ollama", destination: URL(string: "https://ollama.com/download")!)
          .font(AppFont.captionMedium)
      }
    } else if choice != .otherKey || otherProviderSelection != nil {
      VStack(alignment: .leading, spacing: AppSpacing.sm) {
        Text(choice == .otherKey
          ? (L10n.isChinese ? "2. 粘贴并保存您的 API Key" : "2. Paste and save your API key")
          : (L10n.isChinese ? "1. 粘贴并保存您的 API Key" : "1. Paste and save your API key"))
          .font(AppFont.bodyMedium)
        if choice == .openAIKey {
          Link(L10n.isChinese ? "获取 OpenAI 平台 API Key" : "Get an OpenAI Platform API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
            .font(AppFont.captionMedium)
          InlineNote(
            text: L10n.isChinese
              ? "OpenAI 平台 API 为独立计费，与 ChatGPT 订阅账号不通用。您的 ChatGPT 密码不是 API Key。"
              : "OpenAI Platform API use has separate billing from a ChatGPT subscription. Your ChatGPT password is not an API key.",
            kind: .info
          )
        } else {
          Text(L10n.isChinese
            ? "从服务商网站拷贝 API Key 并粘贴到此处。请妥善保管您的密钥。"
            : "Copy the API key from your service's website and paste it here. Keep the key private.")
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
        }
        HStack(spacing: AppSpacing.sm) {
          AppTextField(
            placeholder: L10n.isChinese ? "粘贴 API Key" : "Paste API key",
            text: $apiKeyDraft,
            isSecure: true,
            size: .sm,
            onSubmit: saveKey
          )
          Button(L10n.isChinese ? "保存密钥" : "Save Key") { saveKey() }
            .appButton(.primary, size: .sm)
            .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || !hasUnsavedKey)
        }
        Badge(
          text: settingsStore.apiKey.isEmpty
            ? (L10n.isChinese ? "未保存密钥" : "No key saved")
            : (L10n.isChinese ? "密钥已保存" : "Key saved"),
          variant: settingsStore.apiKey.isEmpty ? .warning : .success,
          symbol: settingsStore.apiKey.isEmpty ? "exclamationmark" : "checkmark"
        )
        if hasUnsavedKey, !settingsStore.apiKey.isEmpty {
          Button(L10n.isChinese ? "保留已保存的密钥" : "Keep saved key") { apiKeyDraft = settingsStore.apiKey }
            .appButton(.ghost, size: .sm)
        }
        if let error = settingsStore.credentialError { InlineNote(text: error, kind: .error) }
      }
    }
  }

  private func modelPicker(for choice: ConnectionChoice) -> some View {
    VStack(alignment: .leading, spacing: AppSpacing.sm) {
      Text(L10n.isChinese ? "模型名称" : "Model name")
        .font(AppFont.bodyMedium)
      Text(modelExplanation(for: choice))
        .font(AppFont.caption)
        .foregroundStyle(palette.mutedForeground)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: AppSpacing.sm) {
        SearchableSelect(
          title: L10n.isChinese ? "AI 模型" : "AI model",
          selection: $settingsStore.settings.provider.model,
          options: availableModels,
          placeholder: L10n.isChinese ? "选择模型" : "Choose a model",
          searchPrompt: L10n.isChinese ? "搜索或输入模型名称" : "Search or type a model name",
          emptyMessage: L10n.isChinese ? "未加载到模型。请输入服务商提供的模型名称。" : "No models loaded. Enter a name from your service.",
          customValueLabel: { L10n.isChinese ? "使用“\($0)”" : "Use “\($0)”" }
        )
        if provider.provider != .azure {
          Button(L10n.isChinese ? "重新加载模型" : "Reload models") { refreshCatalog() }
            .appButton(.outline, size: .sm)
            .disabled(!settingsStore.hasProviderCredential || modelCatalog.isFetching(provider))
        }
      }
      if modelCatalog.isFetching(provider) {
        Text(L10n.isChinese ? "正在加载可用模型…" : "Loading available models…").font(AppFont.caption)
          .foregroundStyle(palette.mutedForeground)
      }
    }
  }

  private func modelExplanation(for choice: ConnectionChoice) -> String {
    if choice == .ollama {
      return L10n.isChinese
        ? "请输入在 Ollama 中下载的模型确切名称。推荐名称仅供参考。"
        : "Use the exact name of a model you downloaded in Ollama. The suggested name is only an example."
    }
    if provider.provider == .azure {
      return L10n.isChinese
        ? "请输入 Azure 门户中显示的部署名称。"
        : "Enter the deployment name shown in your Azure portal."
    }
    if choice == .chatGPT {
      return L10n.isChinese
        ? "登录后，可从账号支持的模型中选择。通常保留推荐模型即可。"
        : "After signing in, choose from the models your account provides. You can usually leave the suggested model."
    }
    return L10n.isChinese
      ? "已预选默认模型。您可以保留它，或选择服务商提供的其他模型。"
      : "A starting model is selected. Leave it or choose another model your service provides."
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
      return L10n.isChinese ? "请在“连接”标签页中选择您的大模型服务商。" : "Choose your AI service on the Connect tab."
    }
    if hasUnsavedKey {
      return L10n.isChinese ? "继续前请点击“保存密钥”。新密钥尚未保存。" : "Click Save Key before continuing. The new key has not been saved yet."
    }
    if !settingsStore.hasProviderCredential {
      return choice == .chatGPT
        ? (L10n.isChinese ? "请完成网页登录以继续。" : "Finish signing in to continue.")
        : (L10n.isChinese ? "请保存您的 API Key 以继续。" : "Save your API key to continue.")
    }
    if provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return L10n.isChinese ? "请选择或输入模型名称以继续。" : "Choose or enter a model name to continue."
    }
    return L10n.isChinese
      ? "请输入有效的服务地址以继续。“高级服务商设置”中包含更多选项。"
      : "Enter a valid service address to continue. Advanced Provider Settings has more options."
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
    SettingsCard(
      L10n.isChinese ? "跨应用划词与快捷键" : "Use text from other apps",
      caption: L10n.isChinese
        ? "可选设置。直接在 PhraseLens 主窗口中输入查词无需此权限。"
        : "Optional. Typing directly into PhraseLens works without this permission."
    ) {
      SettingsBlock {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
          Text(L10n.isChinese
            ? "要在其他应用中直接划选文字查词翻译或润色替换，请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 PhraseLens。"
            : "To translate selected text or replace writing in another app, allow PhraseLens in System Settings → Privacy & Security → Accessibility.")
            .font(AppFont.body)
            .foregroundStyle(palette.secondaryForeground)
            .fixedSize(horizontal: false, vertical: true)
          VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.xs) {
              Text("⌥F")
                .font(AppFont.captionMedium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.sm).strokeBorder(palette.border))
              Text(L10n.isChinese
                ? "在任何应用中划选文字后按下，即可呼出快速翻译浮窗"
                : "Select text in any app and press ⌥F to translate immediately")
                .font(AppFont.caption)
                .foregroundStyle(palette.secondaryForeground)
            }
            HStack(spacing: AppSpacing.xs) {
              Text("⌥S")
                .font(AppFont.captionMedium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.sm).strokeBorder(palette.border))
              Text(L10n.isChinese
                ? "截屏识别并翻译屏幕上的任意区域（首次使用需屏幕录制权限）"
                : "Capture and translate any screen area with OCR (requires screen recording)")
                .font(AppFont.caption)
                .foregroundStyle(palette.secondaryForeground)
            }
          }
          HStack(spacing: AppSpacing.sm) {
            Badge(
              text: model.isAccessibilityTrusted
                ? (L10n.isChinese ? "已授权" : "Granted")
                : (L10n.isChinese ? "未授权" : "Not granted"),
              variant: model.isAccessibilityTrusted ? .success : .warning,
              symbol: model.isAccessibilityTrusted ? "checkmark" : "exclamationmark"
            )
            if !model.isAccessibilityTrusted {
              Button(L10n.isChinese ? "打开辅助功能设置" : "Open Accessibility Settings") {
                model.openAccessibilitySettings()
              }
              .appButton(.outline, size: .md)
            }
          }
          HStack(spacing: AppSpacing.sm) {
            InlineNote(
              text: L10n.isChinese
                ? "截屏识别（⌥S）在首次使用时会申请“屏幕录制”权限。"
                : "Screenshot OCR asks for Screen Recording access when first used.",
              kind: .info
            )
            Button(L10n.isChinese ? "屏幕录制设置" : "Screen Recording Settings") {
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
    SettingsCard(
      L10n.isChinese ? "体验翻译" : "Try a translation",
      caption: L10n.isChinese ? "已在翻译器中为您准备了样例。" : "A sample is ready in the translator."
    ) {
      SettingsBlock {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
          Text(L10n.isChinese
            ? "打开翻译器并点击“翻译”或按下 ⌘↩。返回翻译结果即表明大模型连接成功。"
            : "Open the translator and press Translate or ⌘↩. A returned result confirms the service responds.")
            .font(AppFont.body)
            .foregroundStyle(palette.secondaryForeground)
            .fixedSize(horizontal: false, vertical: true)
          if !settingsStore.hasBasicProviderConfiguration {
            InlineNote(
              text: L10n.isChinese
                ? "在体验样例前，请先在“连接”和“模型”标签页完成基本配置。"
                : "Finish the connection and model tabs before trying the sample.",
              kind: .warning
            )
          }
          Button(L10n.isChinese ? "使用样例进入翻译器" : "Open Translator with Sample") {
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
