import CryptoKit
import Foundation
import IOKit

/// Provider credentials, stored where this app can always read them back.
///
/// They used to live in the login Keychain as generic passwords. Every read
/// there is gated by the item's access-control list, and that list is pinned to
/// the code signature that created the item, so a differently signed build —
/// which is every build during development, and every user who moves the app —
/// gets the "PhraseLens wants to access key … enter the login keychain
/// password" panel. With a read on each provider switch, that panel was showing
/// up during ordinary settings work.
///
/// So credentials now live in a file this app owns, and the process reads it
/// once per launch. The file is sealed with AES-GCM under a key derived from
/// this Mac's hardware UUID, which means a copy lifted out of a backup or a
/// synced folder is inert on another machine. It is deliberately not protection
/// against someone who is already running code as this user: anything that can
/// read the file can also derive the key. The Keychain's stronger promise is the
/// thing that cost a password prompt per read, and for an API key that is
/// already replayable from any process in this session, that trade is not worth
/// it. Compare `~/.aws/credentials`, `~/.config/gh/hosts.yml`, or Codex CLI's
/// `~/.codex/auth.json`, which all settle in the same place.
final class CredentialStore: @unchecked Sendable {
  static let shared = CredentialStore()

  private struct Payload: Codable {
    var apiKeys: [String: String] = [:]
    var oauth: [String: OAuthCredentials] = [:]
  }

  /// The on-disk wrapper. The salt is stored in the clear on purpose: it is
  /// what makes the derived key differ per install rather than being a secret
  /// of its own.
  private struct Envelope: Codable {
    var version: Int
    var salt: Data
    var sealed: Data
  }

  private static let currentVersion = 1
  private static let migrationKeyPrefix = "credential-keychain-migration-v1."

  private let fileURL: URL
  private let directoryURL: URL
  private let defaults: UserDefaults
  private let legacyKeychain: LegacyKeychainStore
  private let lock = NSLock()
  private var payload: Payload?
  private var cachedKey: SymmetricKey?
  private var cachedSalt: Data?

  init(
    directory: URL? = nil,
    filename: String = "credentials.json",
    defaults: UserDefaults = .standard,
    legacyKeychain: LegacyKeychainStore = LegacyKeychainStore()
  ) {
    directoryURL =
      directory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PhraseLens", isDirectory: true)
    fileURL = directoryURL.appendingPathComponent(filename)
    self.defaults = defaults
    self.legacyKeychain = legacyKeychain
  }

  // MARK: - Reading

  func apiKey(for provider: ProviderKind) -> String {
    lock.lock()
    defer { lock.unlock() }
    return loadedPayload().apiKeys[provider.rawValue] ?? ""
  }

  func oauthCredentials(for provider: ProviderKind) -> OAuthCredentials? {
    lock.lock()
    defer { lock.unlock() }
    return loadedPayload().oauth[provider.rawValue]
  }

  // MARK: - Writing

  func setAPIKey(_ value: String, for provider: ProviderKind) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    try mutate { payload in
      if trimmed.isEmpty {
        payload.apiKeys.removeValue(forKey: provider.rawValue)
      } else {
        payload.apiKeys[provider.rawValue] = trimmed
      }
    }
  }

  func setOAuthCredentials(_ credentials: OAuthCredentials?, for provider: ProviderKind) throws {
    try mutate { payload in
      if let credentials {
        payload.oauth[provider.rawValue] = credentials
      } else {
        payload.oauth.removeValue(forKey: provider.rawValue)
      }
    }
  }

  // MARK: - Legacy Keychain migration

  enum LegacyImport {
    /// There was nothing in the Keychain, or it has already been dealt with.
    case none
    case imported
    /// An item is there, but reading it was refused — almost always because the
    /// access panel was dismissed.
    case unreadable
  }

  /// Whether an earlier build left something in the Keychain for this provider
  /// that has not been imported yet.
  ///
  /// Answered from the item's attributes, which the Keychain hands over without
  /// its access panel, so offering the import costs the user nothing. Finding
  /// nothing settles the question for good.
  func hasImportableLegacyCredentials(for provider: ProviderKind) -> Bool {
    let flag = Self.migrationKeyPrefix + provider.rawValue
    guard !defaults.bool(forKey: flag) else { return false }
    guard legacyKeychain.hasStoredCredential(for: provider) else {
      defaults.set(true, forKey: flag)
      return false
    }
    return true
  }

  /// Imports whatever an earlier build filed in the Keychain for one provider.
  ///
  /// This is the one code path that can raise the Keychain's access panel, and
  /// it runs only because someone pressed the import button: the panel appears
  /// for every build signed differently from the one that wrote the item, which
  /// is every development build and every user who reinstalled the app, so
  /// doing this on its own turned ordinary settings work into a password
  /// prompt. Call it off the main thread — the panel blocks its caller.
  ///
  /// What is read is left in the Keychain rather than deleted, because deleting
  /// is another authenticated operation and so another panel. The flag below is
  /// what keeps an imported provider from being offered again.
  func importLegacyKeychainCredentials(for provider: ProviderKind) -> LegacyImport {
    let flag = Self.migrationKeyPrefix + provider.rawValue
    guard !defaults.bool(forKey: flag) else { return .none }
    guard legacyKeychain.hasStoredCredential(for: provider) else {
      defaults.set(true, forKey: flag)
      return .none
    }

    let legacyKey = (try? legacyKeychain.apiKey(for: provider)) ?? ""
    let legacyOAuth = try? legacyKeychain.oauthCredentials(for: provider)
    // A dismissed panel leaves the flag alone: the button is the user's, and
    // pressing it again is how they retry.
    guard !legacyKey.isEmpty || legacyOAuth != nil else { return .unreadable }
    defaults.set(true, forKey: flag)

    var imported = false
    try? mutate { payload in
      // A credential entered since the upgrade is the newer one; the Keychain
      // copy only fills a gap.
      if !legacyKey.isEmpty, (payload.apiKeys[provider.rawValue] ?? "").isEmpty {
        payload.apiKeys[provider.rawValue] = legacyKey
        imported = true
      }
      if let legacyOAuth, payload.oauth[provider.rawValue] == nil {
        payload.oauth[provider.rawValue] = legacyOAuth
        imported = true
      }
    }
    return imported ? .imported : .none
  }

  // MARK: - Storage

  private func mutate(_ body: (inout Payload) -> Void) throws {
    lock.lock()
    defer { lock.unlock() }
    var payload = loadedPayload()
    body(&payload)
    try write(payload)
    self.payload = payload
  }

  /// Callers hold `lock`.
  private func loadedPayload() -> Payload {
    if let payload { return payload }
    let loaded = (try? read()) ?? Payload()
    payload = loaded
    return loaded
  }

  private func read() throws -> Payload {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return Payload() }
    let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
    guard envelope.version == Self.currentVersion else { return Payload() }
    let box = try AES.GCM.SealedBox(combined: envelope.sealed)
    let opened = try AES.GCM.open(box, using: encryptionKey(salt: envelope.salt))
    return try JSONDecoder.credentials.decode(Payload.self, from: opened)
  }

  private func write(_ payload: Payload) throws {
    let salt = try existingSalt() ?? Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    let sealed = try AES.GCM.seal(
      JSONEncoder.credentials.encode(payload),
      using: encryptionKey(salt: salt)
    )
    guard let combined = sealed.combined else { throw CredentialStoreError.sealFailed }
    let envelope = Envelope(version: Self.currentVersion, salt: salt, sealed: combined)

    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try JSONEncoder().encode(envelope).write(to: fileURL, options: [.atomic])
    // `.atomic` replaces the file, so the mode is reapplied after every write
    // rather than only at creation.
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  private func existingSalt() throws -> Data? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
    return envelope?.version == Self.currentVersion ? envelope?.salt : nil
  }

  private func encryptionKey(salt: Data) throws -> SymmetricKey {
    if let cachedKey, salt == cachedSalt { return cachedKey }
    let seed = Data((Self.hardwareIdentifier() + "|com.harry.phraselens").utf8)
    let key = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: seed),
      salt: salt,
      info: Data("PhraseLens credential store v1".utf8),
      outputByteCount: 32
    )
    cachedKey = key
    cachedSalt = salt
    return key
  }

  /// The Mac's hardware UUID. It is stable across reboots and reinstalls of the
  /// app, and different on every other machine, which is exactly the binding
  /// this file wants. If IOKit declines to answer, the derivation still works —
  /// the file is then merely portable, not readable in the clear.
  private static func hardwareIdentifier() -> String {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault,
      IOServiceMatching("IOPlatformExpertDevice")
    )
    guard service != 0 else { return "" }
    defer { IOObjectRelease(service) }
    let property = IORegistryEntryCreateCFProperty(
      service,
      kIOPlatformUUIDKey as CFString,
      kCFAllocatorDefault,
      0
    )
    return (property?.takeRetainedValue() as? String) ?? ""
  }
}

enum CredentialStoreError: LocalizedError {
  case sealFailed

  var errorDescription: String? {
    switch self {
    case .sealFailed: "The credential file could not be encrypted."
    }
  }
}

extension JSONEncoder {
  fileprivate static var credentials: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var credentials: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
