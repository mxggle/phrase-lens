import Foundation
import SwiftUI

public enum AppResources: Sendable {
  public static var bundle: Bundle {
    if Bundle.main.bundleURL.pathExtension == "app" {
      if let url = Bundle.main.resourceURL?.appendingPathComponent("PhraseLens_PhraseLens.bundle"),
         let bundle = Bundle(url: url) {
        return bundle
      }
      return Bundle.main
    }
    return Bundle.module
  }
}

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
  case system
  case english = "en"
  case simplifiedChinese = "zh-Hans"

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .system:
      return L10n.isChinese ? "跟随系统" : "System Default"
    case .english:
      return "English"
    case .simplifiedChinese:
      return "简体中文"
    }
  }

  public var localeIdentifier: String? {
    switch self {
    case .system: return nil
    case .english: return "en"
    case .simplifiedChinese: return "zh-Hans"
    }
  }
}

public final class L10n: @unchecked Sendable {
  public static let shared = L10n()

  private let lock = NSLock()
  private var _currentLanguage: AppLanguage = .system
  private var _cachedBundle: Bundle?

  private init() {
    updateBundle()
  }

  public var currentLanguage: AppLanguage {
    lock.lock()
    defer { lock.unlock() }
    return _currentLanguage
  }

  public static var isChinese: Bool {
    let lang = shared.currentLanguage
    if lang == .simplifiedChinese { return true }
    if lang == .english { return false }
    let preferred = Locale.preferredLanguages.first ?? ""
    return preferred.hasPrefix("zh")
  }

  public func setLanguage(_ language: AppLanguage) {
    lock.lock()
    defer { lock.unlock() }
    guard _currentLanguage != language else { return }
    _currentLanguage = language
    updateBundle()
  }

  private func updateBundle() {
    let langCode: String
    switch _currentLanguage {
    case .system:
      let preferred = Locale.preferredLanguages.first ?? "en"
      langCode = preferred.hasPrefix("zh") ? "zh-Hans" : "en"
    case .english:
      langCode = "en"
    case .simplifiedChinese:
      langCode = "zh-Hans"
    }
    let candidates = [langCode, langCode.lowercased(), langCode.replacingOccurrences(of: "-", with: "_")]
    var foundBundle: Bundle?
    for code in candidates {
      if let path = AppResources.bundle.path(forResource: code, ofType: "lproj"),
         let bundle = Bundle(path: path) {
        foundBundle = bundle
        break
      }
      if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
         let bundle = Bundle(path: path) {
        foundBundle = bundle
        break
      }
    }
    _cachedBundle = foundBundle ?? AppResources.bundle
  }

  public var activeBundle: Bundle {
    lock.lock()
    defer { lock.unlock() }
    if _cachedBundle == nil { updateBundle() }
    return _cachedBundle ?? AppResources.bundle
  }

  public static func tr(_ key: String, table: String? = nil, _ args: CVarArg...) -> String {
    let bundle = shared.activeBundle
    let format = bundle.localizedString(forKey: key, value: nil, table: table)
    if args.isEmpty {
      return format
    }
    return String(format: format, locale: Locale.current, arguments: args)
  }

  public static func trOrFallback(_ key: String, fallback: String, table: String? = nil) -> String {
    let bundle = shared.activeBundle
    let val = bundle.localizedString(forKey: key, value: fallback, table: table)
    return val.isEmpty ? fallback : val
  }
}

/// Global convenience function for string localization
public func loc(_ key: String, table: String? = nil, _ args: CVarArg...) -> String {
  let bundle = L10n.shared.activeBundle
  let format = bundle.localizedString(forKey: key, value: nil, table: table)
  if args.isEmpty {
    return format
  }
  return String(format: format, locale: Locale.current, arguments: args)
}
