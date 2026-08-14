import Foundation
@preconcurrency import NaturalLanguage

enum LanguageDetector {
  static func detect(_ text: String) -> LanguageCode {
    let scalars = text.unicodeScalars

    // This app is primarily used for English and Japanese lookups. Han-only text is
    // inherently ambiguous, so prefer Japanese instead of allowing the system
    // recognizer to classify short kanji words as Chinese.
    if scalars.contains(where: isJapaneseScriptOrHan) {
      return .japanese
    }

    // Short English words are another weak spot for statistical detection. Keep
    // ASCII-only alphabetic input on the app's primary English/Japanese path.
    let containsASCIILetter = scalars.contains { scalar in
      (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }
    let containsNonASCII = scalars.contains { $0.value > 127 }
    if containsASCIILetter, !containsNonASCII {
      return .english
    }

    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let language = recognizer.dominantLanguage else { return .auto }
    switch language {
    case .english: return .english
    case .japanese: return .japanese
    case .simplifiedChinese: return .simplifiedChinese
    case .traditionalChinese: return .traditionalChinese
    case .korean: return .korean
    case .french: return .french
    case .german: return .german
    case .spanish: return .spanish
    case .portuguese: return .portuguese
    case .italian: return .italian
    case .russian: return .russian
    case .arabic: return .arabic
    case .hindi: return .hindi
    case .thai: return .thai
    case .turkish: return .turkish
    case .vietnamese: return .vietnamese
    case .indonesian: return .indonesian
    case .dutch: return .dutch
    case .polish: return .polish
    case .ukrainian: return .ukrainian
    default: return .auto
    }
  }

  private static func isJapaneseScriptOrHan(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3040...0x30FF,  // Hiragana and Katakana
      0x31F0...0x31FF,  // Katakana phonetic extensions
      0x3400...0x4DBF,  // CJK unified ideographs extension A
      0x4E00...0x9FFF,  // CJK unified ideographs
      0xF900...0xFAFF,  // CJK compatibility ideographs
      0xFF66...0xFF9D,  // Half-width Katakana
      0x20000...0x2FA1F:  // CJK extensions and compatibility supplement
      return true
    default:
      return false
    }
  }
}

enum TranslationSourceResolver {
  static func resolve(
    _ text: String,
    configuredSource: LanguageCode,
    inputSource: InputSource,
    restoredSource: LanguageCode? = nil
  ) -> LanguageCode {
    switch inputSource {
    case .selection, .ocr:
      return LanguageDetector.detect(text)
    case .history:
      guard let restoredSource, restoredSource != .auto else {
        return LanguageDetector.detect(text)
      }
      return restoredSource
    case .manual:
      return configuredSource == .auto
        ? LanguageDetector.detect(text)
        : configuredSource
    }
  }
}
