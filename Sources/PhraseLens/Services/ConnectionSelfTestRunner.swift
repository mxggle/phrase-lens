import Foundation

/// Exercises account ownership and routing with isolated preferences and synthetic
/// credentials. No provider requests or interactive authentication are performed.
@MainActor
enum ConnectionSelfTestRunner {
  static func run() async -> [String] {
    var failures: [String] = []
    do { try await routingAndCredentials() }
    catch { failures.append("Connection routing: \(error)") }
    do { try migrationAndReset() }
    catch { failures.append("Connection migration: \(error)") }
    do { try followUpHistory() }
    catch { failures.append("Follow-up routing: \(error)") }
    do { try await refreshOwnership() }
    catch { failures.append("OAuth ownership: \(error)") }
    do { try await refreshSessionReplacement() }
    catch { failures.append("OAuth session replacement: \(error)") }
    return failures
  }

  private struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  private static func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(description: message) }
  }

  private final class Fixture {
    let suite = "PhraseLens-connections-test-\(UUID())"
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PhraseLens-connections-test-\(UUID())")
    let defaults: UserDefaults
    let credentials: CredentialStore

    init() {
      defaults = UserDefaults(suiteName: suite)!
      // Do not probe the real login Keychain from regression tests.
      for provider in ProviderKind.allCases {
        defaults.set(true, forKey: "credential-keychain-migration-v1." + provider.rawValue)
      }
      credentials = CredentialStore(directory: directory, defaults: defaults)
    }

    func cleanUp() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private static func routingAndCredentials() async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let store = SettingsStore(defaults: fixture.defaults, credentials: fixture.credentials)
    let firstID = store.settings.defaultConnectionID!
    store.settings.provider.model = "first-default"
    store.saveAPIKey("fixture-first")
    let secondID = store.addConnection(provider: .openAI)
    store.settings.provider.model = "second-default"
    store.saveAPIKey("fixture-second")
    let followsDefault = TranslationAction(name: "Default action")
    try expect(store.settings.defaultConnectionID == firstID,
      "Creating or editing a connection changed the global default")
    try expect(try store.resolve(followsDefault).1.model == "first-default",
      "Editing a different connection changed the default model")

    var pinned = TranslationAction(name: "Pinned action")
    pinned.route = ActionRoute(connectionID: firstID, model: "pinned-model")
    store.makeDefault(secondID)
    let (first, pinnedConfiguration) = try store.resolve(pinned)
    let (second, defaultConfiguration) = try store.resolve(followsDefault)
    try expect(first.id == firstID && pinnedConfiguration.model == "pinned-model"
      && second.id == secondID && defaultConfiguration.model == "second-default",
      "Changing the default moved a pinned action")
    let firstCredential = try await store.validCredentials(for: first, proxy: .init())
    let secondCredential = try await store.validCredentials(for: second, proxy: .init())
    try expect(firstCredential.accessToken == "fixture-first"
      && secondCredential.accessToken == "fixture-second",
      "Two connections of the same provider shared credentials")
    let request = try TranslationClient().makeRequest(
      prompt: TranslationPrompt(system: "Test", user: "Test"),
      configuration: pinnedConfiguration, apiKey: firstCredential.accessToken)
    let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
    try expect(body?["model"] as? String == "pinned-model"
      && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-first",
      "The prepared request used another connection's model or credential")
    try expect(ModelCatalogStore.key(for: pinnedConfiguration)
      != ModelCatalogStore.key(for: defaultConfiguration),
      "Different accounts at the same endpoint shared a model catalog")
    try expect(store.deleteConnection(firstID, actions: [pinned]) != nil,
      "A referenced connection was deleted")
    try expect(store.deleteConnection(secondID, actions: []) != nil,
      "The default connection was deleted")

    store.selectConnection(secondID)
    store.saveAPIKey("")
    try expect(store.isConfigured(pinned) && !store.isConfigured(followsDefault),
      "A broken global default marked a valid pinned action unconfigured")
    let reopened = SettingsStore(defaults: fixture.defaults,
      credentials: CredentialStore(directory: fixture.directory, defaults: fixture.defaults))
    try expect(reopened.settings.connections.count == 2
      && reopened.settings.defaultConnectionID == secondID,
      "Saved connections or the default did not survive reopening")
    let restoredFirst = try reopened.resolve(pinned).0
    let restoredCredential = try await reopened.validCredentials(for: restoredFirst, proxy: .init())
    try expect(restoredCredential.accessToken == "fixture-first",
      "Reopening lost a connection credential")
    try expect(reopened.deleteConnection(firstID, actions: []) == nil,
      "An unreferenced nondefault connection could not be removed")
    do {
      _ = try reopened.resolve(pinned)
      throw Failure(description: "A removed connection silently fell back to the default")
    } catch is Failure { throw Failure(description: "A removed connection silently fell back to the default") }
    catch { /* Expected: the action needs an explicit replacement. */ }
  }

  private static func migrationAndReset() throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    var legacy = AppSettings()
    legacy.provider.model = "legacy-default"
    var custom = TranslationAction(name: "Legacy custom")
    custom.routingVersion = nil
    custom.setModelOverride("legacy-pinned", for: legacy.provider)
    var builtIn = TranslationAction.builtIns[0]
    builtIn.routingVersion = nil
    builtIn.setModelOverride("legacy-built-in", for: legacy.provider)
    legacy.setBuiltInOverride(builtIn)
    fixture.defaults.set(try JSONEncoder().encode(legacy), forKey: "app-settings-v1")
    try fixture.credentials.setAPIKey("fixture-legacy", for: .openAI)
    let store = SettingsStore(defaults: fixture.defaults, credentials: fixture.credentials)
    let origin = store.settings.defaultConnectionID!
    try expect(fixture.credentials.apiKey(for: origin) == "fixture-legacy",
      "Migration lost the active provider credential")
    try expect(store.settings.resolvedBuiltInActions.first?.route?.model == "legacy-built-in",
      "Migration lost a built-in action's model")
    let other = store.addConnection(provider: .ollama)
    store.makeDefault(other)
    store.migrateAction(&custom)
    try expect(custom.route?.connectionID == origin && custom.route?.model == "legacy-pinned",
      "Delayed custom-action migration used a newly selected global default")
    custom.route = nil
    store.migrateAction(&custom)
    try expect(custom.route == nil, "A migrated action reverted after choosing Follow default")
    let savedCustom = try JSONDecoder().decode(TranslationAction.self, from: JSONEncoder().encode(custom))
    var reloaded = savedCustom
    store.migrateAction(&reloaded)
    try expect(reloaded.route == nil && reloaded.modelOverrides == custom.modelOverrides,
      "Restarting reactivated or discarded retained legacy model choices")
    store.resetBuiltInAction(builtIn.id)
    try expect(store.settings.resolvedBuiltInActions.first?.route?.model == "legacy-built-in",
      "Resetting a prompt also reset its AI route")
    store.reset()
    try expect(store.settings.connections.count == 1 && store.settings.defaultConnectionID != nil,
      "Reset left settings without a usable connection editor")
    _ = try store.resolve(TranslationAction(name: "After reset"))
  }

  private static func followUpHistory() throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let store = SettingsStore(defaults: fixture.defaults, credentials: fixture.credentials)
    store.saveAPIKey("fixture-history")
    let action = TranslationAction.builtIns[0]
    let (connection, configuration) = try store.resolve(action)
    let route = ResultRoute(connectionID: connection.id, configuration: configuration,
      credentialRevision: connection.credentialRevision, proxy: .init(), action: action,
      source: .english, target: .japanese, text: "Original passage.", selectionContext: "Original context.")
    var entry = HistoryEntry(sourceText: route.text, translatedText: "Original answer",
      sourceLanguage: route.source, targetLanguage: route.target, actionName: action.name,
      provider: configuration.provider, model: configuration.model)
    entry.resultRoute = route
    let model = AppModel(settingsStore: store, library: LibraryStore(directory: fixture.directory),
      integrateWithSystem: false)
    model.restore(entry, showWindow: false)
    let other = store.addConnection(provider: .ollama)
    store.makeDefault(other)
    store.settings.targetLanguage = .french
    model.selectedActionID = TranslationAction.builtIns.last!.id
    let prepared = try model.prepareFollowUp("Explain further")
    try expect(prepared.connection.id == connection.id && prepared.configuration == configuration,
      "Changing the default or current action redirected a follow-up")
    let expected = PromptBuilder.followUp(question: "Explain further",
      base: PromptBuilder.build(text: route.text, source: route.source, target: route.target,
        action: route.action, selectionContext: route.selectionContext),
      answer: entry.translatedText, turns: [], target: route.target)
    try expect(prepared.prompt == expected,
      "A restored follow-up lost its original language or prompt context")
    store.settings.sourceLanguage = .english
    model.swapLanguages()
    do {
      _ = try model.prepareFollowUp("Explain swapped text")
      throw Failure(description: "Swapping text retained an unrelated answer's route")
    } catch is Failure { throw Failure(description: "Swapping text retained an unrelated answer's route") }
    catch { /* Expected: swapped text is not the original model result. */ }
    model.restore(entry, showWindow: false)
    store.selectConnection(connection.id)
    store.settings.provider.endpoint = "https://example.invalid/v1/chat/completions"
    do {
      _ = try model.prepareFollowUp("Explain further")
      throw Failure(description: "An edited endpoint silently received old history")
    } catch is Failure { throw Failure(description: "An edited endpoint silently received old history") }
    catch { /* Expected: explicitly rerun with the new destination. */ }
    entry.resultRoute = nil
    model.restore(entry, showWindow: false)
    do {
      _ = try model.prepareFollowUp("Explain further")
      throw Failure(description: "Legacy history guessed a connection")
    } catch is Failure { throw Failure(description: "Legacy history guessed a connection") }
    catch { /* Expected: there is no reliable original connection. */ }
  }

  private static func refreshOwnership() async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let gate = RefreshGate()
    let store = SettingsStore(defaults: fixture.defaults, credentials: fixture.credentials,
      refreshOAuth: { _, _ in await gate.refresh() })
    store.settings.provider.authMode = .oauthCodex
    let firstID = store.settings.defaultConnectionID!
    try fixture.credentials.setOAuthCredentials(OAuthCredentials(accessToken: "expired",
      refreshToken: "refresh", expiresAt: .distantPast, email: "fixture@example.invalid", accountId: "first"), for: firstID)
    let connection = store.settings.connections.first { $0.id == firstID }!
    let first = Task { try await store.validCredentials(for: connection, proxy: .init()) }
    for _ in 0..<500 {
      if await gate.calls > 0 { break }
      await Task.yield()
    }
    let second = Task { try await store.validCredentials(for: connection, proxy: .init()) }
    for _ in 0..<50 { await Task.yield() }
    let otherID = store.addConnection(provider: .openAI)
    await gate.release()
    let firstResult = try await first.value
    let secondResult = try await second.value
    try expect(await gate.calls == 1, "Concurrent requests refreshed the same OAuth session twice")
    try expect(firstResult.accessToken == "refreshed" && secondResult.accountId == "first"
      && fixture.credentials.oauthCredentials(for: firstID)?.accessToken == "refreshed"
      && fixture.credentials.oauthCredentials(for: otherID) == nil,
      "Switching the edited connection redirected an OAuth refresh")

    let gate2 = RefreshGate()
    let store2 = SettingsStore(defaults: fixture.defaults, credentials: fixture.credentials,
      refreshOAuth: { _, _ in await gate2.refresh() })
    store2.selectConnection(firstID)
    try fixture.credentials.setOAuthCredentials(OAuthCredentials(accessToken: "expired-again",
      refreshToken: "refresh", expiresAt: .distantPast, email: nil, accountId: "first"), for: firstID)
    let snapshot = store2.settings.connections.first { $0.id == firstID }!
    let stale = Task { try await store2.validCredentials(for: snapshot, proxy: .init()) }
    for _ in 0..<500 {
      if await gate2.calls > 0 { break }
      await Task.yield()
    }
    store2.logoutOAuth()
    await gate2.release()
    do {
      _ = try await stale.value
      throw Failure(description: "A refresh restored credentials after logout")
    } catch is Failure { throw Failure(description: "A refresh restored credentials after logout") }
    catch { /* Expected: the captured credential identity was revoked. */ }
    try expect(fixture.credentials.oauthCredentials(for: firstID) == nil,
      "A stale refresh persisted credentials after logout")
  }
  private static func refreshSessionReplacement() async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let oldGate = RefreshGate(accountID: "old-account")
    let newGate = RefreshGate(accountID: "new-account")
    let store = SettingsStore(defaults: fixture.defaults, credentials: fixture.credentials,
      refreshOAuth: { credentials, _ in
        if credentials.accountId == "new-account" { return await newGate.refresh() }
        return await oldGate.refresh()
      })
    store.settings.provider.authMode = .oauthCodex
    let id = store.settings.defaultConnectionID!
    try fixture.credentials.setOAuthCredentials(OAuthCredentials(accessToken: "expired-old",
      refreshToken: "old-refresh", expiresAt: .distantPast, email: nil, accountId: "old-account"), for: id)
    let oldSnapshot = store.settings.connections.first { $0.id == id }!
    let oldRequest = Task { try await store.validCredentials(for: oldSnapshot, proxy: .init()) }
    for _ in 0..<500 {
      if await oldGate.calls > 0 { break }
      await Task.yield()
    }
    store.logoutOAuth()
    try fixture.credentials.setOAuthCredentials(OAuthCredentials(accessToken: "expired-new",
      refreshToken: "new-refresh", expiresAt: .distantPast, email: nil, accountId: "new-account"), for: id)
    let newSnapshot = store.settings.connections.first { $0.id == id }!
    let newRequest = Task { try await store.validCredentials(for: newSnapshot, proxy: .init()) }
    for _ in 0..<500 {
      if await newGate.calls > 0 { break }
      await Task.yield()
    }
    await oldGate.release()
    await newGate.release()
    _ = try? await oldRequest.value
    let result = try await newRequest.value
    try expect(result.accountId == "new-account"
      && fixture.credentials.oauthCredentials(for: id)?.accountId == "new-account",
      "A new login inherited the previous account's pending OAuth refresh")
    try expect(await newGate.calls == 1,
      "A new credential identity joined the old credential's refresh task")
  }

}

private actor RefreshGate {
  private(set) var calls = 0
  private let accountID: String

  init(accountID: String = "first") { self.accountID = accountID }
  private var continuations: [CheckedContinuation<OAuthCredentials, Never>] = []
  private var released = false

  func refresh() async -> OAuthCredentials {
    calls += 1
    if released { return response }
    return await withCheckedContinuation { continuations.append($0) }
  }

  func release() {
    released = true
    for continuation in continuations { continuation.resume(returning: response) }
    continuations.removeAll()
  }

  private var response: OAuthCredentials {
    OAuthCredentials(accessToken: "refreshed", refreshToken: "next-refresh",
      expiresAt: Date().addingTimeInterval(3600), email: "fixture@example.invalid", accountId: accountID)
  }
}
