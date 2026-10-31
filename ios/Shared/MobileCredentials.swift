import Foundation
import Security

/// API keys, one per provider, in a Keychain group the app and its Action
/// extension share.
///
/// The App Group doubles as the Keychain access group, so the key typed in
/// the app is the one the extension sends, and it never sits in the shared
/// settings file.
enum MobileCredentials {
  private static let service = "com.harry.phraselens.api-key"

  static func apiKey(for provider: ProviderKind) -> String {
    var query = baseQuery(for: provider)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess, let data = item as? Data {
      return String(decoding: data, as: UTF8.self)
    }
    #if targetEnvironment(simulator)
    if status == errSecMissingEntitlement {
      return simulatorFallback.string(forKey: fallbackKey(provider)) ?? ""
    }
    #endif
    return ""
  }

  @discardableResult
  static func setAPIKey(_ key: String, for provider: ProviderKind) -> Bool {
    let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
    let query = baseQuery(for: provider)
    var status = SecItemDelete(query as CFDictionary)
    if status == errSecMissingEntitlement {
      return writeSimulatorFallback(value, for: provider)
    }
    guard !value.isEmpty else { return true }
    var item = query
    item[kSecValueData as String] = Data(value.utf8)
    // Readable by the extension whenever the phone has been unlocked once
    // since boot, never synced off the device.
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    status = SecItemAdd(item as CFDictionary, nil)
    if status == errSecMissingEntitlement {
      return writeSimulatorFallback(value, for: provider)
    }
    return status == errSecSuccess
  }

  private static func baseQuery(for provider: ProviderKind) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: provider.rawValue,
    ]
    // Without the App Group (a Personal Team build) the item lives in this
    // process's own Keychain group, and the extension keeps a key of its own.
    if MobileSettingsStore.isAppGroupAvailable {
      query[kSecAttrAccessGroup as String] = MobileSettingsStore.appGroup
    }
    return query
  }

  // MARK: - Unsigned simulator builds

  /// A simulator build made without signing carries no entitlements, so the
  /// shared Keychain group refuses it. There the key falls back to the App
  /// Group defaults, which is good enough for a test device and never happens
  /// on a phone, where a missing entitlement means the build cannot launch.
  private static var simulatorFallback: UserDefaults {
    UserDefaults(suiteName: MobileSettingsStore.appGroup) ?? .standard
  }

  private static func fallbackKey(_ provider: ProviderKind) -> String {
    "simulator-api-key.\(provider.rawValue)"
  }

  private static func writeSimulatorFallback(_ value: String, for provider: ProviderKind) -> Bool {
    #if targetEnvironment(simulator)
    if value.isEmpty {
      simulatorFallback.removeObject(forKey: fallbackKey(provider))
    } else {
      simulatorFallback.set(value, forKey: fallbackKey(provider))
    }
    return true
    #else
    return false
    #endif
  }
}
