import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
  @Published var settings: AppSettings {
    didSet { persist() }
  }

  @Published private(set) var apiKey = ""
  @Published private(set) var keychainError: String?
  @Published private(set) var isLoadingAPIKey = false
  @Published private(set) var isSavingAPIKey = false

  private let defaults: UserDefaults
  private let keychain: KeychainStore
  private let settingsKey = "app-settings-v1"
  private let providerConfigurationsKey = "provider-configurations-v1"
  private let selectionCopyMigrationKey = "selection-copy-fallback-v1"
  private var providerConfigurations: [ProviderKind: ProviderConfiguration]
  private var keyLoadID = UUID()
  private var keySaveID = UUID()

  init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
    self.defaults = defaults
    self.keychain = keychain
    if let data = defaults.data(forKey: providerConfigurationsKey),
      let decoded = try? JSONDecoder().decode(
        [ProviderKind: ProviderConfiguration].self,
        from: data
      )
    {
      providerConfigurations = decoded
    } else {
      providerConfigurations = [:]
    }
    if let data = defaults.data(forKey: settingsKey),
      let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
    {
      settings = decoded
    } else {
      settings = AppSettings()
    }
    providerConfigurations[settings.provider.provider] = settings.provider
    if defaults.object(forKey: selectionCopyMigrationKey) == nil {
      settings.useClipboardFallback = true
      defaults.set(true, forKey: selectionCopyMigrationKey)
    }
    loadAPIKey()
  }

  func selectProvider(_ provider: ProviderKind) {
    guard provider != settings.provider.provider else { return }
    providerConfigurations[settings.provider.provider] = settings.provider
    settings.provider = providerConfigurations[provider] ?? ProviderConfiguration(
      provider: provider,
      endpoint: provider.defaultEndpoint,
      model: provider.defaultModel
    )
    persistProviderConfigurations()
    apiKey = ""
    keychainError = nil
    isSavingAPIKey = false
    loadAPIKey()
  }

  func loadAPIKey() {
    let provider = settings.provider.provider
    let keychain = self.keychain
    let requestID = UUID()
    keyLoadID = requestID
    apiKey = ""
    keychainError = nil
    isLoadingAPIKey = true
    Task {
      let result = await Task.detached {
        Result { try keychain.apiKey(for: provider) }
      }.value
      guard requestID == keyLoadID, provider == settings.provider.provider else { return }
      isLoadingAPIKey = false
      switch result {
      case .success(let value):
        apiKey = value
        keychainError = nil
      case .failure(let error):
        apiKey = ""
        keychainError = error.localizedDescription
      }
    }
  }

  func saveAPIKey(_ value: String) {
    let provider = settings.provider.provider
    let keychain = self.keychain
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let requestID = UUID()
    keySaveID = requestID
    isSavingAPIKey = true
    keychainError = nil
    Task {
      let result = await Task.detached {
        Result { try keychain.setAPIKey(trimmedValue, for: provider) }
      }.value
      guard requestID == keySaveID, provider == settings.provider.provider else { return }
      isSavingAPIKey = false
      switch result {
      case .success:
        apiKey = trimmedValue
      case .failure(let error):
        keychainError = error.localizedDescription
      }
    }
  }

  func reset() {
    providerConfigurations = [:]
    defaults.removeObject(forKey: providerConfigurationsKey)
    settings = AppSettings()
    providerConfigurations[settings.provider.provider] = settings.provider
    loadAPIKey()
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: settingsKey)
  }

  private func persistProviderConfigurations() {
    guard let data = try? JSONEncoder().encode(providerConfigurations) else { return }
    defaults.set(data, forKey: providerConfigurationsKey)
  }
}
