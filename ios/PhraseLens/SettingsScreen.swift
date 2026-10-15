import SwiftUI

/// The model connection and the answer language. One connection serves every
/// action; an action can still pick its own model.
struct SettingsScreen: View {
  @EnvironmentObject private var store: MobileSettingsStore
  @State private var apiKey = ""
  @State private var loadedKeyFor: ProviderKind?
  @State private var test: ConnectionTest = .idle

  private enum ConnectionTest: Equatable {
    case idle
    case running
    case passed(String)
    case failed(String)
  }

  /// Ollama listens on the computer it runs on, which a phone cannot reach as
  /// loopback, and the HTTPS rule keeps it off the LAN.
  private static let providers = ProviderKind.allCases.filter { $0 != .ollama }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker(L10n.isChinese ? "服务商" : "Provider", selection: providerBinding) {
            ForEach(Self.providers) { provider in
              Text(provider.rawValue).tag(provider)
            }
          }
          LabeledContent(L10n.isChinese ? "接口地址" : "Endpoint") {
            TextField("https://…", text: $store.settings.provider.endpoint)
              .multilineTextAlignment(.trailing)
              .keyboardType(.URL)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          }
          LabeledContent(
            store.settings.provider.provider == .azure
              ? (L10n.isChinese ? "部署名称" : "Deployment") : (L10n.isChinese ? "模型" : "Model")
          ) {
            TextField(store.settings.provider.provider.defaultModel, text: $store.settings.provider.model)
              .multilineTextAlignment(.trailing)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          }
          if store.settings.provider.provider == .azure {
            LabeledContent("API Version") {
              TextField("2024-10-21", text: $store.settings.provider.apiVersion)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
          }
          LabeledContent("API Key") {
            SecureField(L10n.isChinese ? "必填" : "Required", text: $apiKey)
              .multilineTextAlignment(.trailing)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .onSubmit(saveKey)
          }
          if store.settings.provider.provider == .anthropic {
            Toggle(
              L10n.isChinese ? "扩展思考" : "Extended thinking",
              isOn: $store.settings.provider.extendedThinking
            )
          }
        } header: {
          Text(L10n.isChinese ? "模型连接" : "Model Connection")
        } footer: {
          Text(
            L10n.isChinese
              ? "API Key 只保存在这台设备的钥匙串里，App 和“共享”里的 PhraseLens 共用它。"
              : "The API key stays in this device's Keychain, shared only by the app and its Share sheet action."
          )
        }

        Section {
          Button {
            runTest()
          } label: {
            HStack {
              Text(L10n.isChinese ? "测试连接" : "Test Connection")
              Spacer()
              switch test {
              case .idle: EmptyView()
              case .running: ProgressView()
              case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
              case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
              }
            }
          }
          .disabled(test == .running)
          switch test {
          case .passed(let reply):
            Text(reply).font(.footnote).foregroundStyle(.secondary)
          case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(.red)
          default:
            EmptyView()
          }
        }

        Section(L10n.isChinese ? "语言" : "Language") {
          Picker(L10n.isChinese ? "翻译成" : "Translate into", selection: $store.settings.targetLanguage) {
            ForEach(LanguageCode.allCases.filter { $0 != .auto }) { language in
              Text(language.displayName).tag(language)
            }
          }
        }

        Section {
          LabeledContent(L10n.isChinese ? "版本" : "Version", value: Self.version)
        }
      }
      .navigationTitle(L10n.isChinese ? "设置" : "Settings")
      .onAppear(perform: loadKey)
      .onChange(of: store.settings.provider.provider) { _, _ in loadKey() }
      .onChange(of: apiKey) { _, _ in saveKey() }
    }
  }

  /// Switching provider starts from that provider's own endpoint and model,
  /// since the previous provider's values would not work there.
  private var providerBinding: Binding<ProviderKind> {
    Binding {
      store.settings.provider.provider
    } set: { provider in
      guard provider != store.settings.provider.provider else { return }
      store.settings.provider = ProviderConfiguration(
        provider: provider,
        endpoint: provider.defaultEndpoint,
        model: provider.defaultModel
      )
      test = .idle
    }
  }

  private func loadKey() {
    let provider = store.settings.provider.provider
    loadedKeyFor = provider
    apiKey = MobileCredentials.apiKey(for: provider)
  }

  private func saveKey() {
    let provider = store.settings.provider.provider
    // The key on screen belongs to the provider it was loaded for; a save
    // that races a provider switch must not file it under the new one.
    guard loadedKeyFor == provider else { return }
    MobileCredentials.setAPIKey(apiKey, for: provider)
    test = .idle
  }

  private func runTest() {
    saveKey()
    test = .running
    let configuration = store.settings.provider
    let key = MobileCredentials.apiKey(for: configuration.provider)
    let prompt = PromptBuilder.build(
      text: "hello",
      source: .english,
      target: store.settings.targetLanguage,
      action: TranslationAction.builtIn(for: .translate)
    )
    Task {
      var reply = ""
      do {
        for try await chunk in TranslationClient().stream(
          prompt: prompt, configuration: configuration, apiKey: key, proxy: ProxySettings()
        ) {
          reply += chunk
        }
        test = .passed("hello → \(reply.trimmingCharacters(in: .whitespacesAndNewlines))")
      } catch {
        test = .failed(error.localizedDescription)
      }
    }
  }

  private static var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }
}
