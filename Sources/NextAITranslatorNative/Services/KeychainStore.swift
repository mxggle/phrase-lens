import Foundation
import Security

struct KeychainStore: Sendable {
  private let service = "com.harry.nextai-translator-native"

  func apiKey(for provider: ProviderKind) throws -> String {
    var query = baseQuery(account: provider.rawValue)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return ""
    }
    guard status == errSecSuccess,
      let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      throw KeychainError.unhandled(status)
    }
    return value
  }

  func setAPIKey(_ value: String, for provider: ProviderKind) throws {
    let query = baseQuery(account: provider.rawValue)
    let data = Data(value.utf8)
    let status: OSStatus
    if value.isEmpty {
      let deleteStatus = SecItemDelete(query as CFDictionary)
      guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
        throw KeychainError.unhandled(deleteStatus)
      }
      return
    }

    let existing = SecItemCopyMatching(query as CFDictionary, nil)
    if existing == errSecSuccess {
      status = SecItemUpdate(
        query as CFDictionary,
        [kSecValueData as String: data] as CFDictionary
      )
    } else {
      var attributes = query
      attributes[kSecValueData as String] = data
      attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      status = SecItemAdd(attributes as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw KeychainError.unhandled(status)
    }
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
