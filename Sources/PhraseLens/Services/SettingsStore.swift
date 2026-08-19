import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
  private static let settingsKey = "app-settings-v1"
  private static let providerConfigurationsKey = "provider-configurations-v1"
  private static let selectionCopyMigrationKey = "selection-copy-fallback-v1"

  @Published var settings: AppSettings {
    didSet { persist() }
  }

  @Published private(set) var apiKey = ""
  @Published private(set) var oauthCredentials: OAuthCredentials?
  @Published private(set) var isAuthenticatingOAuth = false
  @Published private(set) var oauthError: String?
  @Published private(set) var credentialError: String?
  @Published private(set) var hasLegacyKeychainCredentials = false
  @Published private(set) var isImportingLegacyCredentials = false

  private let defaults: UserDefaults
  private let credentials: CredentialStore
  private var providerConfigurations: [ProviderKind: ProviderConfiguration]
  private var authTask: Task<Void, Never>?

  init(defaults: UserDefaults = .standard, credentials: CredentialStore = .shared) {
    self.defaults = defaults
    self.credentials = credentials
    if let data = defaults.data(forKey: Self.providerConfigurationsKey),
      let decoded = try? JSONDecoder().decode(
        [ProviderKind: ProviderConfiguration].self,
        from: data
      )
    {
      providerConfigurations = decoded
    } else {
      providerConfigurations = [:]
    }
    if let data = defaults.data(forKey: Self.settingsKey),
      let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
    {
      settings = decoded
    } else {
      settings = AppSettings()
    }
    providerConfigurations[settings.provider.provider] = settings.provider
    if defaults.object(forKey: Self.selectionCopyMigrationKey) == nil {
      settings.useClipboardFallback = true
      defaults.set(true, forKey: Self.selectionCopyMigrationKey)
    }
    loadCredentials()
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
    oauthError = nil
    isAuthenticatingOAuth = false
    loadCredentials()
  }

  /// Credentials come out of an in-memory cache, so switching providers is a
  /// dictionary lookup rather than an authenticated Keychain round trip.
  /// Nothing here touches the Keychain: what an older build left there is
  /// imported only when someone presses the button for it, because that read is
  /// what raises the system password panel.
  func loadCredentials() {
    let provider = settings.provider.provider
    apiKey = credentials.apiKey(for: provider)
    oauthCredentials = credentials.oauthCredentials(for: provider)
    credentialError = nil
    isImportingLegacyCredentials = false
    hasLegacyKeychainCredentials = false
    refreshLegacyKeychainAvailability(for: provider)
  }

  /// Looks for — but does not read — a Keychain entry from an older build. The
  /// lookup is an attribute query, which the Keychain answers silently.
  private func refreshLegacyKeychainAvailability(for provider: ProviderKind) {
    let credentials = self.credentials
    Task.detached(priority: .utility) {
      let available = credentials.hasImportableLegacyCredentials(for: provider)
      guard available else { return }
      await MainActor.run {
        guard provider == self.settings.provider.provider else { return }
        self.hasLegacyKeychainCredentials = true
      }
    }
  }

  /// Pulls this provider's credential out of the login Keychain, at the cost of
  /// the system password panel. Runs off the main thread, since that panel
  /// blocks whichever thread asks.
  func importLegacyKeychainCredentials() {
    guard !isImportingLegacyCredentials else { return }
    let provider = settings.provider.provider
    let credentials = self.credentials
    isImportingLegacyCredentials = true
    credentialError = nil

    Task.detached(priority: .userInitiated) {
      let outcome = credentials.importLegacyKeychainCredentials(for: provider)
      await MainActor.run {
        guard provider == self.settings.provider.provider else { return }
        self.isImportingLegacyCredentials = false
        switch outcome {
        case .imported:
          self.apiKey = credentials.apiKey(for: provider)
          self.oauthCredentials = credentials.oauthCredentials(for: provider)
          self.hasLegacyKeychainCredentials = false
        case .none:
          self.hasLegacyKeychainCredentials = false
        case .unreadable:
          self.credentialError =
            "The Keychain did not release the older \(provider.rawValue) entry. "
            + "Try the import again, or just enter the key above — it is saved outside the Keychain."
        }
      }
    }
  }

  func saveAPIKey(_ value: String) {
    let provider = settings.provider.provider
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      try credentials.setAPIKey(trimmedValue, for: provider)
      apiKey = trimmedValue
      credentialError = nil
    } catch {
      credentialError = error.localizedDescription
    }
  }

  func startOAuthLogin() {
    let provider = settings.provider.provider
    let proxy = settings.proxy
    let credentials = self.credentials

    authTask?.cancel()
    isAuthenticatingOAuth = true
    oauthError = nil

    authTask = Task {
      do {
        let creds = try await OpenAIOAuthService.shared.authenticate(proxy: proxy)
        guard provider == self.settings.provider.provider else { return }
        try credentials.setOAuthCredentials(creds, for: provider)
        self.oauthCredentials = creds
        self.isAuthenticatingOAuth = false
        self.oauthError = nil
      } catch let error as OAuthError where error == .cancelled {
        self.isAuthenticatingOAuth = false
      } catch {
        self.isAuthenticatingOAuth = false
        self.oauthError = error.localizedDescription
      }
    }
  }

  func cancelOAuthLogin() {
    authTask?.cancel()
    authTask = nil
    isAuthenticatingOAuth = false
    Task {
      await OpenAIOAuthService.shared.cancelPending()
    }
  }

  func logoutOAuth() {
    let provider = settings.provider.provider
    authTask?.cancel()
    authTask = nil
    isAuthenticatingOAuth = false
    oauthCredentials = nil
    oauthError = nil
    try? credentials.setOAuthCredentials(nil, for: provider)
  }

  /// Returns a valid credential (API Key or auto-refreshed OAuth access token)
  /// for API calls. OAuth calls also need the account id, which the Codex
  /// backend wants as its own header.
  func validCredentials() async throws -> (accessToken: String, accountId: String?) {
    if settings.provider.provider.supportsOAuth && settings.provider.authMode == .oauthCodex {
      var creds = oauthCredentials
      if creds == nil {
        creds = credentials.oauthCredentials(for: settings.provider.provider)
        if let creds {
          self.oauthCredentials = creds
        }
      }
      guard var validCreds = creds, !validCreds.accessToken.isEmpty else {
        throw TranslationError.missingOAuthCredentials
      }
      if validCreds.isExpired {
        do {
          let refreshed = try await OpenAIOAuthService.shared.refreshCredentials(
            validCreds,
            proxy: settings.proxy
          )
          validCreds = refreshed
          try credentials.setOAuthCredentials(refreshed, for: settings.provider.provider)
          self.oauthCredentials = refreshed
        } catch {
          throw TranslationError.oauthExpired
        }
      }
      return (validCreds.accessToken, validCreds.accountId)
    } else {
      var key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      if key.isEmpty && settings.provider.provider.usesAPIKey {
        let savedKey = credentials.apiKey(for: settings.provider.provider)
        if !savedKey.isEmpty {
          key = savedKey
          self.apiKey = savedKey
        }
      }
      if settings.provider.provider.usesAPIKey, key.isEmpty {
        throw TranslationError.missingAPIKey
      }
      return (key, nil)
    }
  }

  /// Convenience accessor returning only the token/key.
  func validToken() async throws -> String {
    let (key, _) = try await validCredentials()
    return key
  }

  /// Keeps the default action usable from every surface. Choosing a hidden
  /// action as the default makes it visible again rather than persisting a
  /// contradictory configuration.
  func setDefaultAction(_ id: UUID) {
    settings.setDefaultAction(id)
  }

  func resetBuiltInAction(_ id: UUID) {
    settings.resetBuiltInAction(id)
  }

  func resetActionPresentation() {
    settings.resetActionPresentation()
  }

  func reset() {
    providerConfigurations = [:]
    defaults.removeObject(forKey: Self.providerConfigurationsKey)
    settings = AppSettings()
    providerConfigurations[settings.provider.provider] = settings.provider
    loadCredentials()
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: Self.settingsKey)
  }

  private func persistProviderConfigurations() {
    guard let data = try? JSONEncoder().encode(providerConfigurations) else { return }
    defaults.set(data, forKey: Self.providerConfigurationsKey)
  }

}
