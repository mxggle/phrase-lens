import Foundation
@preconcurrency import NaturalLanguage

/// The bookkeeping behind the learning assistant: which history rows count as
/// looking a term up, which term a lookup belongs to, and what the record says
/// about it.
///
/// Everything here is a pure function of its inputs and uses nothing that is
/// specific to one language. Lemmas come from the system lemmatizer only where
/// it covers the language; everything else — readings, senses, dictionary
/// forms for languages it does not cover — is the annotator's job.
enum LearningLedger {
  /// Lookups this close together are one sitting. Switching action tabs, or
  /// running the same word again, is not forgetting it.
  static let encounterMergeWindow: TimeInterval = 30 * 60
  /// Longest sentence kept from a captured context.
  static let sentenceLimit = 240
  /// Questions kept per sitting.
  static let maximumEncounterQuestions = 12

  // MARK: - Which rows are lookups

  /// Built-in action names as history has stored them, in either interface
  /// language. Rows written before results carried their route only have this.
  private static let storedActionNames: [String: ActionMode] = [
    "Translate": .translate, "翻译": .translate,
    "Definition": .definition, "释义": .definition,
    "Polish": .polishing, "润色": .polishing,
    "Summarize": .summarize, "摘要": .summarize,
    "Analyze": .analyze, "深度解析": .analyze,
    "Explain Usage": .explainUsage, "用法详解": .explainUsage,
    "Explain in Context": .explainContext, "语境解析": .explainContext,
    "Explain Code": .explainCode, "代码解析": .explainCode,
    "Compare Synonyms": .compareSynonyms, "近义词辨析": .compareSynonyms,
  ]

  /// The mode that produced a history row, or nil for a custom action.
  static func mode(of entry: HistoryEntry) -> ActionMode? {
    if let route = entry.resultRoute { return route.action.mode }
    if entry.dictionarySnapshot != nil { return .definition }
    return storedActionNames[entry.actionName]
  }

  /// Modes that work on a text rather than study it.
  private static let nonStudyModes: Set<ActionMode> = [.polishing, .summarize, .explainCode]

  /// Whether a request was someone looking a term up — a word or a short
  /// phrase, under an action that studies it.
  static func isLookup(text: String, mode: ActionMode?) -> Bool {
    if let mode, nonStudyModes.contains(mode) { return false }
    let clean = cleaned(text)
    guard clean.contains(where: \.isLetter) else { return false }
    return PromptBuilder.isLikelyShortPhrase(clean)
  }

  /// Whether a request studied a passage rather than a term.
  static func isPassageStudy(text: String, mode: ActionMode?) -> Bool {
    if let mode, nonStudyModes.contains(mode) { return false }
    let clean = cleaned(text)
    return clean.contains(where: \.isLetter) && !PromptBuilder.isLikelyShortPhrase(clean)
  }

  // MARK: - Normal forms

  /// A selection with its edges cleaned up: whitespace collapsed, and the
  /// punctuation a drag tends to pick up along with the word dropped.
  static func cleaned(_ text: String) -> String {
    let edges = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
      .subtracting(CharacterSet(charactersIn: "'’-〜~"))
    return PromptBuilder.normalizedWhitespace(text).trimmingCharacters(in: edges)
  }

  /// The form two spellings are compared in when the question is "is this the
  /// same term". Case and character width fold away; accents and kana voicing
  /// do not, because in some language each of them is a different word.
  static func key(for text: String) -> String {
    cleaned(text)
      .precomposedStringWithCompatibilityMapping
      .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
  }

  static func resolvedLanguage(_ stored: LanguageCode, text: String) -> LanguageCode {
    stored == .auto ? LanguageDetector.detect(text) : stored
  }

  /// The dictionary form, from the system lemmatizer, or nil when it does not
  /// cover the language or the text.
  ///
  /// A phrase is lemmatized word by word and only in scripts that space their
  /// words, because those are the only ones it can be put back together in.
  static func lemma(of text: String, language: LanguageCode) -> String? {
    let clean = cleaned(text)
    guard !clean.isEmpty, clean.count <= 40 else { return nil }
    let tagger = NLTagger(tagSchemes: [.lemma])
    tagger.string = clean
    let range = clean.startIndex..<clean.endIndex
    if language != .auto {
      tagger.setLanguage(NLLanguage(rawValue: language.rawValue), range: range)
    }
    var parts: [String] = []
    var complete = true
    tagger.enumerateTags(
      in: range,
      unit: .word,
      scheme: .lemma,
      options: [.omitPunctuation, .omitWhitespace]
    ) { tag, _ in
      guard let lemma = tag?.rawValue, !lemma.isEmpty else {
        complete = false
        return false
      }
      parts.append(lemma)
      return true
    }
    guard complete, !parts.isEmpty, parts.count == 1 || clean.contains(" ") else { return nil }
    return parts.joined(separator: " ")
  }

  // MARK: - Context

  /// The sentence a term was met in, cut from the text captured around it.
  static func sentence(containing term: String, in context: String?) -> String? {
    guard let context else { return nil }
    let text = PromptBuilder.normalizedWhitespace(context)
    let needle = cleaned(term)
    guard !text.isEmpty, !needle.isEmpty,
      let hit = text.range(of: needle, options: [.caseInsensitive, .widthInsensitive])
    else { return nil }

    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = text
    var found: Range<String.Index>?
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      guard range.contains(hit.lowerBound) else { return true }
      found = range
      return false
    }
    // A term that straddles the tokenizer's boundary keeps its whole self.
    let sentenceRange = found.map { $0.lowerBound..<max($0.upperBound, hit.upperBound) } ?? hit
    let sentence = window(text, around: hit, within: sentenceRange)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // A "sentence" that is only the term itself says nothing about it.
    guard key(for: sentence) != key(for: term) else { return nil }
    return sentence
  }

  /// At most `sentenceLimit` characters of `range`, keeping `hit` inside.
  private static func window(
    _ text: String,
    around hit: Range<String.Index>,
    within range: Range<String.Index>
  ) -> String {
    let length = text.distance(from: range.lowerBound, to: range.upperBound)
    guard length > sentenceLimit else { return String(text[range]) }
    let hitStart = text.distance(from: range.lowerBound, to: hit.lowerBound)
    let hitLength = text.distance(from: hit.lowerBound, to: hit.upperBound)
    var start = max(0, hitStart - max(0, sentenceLimit - hitLength) / 2)
    start = min(start, length - sentenceLimit)
    let lower = text.index(range.lowerBound, offsetBy: start)
    let upper = text.index(lower, offsetBy: sentenceLimit)
    return (start > 0 ? "…" : "") + text[lower..<upper] + (upper < range.upperBound ? "…" : "")
  }

  // MARK: - Recording

  /// The term a spelling belongs to. A term in the same language wins; one in
  /// another language is the fallback, since a source language set by hand
  /// does not always describe the text that was typed.
  static func termIndex(
    forKeys keys: [String],
    language: LanguageCode,
    in terms: [LearningTerm]
  ) -> Int? {
    var fallback: Int?
    for (index, term) in terms.enumerated()
    where keys.contains(where: { $0 == term.key || term.forms.contains($0) }) {
      if term.language == language { return index }
      fallback = fallback ?? index
    }
    return fallback
  }

  /// Files a history row under its term, and returns where the term sits.
  /// Rows that are not lookups, and rows already filed, change nothing.
  @discardableResult
  static func record(_ entry: HistoryEntry, into terms: inout [LearningTerm]) -> Int? {
    guard isLookup(text: entry.sourceText, mode: mode(of: entry)) else { return nil }
    let surface = cleaned(entry.sourceText)
    let language = resolvedLanguage(entry.sourceLanguage, text: surface)
    let surfaceKey = key(for: surface)
    let lemma = lemma(of: surface, language: language)
    let lemmaKey = lemma.map(key(for:))
    let keys = [lemmaKey, surfaceKey].compactMap { $0 }
    let questions = (entry.followUps ?? [])
      .filter { !$0.answer.isEmpty }
      .map { LearningFollowUp(historyID: entry.id, question: $0.question) }
    let encounter = LearningEncounter(
      at: entry.createdAt,
      surface: surface,
      sentence: sentence(containing: surface, in: entry.selectionContext),
      historyIDs: [entry.id],
      actions: [entry.actionName],
      followUps: questions.isEmpty ? nil : questions
    )

    guard let index = termIndex(forKeys: keys, language: language, in: terms) else {
      terms.append(
        LearningTerm(
          language: language,
          key: lemmaKey ?? surfaceKey,
          display: surface,
          lemma: lemma,
          forms: unique(keys),
          encounters: [encounter]
        )
      )
      return terms.count - 1
    }

    var term = terms[index]
    if term.encounters.contains(where: { $0.historyIDs.contains(entry.id) }) { return index }
    if entry.createdAt >= term.lastSeen { term.display = surface }
    if term.lemma == nil, let lemma { term.lemma = lemma }
    term.forms = unique(term.forms + keys)

    if let near = term.encounters.firstIndex(where: {
      abs($0.at.timeIntervalSince(entry.createdAt)) < encounterMergeWindow
    }) {
      var merged = term.encounters[near]
      merged.historyIDs.append(entry.id)
      if !merged.actions.contains(entry.actionName) { merged.actions.append(entry.actionName) }
      merged.sentence = merged.sentence ?? encounter.sentence
      let combined = (merged.followUps ?? []) + questions
      merged.followUps = combined.isEmpty ? nil : Array(combined.suffix(maximumEncounterQuestions))
      term.encounters[near] = merged
    } else {
      let position = term.encounters.firstIndex(where: { $0.at > entry.createdAt }) ?? term.encounters.count
      term.encounters.insert(encounter, at: position)
    }
    terms[index] = term
    return index
  }

  /// Replaces the questions filed for one history row with its current thread.
  @discardableResult
  static func attachFollowUps(
    historyID: UUID,
    questions: [String],
    to terms: inout [LearningTerm]
  ) -> Bool {
    for termIndex in terms.indices {
      guard let encounterIndex = terms[termIndex].encounters.firstIndex(where: {
        $0.historyIDs.contains(historyID)
      }) else { continue }
      var encounter = terms[termIndex].encounters[encounterIndex]
      var list = (encounter.followUps ?? []).filter { $0.historyID != historyID }
      list += questions.map { LearningFollowUp(historyID: historyID, question: $0) }
      encounter.followUps = list.isEmpty ? nil : Array(list.suffix(maximumEncounterQuestions))
      terms[termIndex].encounters[encounterIndex] = encounter
      return true
    }
    return false
  }

  /// Drops everything filed from the given history rows. A term with nothing
  /// left goes too, along with every relation pointing at it.
  static func forget(historyIDs: Set<UUID>, in terms: inout [LearningTerm]) {
    guard !historyIDs.isEmpty else { return }
    var removed = Set<UUID>()
    terms = terms.compactMap { term in
      var term = term
      term.encounters = term.encounters.compactMap { encounter in
        var encounter = encounter
        encounter.historyIDs.removeAll { historyIDs.contains($0) }
        encounter.followUps?.removeAll { historyIDs.contains($0.historyID) }
        if encounter.followUps?.isEmpty == true { encounter.followUps = nil }
        return encounter.historyIDs.isEmpty ? nil : encounter
      }
      if term.encounters.isEmpty {
        removed.insert(term.id)
        return nil
      }
      return term
    }
    guard !removed.isEmpty else { return }
    for index in terms.indices {
      terms[index].relations?.removeAll { removed.contains($0.termID) }
      if terms[index].relations?.isEmpty == true { terms[index].relations = nil }
    }
  }

  /// Terms for history written before the assistant existed, oldest first so
  /// sittings merge the way they would have live.
  static func backfill(_ history: [HistoryEntry]) -> [LearningTerm] {
    var terms: [LearningTerm] = []
    for entry in history.sorted(by: { $0.createdAt < $1.createdAt }) {
      record(entry, into: &terms)
    }
    return terms
  }

  // MARK: - What the record says

  static func distinctDays(_ term: LearningTerm, calendar: Calendar = .current) -> Int {
    Set(term.encounters.map { calendar.startOfDay(for: $0.at) }).count
  }

  /// Met in more than one sitting.
  static func isRepeat(_ term: LearningTerm) -> Bool { term.encounters.count >= 2 }

  /// Met three times or more, on more than one day: not sticking.
  static func isStubborn(_ term: LearningTerm, calendar: Calendar = .current) -> Bool {
    term.encounters.count >= 3 && distinctDays(term, calendar: calendar) >= 2
  }

  /// The term a lookup of `text` would be filed under.
  static func term(
    for text: String,
    language: LanguageCode,
    in terms: [LearningTerm]
  ) -> LearningTerm? {
    let surface = cleaned(text)
    guard !surface.isEmpty else { return nil }
    let resolved = resolvedLanguage(language, text: surface)
    var keys = [key(for: surface)]
    if let lemma = lemma(of: surface, language: resolved) { keys.insert(key(for: lemma), at: 0) }
    return termIndex(forKeys: keys, language: resolved, in: terms).map { terms[$0] }
  }

  /// What a new lookup of `term` should be told about the reader.
  static func memory(
    for term: LearningTerm?,
    in terms: [LearningTerm],
    habits: [FollowUpCategory],
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> LearnerMemory? {
    var memory = LearnerMemory(
      lookupCount: 1,
      lookupDays: 1,
      earlier: [],
      questions: [],
      related: [],
      hook: nil,
      habits: habits
    )
    if let term {
      // The sitting under way is not "earlier", even when a lookup in it has
      // already been filed.
      let earlier = term.encounters.filter { now.timeIntervalSince($0.at) >= encounterMergeWindow }
      memory.lookupCount = earlier.count + 1
      memory.lookupDays = Set((earlier.map(\.at) + [now]).map { calendar.startOfDay(for: $0) }).count
      memory.earlier = earlier.reversed().prefix(3).map {
        LearnerMemory.Encounter(date: $0.at, sentence: $0.sentence, sense: $0.sense)
      }
      memory.questions = Array(unique(earlier.flatMap { $0.followUps ?? [] }.map(\.question)).suffix(3))
      memory.related = (term.relations ?? []).prefix(3).compactMap { relation in
        guard let other = terms.first(where: { $0.id == relation.termID }) else { return nil }
        return LearnerMemory.Related(term: other.headword, kind: relation.kind, note: relation.note)
      }
      memory.hook = term.card?.hook
    }
    return memory.isEmpty ? nil : memory
  }

  // MARK: - Follow-up habits

  /// Words that give a follow-up's subject away, in the languages a reader is
  /// likely to type questions in. Checked in order, so the narrower subjects
  /// come before the ones whose words also turn up in other questions.
  private static let categoryKeywords: [(FollowUpCategory, [String])] = [
    (.nuance, ["区别", "辨析", "混淆", "差别", "差异", "不同", "difference", "differ", " vs", "versus",
      "confus", "nuance", "違い", "区別"]),
    (.collocations, ["搭配", "固定短语", "collocat", "goes with", "組み合わせ", "コロケーション"]),
    (.wordParts, ["词根", "词缀", "词源", "派生", "etymolog", "root", "prefix", "suffix", "語源"]),
    (.memory, ["记忆", "记住", "联想", "mnemonic", "remember", "memori", "覚え"]),
    (.pronunciation, ["发音", "读音", "怎么读", "pronounc", "読み方", "発音"]),
    (.grammar, ["语法", "时态", "grammar", "tense", "文法"]),
    (.breakdown, ["拆解", "成分", "break it down", "break down", "structure", "構造"]),
    (.rephrase, ["改写", "换种说法", "换个说法", "rephrase", "paraphrase", "say it differently", "言い換え"]),
    (.keyWords, ["重点词", "核心词", "key word"]),
    (.examples, ["例句", "例子", "举例", "造句", "example", "例文"]),
    (.deeper, ["为什么", "深层", "字面", "why", "literal", "idiom", "なぜ"]),
  ]

  /// What a follow-up asked for. The one-tap chips are recognized exactly; a
  /// typed question is read for the words that give its subject away.
  static func category(of question: String) -> FollowUpCategory {
    let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
    for (sample, sentence) in [("word", false), ("A sentence long enough to parse, with a clause.", true)] {
      if let chip = FollowUpSuggestion.suggestions(for: sample, mode: nil).first(where: { $0.question == trimmed }),
        let category = FollowUpCategory.of(chipSymbol: chip.symbol, sentence: sentence)
      {
        return category
      }
    }
    let folded = " " + trimmed.lowercased()
    for (category, words) in categoryKeywords where words.contains(where: { folded.contains($0) }) {
      return category
    }
    return .other
  }

  /// The subjects a reader asks about often enough that the first answer
  /// should cover them: asked at least three times, and a quarter of all
  /// questions or more. At most two, so the answer keeps its own shape.
  static func habits(from counts: [FollowUpCategory: Int]) -> [FollowUpCategory] {
    let total = counts.values.reduce(0, +)
    guard total > 0 else { return [] }
    return counts
      .filter { $0.key != .other && $0.value >= 3 && Double($0.value) / Double(total) >= 0.25 }
      .sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
      .prefix(2)
      .map(\.key)
  }

  static func unique<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    return values.filter { seen.insert($0).inserted }
  }
}
