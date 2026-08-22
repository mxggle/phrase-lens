import Foundation

// MARK: - Dimensions

/// What kind of thing was saved.
///
/// This is the dimension that matters most, because the collection mixes them:
/// a headword, a fixed expression, and a whole sentence kept for its structure
/// are three different things to study, and a grid that tiles them together
/// reads as one undifferentiated wall.
enum VocabularyUnit: String, Codable, CaseIterable, Identifiable, Sendable {
  case word
  case phrase
  case sentence

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .word: "Word"
    case .phrase: "Phrase"
    case .sentence: "Sentence"
    }
  }

  /// Answers a model might give for this dimension that are not the raw value.
  static let synonyms: [String: VocabularyUnit] = [
    "headword": .word,
    "vocabulary": .word,
    "term": .word,
    "idiom": .phrase,
    "expression": .phrase,
    "collocation": .phrase,
    "setphrase": .phrase,
    "clause": .sentence,
    "sentencepattern": .sentence,
    "grammar": .sentence,
  ]
}

enum VocabularyPartOfSpeech: String, Codable, CaseIterable, Identifiable, Sendable {
  case noun
  case verb
  case adjective
  case adverb
  case conjunction
  case particle
  case expression

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .noun: "Noun"
    case .verb: "Verb"
    case .adjective: "Adjective"
    case .adverb: "Adverb"
    case .conjunction: "Conjunction"
    case .particle: "Particle"
    case .expression: "Expression"
    }
  }

  static let synonyms: [String: VocabularyPartOfSpeech] = [
    "n": .noun,
    "pronoun": .noun,
    "propernoun": .noun,
    "v": .verb,
    "adj": .adjective,
    "adjectivalnoun": .adjective,
    "naadjective": .adjective,
    "iadjective": .adjective,
    "adv": .adverb,
    "conj": .conjunction,
    "conjunctive": .conjunction,
    "auxiliary": .particle,
    "postposition": .particle,
    "preposition": .particle,
    "idiom": .expression,
    "phrase": .expression,
    "interjection": .expression,
    "other": .expression,
  ]
}

/// Where a word belongs — the dimension that answers "can I put this in an
/// email?", which a dictionary sense on its own never does.
enum VocabularyRegister: String, Codable, CaseIterable, Identifiable, Sendable {
  case spoken
  case written
  case formal
  case slang
  case honorific

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .spoken: "Spoken"
    case .written: "Written"
    case .formal: "Formal"
    case .slang: "Slang & internet"
    case .honorific: "Honorific"
    }
  }

  static let synonyms: [String: VocabularyRegister] = [
    "colloquial": .spoken,
    "casual": .spoken,
    "conversational": .spoken,
    "literary": .written,
    "academic": .written,
    "business": .formal,
    "polite": .formal,
    "internet": .slang,
    "slanginternet": .slang,
    "netslang": .slang,
    "vulgar": .slang,
    "keigo": .honorific,
    "respectful": .honorific,
    "humble": .honorific,
  ]
}

/// A five-step scale that every language shares.
///
/// The scale a learner actually thinks in is their language's own — JLPT,
/// CEFR, HSK — but those do not line up with each other and the app files
/// twenty languages in one list. The native rung is kept alongside, in
/// `VocabularyTags.levelLabel`, for the entries whose language has one.
enum VocabularyDifficulty: Int, Codable, CaseIterable, Identifiable, Sendable {
  case beginner = 1
  case elementary = 2
  case intermediate = 3
  case advanced = 4
  case expert = 5

  var id: Int { rawValue }

  var displayName: String {
    switch self {
    case .beginner: "Beginner"
    case .elementary: "Elementary"
    case .intermediate: "Intermediate"
    case .advanced: "Advanced"
    case .expert: "Expert"
    }
  }
}

// MARK: - Loose matching

extension RawRepresentable where Self: CaseIterable, RawValue == String {
  /// Matches one of a model's answers to a case, forgiving case, spacing, and
  /// punctuation.
  ///
  /// The taxonomy is spelled out in the request, but a model still answers
  /// "Part of speech: noun" or "na-adjective" often enough that treating those
  /// as unfiled loses real work. Anything still unrecognized stays unfiled,
  /// which is the honest outcome — a wrong bucket is worse than no bucket.
  init?(loose raw: String, synonyms: [String: Self] = [:]) {
    let normalized = Self.normalizedTagToken(raw)
    guard !normalized.isEmpty else { return nil }
    if let match = Self.allCases.first(where: {
      Self.normalizedTagToken($0.rawValue) == normalized
    }) {
      self = match
      return
    }
    if let match = synonyms[normalized] {
      self = match
      return
    }
    return nil
  }

  static func normalizedTagToken(_ raw: String) -> String {
    // A model that answers with a labeled field ("unit: word") keeps only the
    // value; everything before the last colon is the label it repeated back.
    let value = raw.split(separator: ":").last.map(String.init) ?? raw
    return String(value.lowercased().filter(\.isLetter))
  }
}

// MARK: - Tags

/// How one saved entry is filed.
///
/// Every field is optional and stays that way. Entries saved before tagging
/// existed decode with nothing set; a model that cannot judge a dimension is
/// told to leave it out rather than guess; and a tagging run that never
/// succeeded has to leave the entry as usable as it was before.
struct VocabularyTags: Codable, Hashable, Sendable {
  var unit: VocabularyUnit?
  var partOfSpeech: VocabularyPartOfSpeech?
  var register: VocabularyRegister?
  var difficulty: VocabularyDifficulty?
  /// The rung this entry sits on in the source language's own scale — "N2",
  /// "B1". Shown, never filtered on: the scale changes with the language, so
  /// its values cannot share a column with another language's.
  var levelLabel: String?
  /// At most two subject areas. The one open dimension: what a reader's
  /// material is about is decided by the material, and no fixed list survives
  /// contact with it.
  var topics: [String]?
  var taggedAt: Date?
  /// Which taxonomy wrote these, so a later shape change can find what it left
  /// behind and re-file it instead of trusting stale values.
  var taxonomyVersion: Int?

  var isEmpty: Bool {
    unit == nil && partOfSpeech == nil && register == nil && difficulty == nil
      && levelLabel == nil && (topics?.isEmpty ?? true)
  }

  enum CodingKeys: String, CodingKey {
    case unit
    case partOfSpeech
    case register
    case difficulty
    case levelLabel
    case topics
    case taggedAt
    case taxonomyVersion
  }

  init(
    unit: VocabularyUnit? = nil,
    partOfSpeech: VocabularyPartOfSpeech? = nil,
    register: VocabularyRegister? = nil,
    difficulty: VocabularyDifficulty? = nil,
    levelLabel: String? = nil,
    topics: [String]? = nil,
    taggedAt: Date? = nil,
    taxonomyVersion: Int? = nil
  ) {
    self.unit = unit
    self.partOfSpeech = partOfSpeech
    self.register = register
    self.difficulty = difficulty
    self.levelLabel = levelLabel
    self.topics = topics
    self.taggedAt = taggedAt
    self.taxonomyVersion = taxonomyVersion
  }

  /// Decoding never throws on a value it does not recognize.
  ///
  /// These are read on every launch, from the same file that holds the words
  /// themselves. A taxonomy that later drops a case, or one bad value written
  /// by an older build, would otherwise throw out of `LibraryStore.vocabulary()`
  /// and take the reader's whole collection with it. An unreadable field is
  /// dropped instead.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    unit = (try? container.decodeIfPresent(VocabularyUnit.self, forKey: .unit)) ?? nil
    partOfSpeech =
      (try? container.decodeIfPresent(VocabularyPartOfSpeech.self, forKey: .partOfSpeech)) ?? nil
    register = (try? container.decodeIfPresent(VocabularyRegister.self, forKey: .register)) ?? nil
    difficulty =
      (try? container.decodeIfPresent(VocabularyDifficulty.self, forKey: .difficulty)) ?? nil
    levelLabel = (try? container.decodeIfPresent(String.self, forKey: .levelLabel)) ?? nil
    topics = (try? container.decodeIfPresent([String].self, forKey: .topics)) ?? nil
    taggedAt = (try? container.decodeIfPresent(Date.self, forKey: .taggedAt)) ?? nil
    taxonomyVersion =
      (try? container.decodeIfPresent(Int.self, forKey: .taxonomyVersion)) ?? nil
  }
}
