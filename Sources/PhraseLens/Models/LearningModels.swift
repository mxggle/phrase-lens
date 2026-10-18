import Foundation

// The study record the learning assistant keeps. History says what was asked;
// this says what the reader keeps coming back to, so it outlives the history
// cap and is pruned only when the reader deletes the history it came from.

/// One word or phrase the reader has looked up, and every time they met it.
struct LearningTerm: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  var language: LanguageCode
  /// `LearningLedger.key(for:)` of the headword. Lookups find their term by it.
  var key: String
  /// The spelling the reader last looked up.
  var display: String
  /// The dictionary form, when one is known: from the system lemmatizer where
  /// it covers the language, otherwise from the annotator.
  var lemma: String?
  /// How the headword is read, for scripts that do not spell it out.
  var reading: String?
  /// Keys of every spelling that has led here, so `ran` keeps finding `run`
  /// after the two have been merged.
  var forms: [String]
  var encounters: [LearningEncounter]
  var relations: [LearningRelation]?
  /// When the annotator last read this term, and under which prompt version.
  var annotatedAt: Date?
  var annotationVersion: Int?
  var card: StudyCard?
  var review: ReviewState?
  /// When the term was saved to Vocabulary on its own. It happens once: a
  /// reader who then removes the word has decided against it.
  var autoCollectedAt: Date?

  var firstSeen: Date { encounters.first?.at ?? .distantPast }
  var lastSeen: Date { encounters.last?.at ?? .distantPast }
  var headword: String { lemma ?? display }
}

/// One sitting with a term. Lookups within `LearningLedger.encounterMergeWindow`
/// of each other are one sitting: switching tabs over the same word is not
/// forgetting it.
struct LearningEncounter: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  var at: Date
  var surface: String
  /// The sentence the term was met in, cut from the captured context.
  var sentence: String?
  var historyIDs: [UUID]
  var actions: [String]
  var followUps: [LearningFollowUp]?
  /// A short gloss of the sense met here, written by the annotator.
  var sense: String?
}

struct LearningFollowUp: Codable, Hashable, Sendable {
  var historyID: UUID
  var question: String
}

/// How two terms in the record relate. Written only by the annotator, which
/// only ever judges pairs the ledger proposed itself.
struct LearningRelation: Codable, Hashable, Sendable {
  var termID: UUID
  var kind: LearningRelationKind
  var note: String
  var createdAt: Date
}

enum LearningRelationKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case synonym
  case antonym
  case confusable
  case sameRoot
  case collocation
  case sameTopic

  var id: String { rawValue }

  var title: String {
    if L10n.isChinese {
      switch self {
      case .synonym: return "近义"
      case .antonym: return "反义"
      case .confusable: return "易混"
      case .sameRoot: return "同根"
      case .collocation: return "搭配"
      case .sameTopic: return "同主题"
      }
    }
    switch self {
    case .synonym: return "Synonym"
    case .antonym: return "Antonym"
    case .confusable: return "Confusable"
    case .sameRoot: return "Same root"
    case .collocation: return "Collocation"
    case .sameTopic: return "Same topic"
    }
  }

  /// Spellings a model reaches for instead of the raw value.
  static let synonyms: [String: LearningRelationKind] = [
    "synonyms": .synonym, "near-synonym": .synonym, "similar": .synonym,
    "antonyms": .antonym, "opposite": .antonym,
    "confusables": .confusable, "confusing": .confusable, "look-alike": .confusable,
    "lookalike": .confusable, "false-friend": .confusable, "similar-form": .confusable,
    "same-root": .sameRoot, "root": .sameRoot, "cognate": .sameRoot, "derivative": .sameRoot,
    "same-kanji": .sameRoot, "family": .sameRoot,
    "collocations": .collocation, "phrase": .collocation,
    "same-topic": .sameTopic, "topic": .sameTopic, "theme": .sameTopic,
  ]

  init?(loose raw: String) {
    let folded = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
    if let exact = Self.allCases.first(where: { $0.rawValue.lowercased() == folded.replacingOccurrences(of: "-", with: "") }) {
      self = exact
    } else if let mapped = Self.synonyms[folded] {
      self = mapped
    } else {
      return nil
    }
  }
}

/// What the reader gets for a word they keep forgetting.
struct StudyCard: Codable, Hashable, Sendable {
  var meaning: String
  /// The one line meant to make it stick.
  var hook: String
  var contrast: String?
  var example: String?
  var exampleTranslation: String?
  var createdAt: Date
}

enum ReviewGrade: Int, Codable, CaseIterable, Identifiable, Sendable {
  case again = 1
  case hard = 2
  case good = 3
  case easy = 4

  var id: Int { rawValue }

  var title: String {
    if L10n.isChinese {
      switch self {
      case .again: return "忘了"
      case .hard: return "模糊"
      case .good: return "记得"
      case .easy: return "很熟"
      }
    }
    switch self {
    case .again: return "Forgot"
    case .hard: return "Hard"
    case .good: return "Good"
    case .easy: return "Easy"
    }
  }
}

/// Where a term stands in the review queue.
struct ReviewState: Codable, Hashable, Sendable {
  var enrolledAt: Date
  var due: Date
  /// Days until the next review after a successful one.
  var interval: Double
  var ease: Double
  var reps: Int
  var lapses: Int
  var lastReviewedAt: Date?
  var lastGrade: ReviewGrade?
}

/// A diagnosis of a stretch of study, written by the coach and grounded in
/// terms from the record.
struct LearningReport: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  var createdAt: Date
  var periodStart: Date
  var periodEnd: Date
  var summary: String
  var issues: [LearningIssue]
  var focusTermIDs: [UUID]
  var stats: LearningStats
}

struct LearningIssue: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  var title: String
  var detail: String
  var suggestion: String
  var termIDs: [UUID]
}

/// Counts over a period, worked out locally.
struct LearningStats: Codable, Hashable, Sendable {
  var lookups: Int
  var newTerms: Int
  var repeatedTerms: Int
  var followUps: Int
  var sentenceLookups: Int
  var categoryCounts: [String: Int]
}

/// The file the learning assistant keeps beside the history.
struct LearningLibrary: Codable, Sendable {
  var version = 1
  var terms: [LearningTerm] = []
  var reports: [LearningReport] = []
  /// Whether history that predates the assistant has been read in once.
  var backfilledHistory = false
}

/// What kind of thing a follow-up asked for. Drives the adaptive first answer
/// and the order of the suggestion chips.
enum FollowUpCategory: String, Codable, CaseIterable, Identifiable, Sendable {
  case examples
  case nuance
  case collocations
  case wordParts
  case memory
  case breakdown
  case grammar
  case keyWords
  case rephrase
  case deeper
  case pronunciation
  case other

  var id: String { rawValue }

  var title: String {
    if L10n.isChinese {
      switch self {
      case .examples: return "例句"
      case .nuance: return "词义辨析"
      case .collocations: return "搭配"
      case .wordParts: return "词根词源"
      case .memory: return "记忆技巧"
      case .breakdown: return "成分拆解"
      case .grammar: return "语法"
      case .keyWords: return "核心词汇"
      case .rephrase: return "改写"
      case .deeper: return "深层含义"
      case .pronunciation: return "发音"
      case .other: return "其他"
      }
    }
    switch self {
    case .examples: return "Examples"
    case .nuance: return "Nuance"
    case .collocations: return "Collocations"
    case .wordParts: return "Word parts"
    case .memory: return "Memory aids"
    case .breakdown: return "Breakdown"
    case .grammar: return "Grammar"
    case .keyWords: return "Key words"
    case .rephrase: return "Rephrasing"
    case .deeper: return "Deeper meaning"
    case .pronunciation: return "Pronunciation"
    case .other: return "Other"
    }
  }

  /// How the adaptive first answer asks for this, in the prompt's language.
  var promptRequest: String? {
    switch self {
    case .examples: return "two or three natural example sentences with translations"
    case .nuance: return "how it differs from the words it is most often confused with"
    case .collocations: return "its most common collocations"
    case .wordParts: return "its word parts or etymology"
    case .memory: return "a short memory hook"
    case .breakdown: return "a chunk-by-chunk breakdown"
    case .grammar: return "the grammar points it uses"
    case .keyWords: return "the key words worth learning"
    case .rephrase: return "a more casual and a more formal rephrasing"
    case .deeper: return "why it means this rather than the literal reading"
    case .pronunciation: return "how it is pronounced"
    case .other: return nil
    }
  }

  /// Which chip in `FollowUpSuggestion` asks for this.
  static func of(chipSymbol symbol: String, sentence: Bool) -> FollowUpCategory? {
    switch symbol {
    case "text.quote": return .examples
    case "arrow.triangle.branch": return .nuance
    case "link": return .collocations
    case "square.split.2x1": return .wordParts
    case "brain": return .memory
    case "list.bullet.indent": return .breakdown
    case "textformat.abc": return .grammar
    case "star": return .keyWords
    case "arrow.2.squarepath": return .rephrase
    case "questionmark.circle": return .deeper
    default: return nil
    }
  }
}

/// What the record says about the term being looked up, handed to the prompt
/// so the answer can build on what the reader already met.
struct LearnerMemory: Equatable, Sendable {
  struct Encounter: Equatable, Sendable {
    var date: Date
    var sentence: String?
    var sense: String?
  }

  struct Related: Equatable, Sendable {
    var term: String
    var kind: LearningRelationKind
    var note: String
  }

  /// Sittings with this term, the current one included.
  var lookupCount: Int
  var lookupDays: Int
  /// Earlier sittings, most recent first. The current one is not among them.
  var earlier: [Encounter]
  var questions: [String]
  var related: [Related]
  var hook: String?
  /// What this reader usually asks for afterwards, most asked first.
  var habits: [FollowUpCategory]

  var isRepeat: Bool { lookupCount > 1 }
  var isEmpty: Bool { !isRepeat && related.isEmpty && hook == nil && habits.isEmpty }
}
