import Foundation
@preconcurrency import NaturalLanguage

/// Dictionary detection is intentionally independent of the existing translator's
/// Japanese/English heuristics. A shared script is never proof of a language.
enum DictionaryLanguageResolver {
  static func candidates(text: String, context: String?, override: String) -> [String] {
    if override != "auto" { return [override] }
    let scalars = text.unicodeScalars
    if scalars.contains(where: { (0x3040...0x30ff).contains($0.value) || (0xff66...0xff9d).contains($0.value) }) {
      return ["ja"]
    }
    if scalars.contains(where: { (0xac00...0xd7af).contains($0.value) || (0x1100...0x11ff).contains($0.value) }) {
      return ["ko"]
    }
    let han = scalars.contains { (0x3400...0x9fff).contains($0.value) || (0x20000...0x2fa1f).contains($0.value) }
    if han {
      let contextual = hypotheses(context ?? "").first
      return contextual?.hasPrefix("zh") == true ? ["zh", "ja"] : ["ja", "zh"]
    }
    var result = hypotheses(text)
    // Short Latin words have poor statistical evidence. Keep English eligible
    // without erasing French/German/etc. An explicit override remains final.
    if text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }),
      text.unicodeScalars.allSatisfy({ $0.value < 0x0250 }) {
      let contextual = hypotheses(context ?? "").first
      if let contextual, !result.contains(contextual) { result.insert(contextual, at: 0) }
      result.removeAll { $0 == "en" }
      result.insert("en", at: min(result.count, context == nil ? 0 : 1))
    }
    return Array(NSOrderedSet(array: result).array.compactMap { $0 as? String }.prefix(3))
  }

  private static func hypotheses(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(String(text.prefix(1_600)))
    return recognizer.languageHypotheses(withMaximum: 3)
      .sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
      .filter { $0.value >= 0.1 }.map { $0.key.rawValue }
  }

  static func isLookupCandidate(_ text: String) -> Bool {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard canProbeLexicalEntry(clean) else { return false }
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = clean
    let tokens = tokenizer.tokens(for: clean.startIndex..<clean.endIndex)
    return tokens.count == 1 && tokens.first == clean.startIndex..<clean.endIndex
  }

  /// CJK compounds and inflections can contain several tokenizer units. They
  /// qualify only after a real dictionary matches the entire selection. This
  /// is a lookup bound, never evidence that the selection is a word.
  static func canProbeLexicalEntry(_ text: String) -> Bool {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean.count <= 80,
      !clean.contains(where: \.isWhitespace),
      clean.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return false }
    return clean.unicodeScalars.allSatisfy {
      CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
        || "-'’".unicodeScalars.contains($0)
    }
  }
}

struct ExactLexicalProcessor: LexicalProcessor {
  func candidates(for text: String) -> [LexicalCandidate] {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = clean.precomposedStringWithCompatibilityMapping
    var values = [LexicalCandidate(text: clean, reason: "exact")]
    if normalized != clean { values.append(.init(text: normalized, reason: "normalized")) }
    return values
  }
}

struct EnglishLexicalProcessor: LexicalProcessor {
  func candidates(for text: String) -> [LexicalCandidate] {
    var values = ExactLexicalProcessor().candidates(for: text)
    let folded = values.last!.text.lowercased()
    if !values.contains(where: { $0.text == folded }) { values.append(.init(text: folded, reason: "case variant")) }
    // Inflections (including irregulars) are indexed from the dictionary, not
    // guessed by stripping suffixes that could produce unrelated words.
    return values
  }
}

struct JapaneseLexicalProcessor: LexicalProcessor {
  func candidates(for text: String) -> [LexicalCandidate] {
    var values = ExactLexicalProcessor().candidates(for: text)
    let normalized = values.last!.text
    if let hiragana = normalized.applyingTransform(.hiraganaToKatakana, reverse: true),
      hiragana != normalized { values.append(.init(text: hiragana, reason: "kana variant")) }
    // Reduce polite tense/negation to the source-indexed polite form.
    // The provider must still find that exact form in a real dictionary entry.
    for suffix in ["ませんでした", "ました", "ません"] where normalized.hasSuffix(suffix) {
      values.append(.init(text: String(normalized.dropLast(suffix.count)) + "ます", reason: "polite inflection"))
    }
    // Source-provided inflection forms are indexed by the importer. Avoid
    // guessing a lemma without its conjugation class and reading restrictions.
    return values
  }
}
