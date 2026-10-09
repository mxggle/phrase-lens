import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
  private static let settingsKey = "app-settings-v1"
  private static let providerConfigurationsKey = "provider-configurations-v1"
  private static let selectionCopyMigrationKey = "selection-copy-fallback-v1"
  private static let setupGuideKey = "setup-guide-dismissed-v1"

  @Published var settings: AppSettings {
    didSet {
      if oldValue.appLanguage != settings.appLanguage {
        L10n.shared.setLanguage(settings.appLanguage)
      }
      synchronizeEditedConnection()
      persist()
    }
  }

  @Published private(set) var apiKey = ""
  @Published private(set) var oauthCredentials: OAuthCredentials?
  @Published private(set) var isAuthenticatingOAuth = false
  @Published private(set) var oauthError: String?
  @Published private(set) var credentialError: String?
  @Published private(set) var hasLegacyKeychainCredentials = false
  @Published private(set) var isImportingLegacyCredentials = false
  @Published private(set) var shouldShowSetupGuide: Bool

  private let defaults: UserDefaults
  private let credentials: CredentialStore
  private let refreshOAuth: @Sendable (OAuthCredentials, ProxySettings) async throws -> OAuthCredentials
  private var providerConfigurations: [ProviderKind: ProviderConfiguration]
  @Published private(set) var editingConnectionID: UUID?
  private struct RefreshIdentity: Hashable {
    var connectionID: UUID
    var credentialRevision: UUID
    var configuration: ProviderConfiguration
    var proxy: ProxySettings
  }
  private var refreshTasks: [RefreshIdentity: Task<OAuthCredentials, Error>] = [:]
  private var authGeneration = UUID()
  private var authTask: Task<Void, Never>?

  init(defaults: UserDefaults = .standard, credentials: CredentialStore = .shared, loadStoredCredentials: Bool = true, refreshOAuth: @escaping @Sendable (OAuthCredentials, ProxySettings) async throws -> OAuthCredentials = { try await OpenAIOAuthService.shared.refreshCredentials($0, proxy: $1) }) {
    self.defaults = defaults
    self.credentials = credentials
    self.refreshOAuth = refreshOAuth
    // Existing installations already have a settings document. Only a genuinely
    // new installation opens the guide automatically; everyone can reopen it.
    shouldShowSetupGuide = defaults.data(forKey: Self.settingsKey) == nil
      && !defaults.bool(forKey: Self.setupGuideKey)
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
    if settings.connections.isEmpty {
      let configs = [settings.provider] + providerConfigurations.values.filter { $0.provider != settings.provider.provider }
      let migrated = configs.map { AIConnection(name: $0.provider.rawValue, configuration: $0) }
      // Credentials must be copied successfully before publishing migrated settings.
      do {
        if loadStoredCredentials {
          try credentials.migrateCredentials(to: migrated)
        }
        settings.connections = migrated
        settings.defaultConnectionID = migrated.first?.id
        settings.legacyRoutingConnectionID = migrated.first?.id
        settings.defaultModel = settings.provider.model
        for index in settings.builtInActionOverrides.indices {
          migrateAction(&settings.builtInActionOverrides[index])
        }
        persist()
      } catch { credentialError = error.localizedDescription }
    }
    editingConnectionID = settings.defaultConnectionID
    if let connection = settings.connections.first(where: { $0.id == editingConnectionID }) {
      var configuration = connection.configuration
      configuration.catalogIdentity = connection.id.uuidString + "|" + connection.credentialRevision.uuidString
      settings.provider = configuration
    }
    if loadStoredCredentials { loadCredentials() }
    L10n.shared.setLanguage(settings.appLanguage)
  }

  var resolvedLocale: Locale {
    if let id = settings.appLanguage.localeIdentifier {
      return Locale(identifier: id)
    }
    return Locale.current
  }

  var hasProviderCredential: Bool {
    let provider = settings.provider
    if provider.provider == .ollama { return true }
    if provider.provider.supportsOAuth && provider.authMode == .oauthCodex {
      return !(oauthCredentials?.accessToken.isEmpty ?? true)
    }
    return !apiKey.isEmpty
  }

  var hasBasicProviderConfiguration: Bool {
    guard hasProviderCredential,
      !settings.provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return false }
    let provider = settings.provider
    if provider.provider.supportsOAuth && provider.authMode == .oauthCodex { return true }
    return (try? EndpointValidator.validate(provider.endpoint, provider: provider.provider)) != nil
  }

  func hasCredential(for connection: AIConnection) -> Bool {
    let configuration = connection.configuration
    if configuration.provider.supportsOAuth && configuration.authMode == .oauthCodex {
      return !(credentials.oauthCredentials(for: connection.id)?.accessToken.isEmpty ?? true)
    }
    return !configuration.provider.usesAPIKey || !credentials.apiKey(for: connection.id).isEmpty
  }

  func isConfigured(_ action: TranslationAction) -> Bool {
    guard let (connection, configuration) = try? resolve(action),
      !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    if configuration.provider.supportsOAuth && configuration.authMode == .oauthCodex {
      return !(credentials.oauthCredentials(for: connection.id)?.accessToken.isEmpty ?? true)
    }
    return (!configuration.provider.usesAPIKey || !credentials.apiKey(for: connection.id).isEmpty)
      && (try? EndpointValidator.validate(configuration.endpoint, provider: configuration.provider)) != nil
  }

  func dismissSetupGuide() {
    defaults.set(true, forKey: Self.setupGuideKey)
    shouldShowSetupGuide = false
  }

  func selectProvider(_ provider: ProviderKind) {
    guard provider != settings.provider.provider else { return }
    if let existing = settings.connections.first(where: { $0.configuration.provider == provider }) { selectConnection(existing.id) }
    else { addConnection(provider: provider) }
  }

  private func synchronizeEditedConnection() {
    guard let index = settings.connections.firstIndex(where: { $0.id == editingConnectionID }) else { return }
    var configuration = settings.provider
    configuration.catalogIdentity = nil
    guard configuration != settings.connections[index].configuration else { return }
    settings.connections[index].configuration = configuration
    if editingConnectionID == settings.defaultConnectionID { settings.defaultModel = configuration.model }
  }

  func selectConnection(_ id: UUID) {
    guard let connection = settings.connections.first(where: { $0.id == id }) else { return }
    editingConnectionID = id
    var configuration = connection.configuration
    configuration.catalogIdentity = connection.id.uuidString + "|" + connection.credentialRevision.uuidString
    settings.provider = configuration
    loadCredentials()
  }

  @discardableResult func addConnection(provider: ProviderKind = .openAI) -> UUID {
    let count = settings.connections.filter { $0.configuration.provider == provider }.count
    let name = count == 0 ? provider.rawValue : "\(provider.rawValue) \(count + 1)"
    let connection = AIConnection(name: name, configuration: ProviderConfiguration(provider: provider, endpoint: provider.defaultEndpoint, model: provider.defaultModel))
    settings.connections.append(connection)
    selectConnection(connection.id)
    return connection.id
  }

  func makeDefault(_ id: UUID) {
    guard let connection = settings.connections.first(where: { $0.id == id }) else { return }
    settings.defaultConnectionID = id
    settings.defaultModel = connection.configuration.model
  }

  func deleteConnection(_ id: UUID, actions: [TranslationAction]) -> String? {
    var references = actions.filter { $0.route?.connectionID == id }.map(\.name)
    if settings.defaultConnectionID == id { references.insert(L10n.isChinese ? "全局默认" : "Global default", at: 0) }
    guard references.isEmpty else { return (L10n.isChinese ? "仍在使用：" : "Still used by: ") + references.joined(separator: ", ") }
    settings.connections.removeAll { $0.id == id }
    if editingConnectionID == id, let next = settings.connections.first { selectConnection(next.id) }
    return nil
  }

  func migrateAction(_ action: inout TranslationAction) {
    guard action.routingVersion == nil else { return }
    action.routingVersion = 1
    guard action.route == nil, let id = settings.legacyRoutingConnectionID,
      let configuration = settings.connections.first(where: { $0.id == id })?.configuration,
      let model = action.modelOverride(for: configuration) else { return }
    action.route = ActionRoute(connectionID: id, model: model)
  }

  func resolve(_ action: TranslationAction) throws -> (AIConnection, ProviderConfiguration) {
    let id = action.route?.connectionID ?? settings.defaultConnectionID
    guard let connection = settings.connections.first(where: { $0.id == id }) else {
      throw NSError(domain: "AIConnections", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.isChinese ? "请选择可用的 AI 连接。" : "Choose an available AI connection."])
    }
    var configuration = connection.configuration
    configuration.catalogIdentity = connection.id.uuidString + "|" + connection.credentialRevision.uuidString
    configuration.model = action.route?.model ?? settings.defaultModel ?? configuration.model
    return (connection, configuration)
  }

  /// Credentials come out of an in-memory cache, so switching providers is a
  /// dictionary lookup rather than an authenticated Keychain round trip.
  /// Nothing here touches the Keychain: what an older build left there is
  /// imported only when someone presses the button for it, because that read is
  /// what raises the system password panel.
  func loadCredentials() {
    let provider = settings.provider.provider
    apiKey = credentials.apiKey(for: self.editingConnectionID ?? UUID())
    oauthCredentials = credentials.oauthCredentials(for: self.editingConnectionID ?? UUID())
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
    let connectionID = editingConnectionID
    let credentials = self.credentials
    isImportingLegacyCredentials = true
    credentialError = nil

    Task.detached(priority: .userInitiated) {
      let outcome = credentials.importLegacyKeychainCredentials(for: provider)
      await MainActor.run {
        if let connectionID { try? credentials.migrateCredentials(for: provider, to: connectionID); self.bumpCredentialRevision(connectionID) }
        guard connectionID == self.editingConnectionID else { return }
        self.isImportingLegacyCredentials = false
        switch outcome {
        case .imported:
          self.apiKey = credentials.apiKey(for: self.editingConnectionID ?? UUID())
          self.oauthCredentials = credentials.oauthCredentials(for: self.editingConnectionID ?? UUID())
          self.hasLegacyKeychainCredentials = false
        case .none:
          self.hasLegacyKeychainCredentials = false
        case .unreadable:
          self.credentialError =
            L10n.isChinese
              ? "钥匙串未返回旧版 \(provider.rawValue) 凭据。请重试导入，或直接在上方输入密钥（新密钥会保存在钥匙串之外）。"
              : "The Keychain did not release the older \(provider.rawValue) entry. Try the import again, or just enter the key above — it is saved outside the Keychain."
        }
      }
    }
  }

  func saveAPIKey(_ value: String) {
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      guard let id = editingConnectionID else { return }
      try credentials.setAPIKey(trimmedValue, for: id)
      bumpCredentialRevision(id)
      apiKey = trimmedValue
      credentialError = nil
    } catch {
      credentialError = error.localizedDescription
    }
  }

  func startOAuthLogin() {
    let connectionID = editingConnectionID
    let proxy = settings.proxy
    let credentials = self.credentials

    authTask?.cancel()
    authGeneration = UUID()
    let generation = authGeneration
    let originalConnection = settings.connections.first { $0.id == connectionID }
    isAuthenticatingOAuth = true
    oauthError = nil

    authTask = Task {
      defer { if self.authGeneration == generation { self.isAuthenticatingOAuth = false } }
      do {
        let creds = try await OpenAIOAuthService.shared.authenticate(proxy: proxy)
        guard !Task.isCancelled, self.authGeneration == generation, let connectionID,
          let originalConnection, self.settings.connections.contains(originalConnection) else { return }
        try credentials.setOAuthCredentials(creds, for: connectionID)
        self.bumpCredentialRevision(connectionID)
        guard connectionID == self.editingConnectionID else { return }
        self.oauthCredentials = creds
        self.isAuthenticatingOAuth = false
        self.oauthError = nil
      } catch let error as OAuthError where error == .cancelled {
        guard self.authGeneration == generation else { return }
        self.isAuthenticatingOAuth = false
      } catch {
        guard self.authGeneration == generation else { return }
        self.isAuthenticatingOAuth = false
        self.oauthError = error.localizedDescription
      }
    }
  }

  func cancelOAuthLogin() {
    authGeneration = UUID()
    authTask?.cancel()
    authTask = nil
    isAuthenticatingOAuth = false
    Task {
      await OpenAIOAuthService.shared.cancelPending()
    }
  }

  func logoutOAuth() {
    authGeneration = UUID()
    authTask?.cancel()
    authTask = nil
    isAuthenticatingOAuth = false
    oauthCredentials = nil
    oauthError = nil
    if let id = editingConnectionID { try? credentials.setOAuthCredentials(nil, for: id); bumpCredentialRevision(id) }
  }

  /// Returns a valid credential (API Key or auto-refreshed OAuth access token)
  /// for API calls. OAuth calls also need the account id, which the Codex
  /// backend wants as its own header.
  private func bumpCredentialRevision(_ id: UUID) {
    for (identity, task) in refreshTasks where identity.connectionID == id { task.cancel() }
    if let index = settings.connections.firstIndex(where: { $0.id == id }) {
      settings.connections[index].credentialRevision = UUID()
      if editingConnectionID == id { settings.provider.catalogIdentity = id.uuidString + "|" + settings.connections[index].credentialRevision.uuidString }
    }
  }

  func validCredentials() async throws -> (accessToken: String, accountId: String?) {
    guard let connection = settings.connections.first(where: { $0.id == editingConnectionID }) else { throw TranslationError.missingAPIKey }
    return try await validCredentials(for: connection, proxy: settings.proxy)
  }

  func validCredentials(for connection: AIConnection, proxy: ProxySettings) async throws -> (accessToken: String, accountId: String?) {
    guard settings.connections.contains(where: { $0.id == connection.id && $0.credentialRevision == connection.credentialRevision && $0.configuration == connection.configuration }) else {
      throw NSError(domain: "AIConnections", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.isChinese ? "连接已更改，请重新配置后重试。" : "The connection changed. Reconfigure and retry."])
    }
    let configuration = connection.configuration
    if configuration.provider.supportsOAuth && configuration.authMode == .oauthCodex {
      guard var creds = credentials.oauthCredentials(for: connection.id), !creds.accessToken.isEmpty else { throw TranslationError.missingOAuthCredentials }
      if creds.isExpired {
        let identity = RefreshIdentity(connectionID: connection.id, credentialRevision: connection.credentialRevision, configuration: connection.configuration, proxy: proxy)
        let task: Task<OAuthCredentials, Error>
        if let existing = refreshTasks[identity] { task = existing }
        else {
          task = Task { try await refreshOAuth(creds, proxy) }
          refreshTasks[identity] = task
        }
        defer { refreshTasks[identity] = nil }
        let refreshed = try await task.value
        guard settings.connections.contains(where: { $0.id == connection.id && $0.credentialRevision == connection.credentialRevision && $0.configuration == connection.configuration }) else { throw TranslationError.oauthExpired }
        try credentials.setOAuthCredentials(refreshed, for: connection.id)
        creds = refreshed
        if editingConnectionID == connection.id { oauthCredentials = refreshed }
      }
      return (creds.accessToken, creds.accountId)
    }
    let key = credentials.apiKey(for: connection.id)
    if configuration.provider.usesAPIKey && key.isEmpty { throw TranslationError.missingAPIKey }
    return (key, nil)
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
    editingConnectionID = nil
    settings = AppSettings()
    let connection = AIConnection(name: ProviderKind.openAI.rawValue, configuration: settings.provider)
    settings.connections = [connection]
    settings.defaultConnectionID = connection.id
    settings.defaultModel = connection.configuration.model
    selectConnection(connection.id)
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
