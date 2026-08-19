import Foundation
import Security

/// Read-only access to credentials that earlier builds filed in the login
/// Keychain. Nothing writes or deletes here any more — `CredentialStore` owns
/// storage — and this exists only so an upgrading install can recover the key
/// it already entered. Reading an item raises the Keychain's password panel on
/// any build whose signature differs from the one that wrote it, so
/// `CredentialStore` only reaches these reads when someone asks for the import.
struct LegacyKeychainStore: Sendable {
  private let service = "com.harry.phraselens"

  /// Whether an item exists at all, asked without requesting its data.
  ///
  /// The access-control panel is raised by reading a secret, not by looking at
  /// an item's attributes, so this answers "is there anything to import?"
  /// without putting a password prompt in front of anyone.
  func hasStoredCredential(for provider: ProviderKind) -> Bool {
    [provider.rawValue, oauthAccount(for: provider)].contains { account in
      var query = baseQuery(account: account)
      query[kSecReturnAttributes as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
  }

  func apiKey(for provider: ProviderKind) throws -> String {
    guard let data = try copyData(account: provider.rawValue) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }

  func oauthCredentials(for provider: ProviderKind) throws -> OAuthCredentials? {
    guard let data = try copyData(account: oauthAccount(for: provider)) else { return nil }
    return try? JSONDecoder().decode(OAuthCredentials.self, from: data)
  }

  private func copyData(account: String) throws -> Data? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw KeychainError.unhandled(status)
    }
    return data
  }

  private func oauthAccount(for provider: ProviderKind) -> String {
    "\(provider.rawValue)-oauth"
  }

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

enum KeychainError: LocalizedError {
  case unhandled(OSStatus)

  var errorDescription: String? {
    switch self {
    case .unhandled(let status):
      SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
  }
}
