import Foundation
@preconcurrency import NaturalLanguage

/// Proposes which terms in the record might be related, without asking a
/// model. The annotator then judges only these pairs, which is what keeps it
/// from inventing relations to words the reader never met.
///
/// Every signal here works on characters, so it applies to any language: a
/// shared stem or a near-identical spelling for alphabetic scripts, a shared
/// character for Han script. The system's word embeddings add meaning where
/// the system has them for the language, and are skipped where it does not.
enum LearningRelations {
  /// Lowest score that still makes a pair worth asking about.
  static let threshold = 0.45

  /// Candidates for every term in `batch`, keyed by term id, best first.
  static func candidates(
    for batch: [LearningTerm],
    in terms: [LearningTerm],
    limit: Int
  ) -> [UUID: [LearningTerm]] {
    var embeddings: [LanguageCode: NLEmbedding] = [:]
    for language in Set(batch.map(\.language)) where language != .auto {
      if let embedding = NLEmbedding.wordEmbedding(for: NLLanguage(rawValue: language.rawValue)) {
        embeddings[language] = embedding
      }
    }
    var result: [UUID: [LearningTerm]] = [:]
    for term in batch {
      let related = Set((term.relations ?? []).map(\.termID))
      let scored = terms.compactMap { other -> (LearningTerm, Double)? in
        guard other.id != term.id, !related.contains(other.id), comparable(term.language, other.language)
        else { return nil }
        var value = score(term.headword, other.headword)
        if let embedding = embeddings[term.language], term.language == other.language {
          value = max(value, semanticScore(term.headword, other.headword, embedding: embedding))
        }
        return value >= threshold ? (other, value) : nil
      }
      result[term.id] = scored
        .sorted { $0.1 == $1.1 ? $0.0.lastSeen > $1.0.lastSeen : $0.1 > $1.1 }
        .prefix(limit)
        .map(\.0)
    }
    return result
  }

  /// Han script is shared across Chinese and Japanese, and a source language
  /// set by hand sometimes files one under the other.
  static func comparable(_ lhs: LanguageCode, _ rhs: LanguageCode) -> Bool {
    let han: Set<LanguageCode> = [.japanese, .simplifiedChinese, .traditionalChinese]
    return lhs == rhs || (han.contains(lhs) && han.contains(rhs))
  }

  /// How alike two spellings are, from 0 to 1.
  static func score(_ lhs: String, _ rhs: String) -> Double {
    let a = Array(LearningLedger.key(for: lhs))
    let b = Array(LearningLedger.key(for: rhs))
    guard !a.isEmpty, !b.isEmpty, a != b else { return 0 }

    let hanA = a.filter(isHan)
    let hanB = b.filter(isHan)
    if !hanA.isEmpty || !hanB.isEmpty {
      // Kana and particles carry grammar, not meaning; the characters that
      // are shared between two words are the ones that say they are kin.
      let shared = Set(hanA).intersection(hanB).count
      guard shared > 0 else { return 0 }
      let contained = containsRun(a, b) ? 0.2 : 0
      return min(1, 0.35 + Double(shared) / Double(max(Set(hanA).count, Set(hanB).count)) * 0.4 + contained)
    }

    let shorter = min(a.count, b.count)
    var value = 0.0
    if shorter >= 3, containsRun(a, b) { value = max(value, 0.7) }
    let prefix = zip(a, b).prefix { $0 == $1 }.count
    if prefix >= 4, Double(prefix) >= 0.6 * Double(shorter) { value = max(value, 0.6) }
    if shorter >= 4 {
      switch editDistance(a, b, limit: 2) {
      case 1: value = max(value, 0.8)
      case 2: value = max(value, shorter >= 6 ? 0.55 : 0.45)
      default: break
      }
    }
    return value
  }

  /// Closeness in meaning, from the system's word embedding. Only single
  /// words have a vector.
  static func semanticScore(_ lhs: String, _ rhs: String, embedding: NLEmbedding) -> Double {
    let a = LearningLedger.key(for: lhs)
    let b = LearningLedger.key(for: rhs)
    guard !a.contains(" "), !b.contains(" "), embedding.contains(a), embedding.contains(b) else { return 0 }
    let distance = embedding.distance(between: a, and: b, distanceType: .cosine)
    guard distance.isFinite, distance < 0.95 else { return 0 }
    return min(0.85, (1.25 - distance) * 0.75)
  }

  private static func containsRun(_ a: [Character], _ b: [Character]) -> Bool {
    let (short, long) = a.count <= b.count ? (a, b) : (b, a)
    guard short.count < long.count else { return false }
    for start in 0...(long.count - short.count) where Array(long[start..<(start + short.count)]) == short {
      return true
    }
    return false
  }

  /// Levenshtein distance, or `limit + 1` once it is known to exceed `limit`.
  static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
    guard abs(a.count - b.count) <= limit else { return limit + 1 }
    guard !a.isEmpty, !b.isEmpty else { return min(max(a.count, b.count), limit + 1) }
    var previous = Array(0...b.count)
    for i in 1...a.count {
      var current = [i] + Array(repeating: 0, count: b.count)
      for j in 1...b.count {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
      }
      if current.min() ?? 0 > limit { return limit + 1 }
      previous = current
    }
    return min(previous[b.count], limit + 1)
  }

  private static func isHan(_ character: Character) -> Bool {
    character.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
      default: false
      }
    }
  }
}
