import Foundation

/// The tools the study assistant can call, and how each one is answered.
///
/// Most of them read the reader's own record. Two write to it, and only when
/// the reader asks. Two reach public dictionary APIs for English words, and
/// send nothing but the word.
enum LearningTools {
  static let searchTerms = AgentTool(
    name: "search_terms",
    description: "List terms from the learner's study record. Use it to find what they looked up, what keeps coming back, and what is in review.",
    parameters: """
      {"type":"object","properties":{\
      "query":{"type":"string","description":"Text to match against the term, its reading, or its senses. Omit to list everything."},\
      "filter":{"type":"string","enum":["all","repeated","stubborn","reviewing","related","due"],"description":"repeated: looked up more than once; stubborn: three or more times on different days; reviewing: in the review queue; related: has related terms; due: due for review today."},\
      "language":{"type":"string","description":"Language code such as en or ja."},\
      "limit":{"type":"integer","description":"At most 50. Default 20."}}}
      """
  )

  static let getTerm = AgentTool(
    name: "get_term",
    description: "Everything the record holds about one term: every sitting with its sentence and sense, the follow-up questions asked, related terms, its memory card, its review state, and the latest explanation the learner got.",
    parameters: """
      {"type":"object","properties":{"term":{"type":"string","description":"The term as the learner wrote it, or its dictionary form."}},"required":["term"]}
      """
  )

  static let searchHistory = AgentTool(
    name: "search_history",
    description: "Search the learner's translation history, including passages and sentences, not only terms. Matches the source text, the result, and follow-up questions.",
    parameters: """
      {"type":"object","properties":{\
      "query":{"type":"string","description":"Text to look for. Omit to list the most recent entries."},\
      "days":{"type":"integer","description":"Only entries from the last this many days."},\
      "limit":{"type":"integer","description":"At most 30. Default 10."}}}
      """
  )

  static let getStats = AgentTool(
    name: "get_stats",
    description: "Counts for a recent period: lookups, new terms, repeated terms, follow-up questions and what they asked about, passages studied, and the review queue.",
    parameters: """
      {"type":"object","properties":{"days":{"type":"integer","description":"How many days back. Default 7."}}}
      """
  )

  static let getReport = AgentTool(
    name: "get_report",
    description: "The latest weekly diagnosis of the learner's study, with its issues and the terms they concern.",
    parameters: #"{"type":"object","properties":{}}"#
  )

  static let addToReview = AgentTool(
    name: "add_to_review",
    description: "Put a term from the record into the review queue, due now. Only when the learner asks for it.",
    parameters: """
      {"type":"object","properties":{"term":{"type":"string"}},"required":["term"]}
      """
  )

  static let saveToVocabulary = AgentTool(
    name: "save_to_vocabulary",
    description: "Save a term from the record to the learner's Vocabulary list. Only when the learner asks for it.",
    parameters: """
      {"type":"object","properties":{"term":{"type":"string"}},"required":["term"]}
      """
  )

  static let relatedWords = AgentTool(
    name: "find_related_words",
    description: "English only. Ask the Datamuse API for words related to an English word: synonyms, antonyms, words with a similar meaning, words that sound or are spelled alike, associated words, adjectives used with a noun, or nouns used with an adjective.",
    parameters: """
      {"type":"object","properties":{\
      "word":{"type":"string"},\
      "relation":{"type":"string","enum":["synonyms","antonyms","means_like","sounds_like","spelled_like","associated","adjectives_for","nouns_for"]}},\
      "required":["word","relation"]}
      """
  )

  static let dictionary = AgentTool(
    name: "dictionary_lookup",
    description: "English only. Look an English word up in the Free Dictionary API: phonetics, parts of speech, definitions, examples, and synonyms.",
    parameters: """
      {"type":"object","properties":{"word":{"type":"string"}},"required":["word"]}
      """
  )

  static func available(webTools: Bool) -> [AgentTool] {
    let local = [searchTerms, getTerm, searchHistory, getStats, getReport, addToReview, saveToVocabulary]
    return webTools ? local + [relatedWords, dictionary] : local
  }

  // MARK: - Reading the record

  /// Terms matching a `search_terms` call, newest first.
  static func searchTerms(
    _ arguments: [String: Any],
    in terms: [LearningTerm],
    now: Date = Date()
  ) -> [[String: Any]] {
    let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let language = (arguments["language"] as? String)?.lowercased()
    let limit = min(max(int(arguments["limit"]) ?? 20, 1), 50)
    let filter = arguments["filter"] as? String ?? "all"
    return terms
      .filter { term in
        switch filter {
        case "repeated": LearningLedger.isRepeat(term)
        case "stubborn": LearningLedger.isStubborn(term)
        case "reviewing": term.review != nil
        case "related": term.relations?.isEmpty == false
        case "due": term.review.map { ReviewScheduler.isDue($0, now: now) } ?? false
        default: true
        }
      }
      .filter { term in
        guard let language, !language.isEmpty else { return true }
        return term.language.rawValue.lowercased().hasPrefix(language)
      }
      .filter { term in
        guard !query.isEmpty else { return true }
        return [term.display, term.headword, term.reading ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
          || term.encounters.contains { $0.sense?.localizedCaseInsensitiveContains(query) ?? false }
      }
      .sorted { $0.lastSeen > $1.lastSeen }
      .prefix(limit)
      .map { summary(of: $0, now: now) }
  }

  static func summary(of term: LearningTerm, now: Date) -> [String: Any] {
    var item: [String: Any] = [
      "term": term.headword,
      "language": term.language.rawValue,
      "lookups": term.encounters.count,
      "days": LearningLedger.distinctDays(term),
      "lastSeen": day(term.lastSeen),
    ]
    if let reading = term.reading { item["reading"] = reading }
    let senses = LearningLedger.unique(term.encounters.compactMap(\.sense))
    if !senses.isEmpty { item["senses"] = senses }
    if LearningLedger.isStubborn(term) { item["notSticking"] = true }
    if let count = term.relations?.count, count > 0 { item["relatedTerms"] = count }
    if let review = term.review {
      item["review"] = ReviewScheduler.isDue(review, now: now) ? "due today" : "next \(day(review.due))"
    }
    if term.card != nil { item["hasMemoryCard"] = true }
    return item
  }

  static func termDetail(
    _ term: LearningTerm,
    in terms: [LearningTerm],
    latestExplanation: String?,
    now: Date = Date()
  ) -> [String: Any] {
    var item = summary(of: term, now: now)
    item["sittings"] = term.encounters.suffix(12).map { encounter -> [String: Any] in
      var sitting: [String: Any] = ["date": day(encounter.at), "spelling": encounter.surface, "actions": encounter.actions]
      if let sentence = encounter.sentence { sitting["sentence"] = sentence }
      if let sense = encounter.sense { sitting["sense"] = sense }
      let questions = (encounter.followUps ?? []).map(\.question)
      if !questions.isEmpty { sitting["questions"] = questions }
      return sitting
    }
    let related = (term.relations ?? []).compactMap { relation -> [String: Any]? in
      guard let other = terms.first(where: { $0.id == relation.termID }) else { return nil }
      return ["term": other.headword, "kind": relation.kind.rawValue, "note": relation.note]
    }
    if !related.isEmpty { item["related"] = related }
    if let card = term.card {
      var value: [String: Any] = ["meaning": card.meaning, "hook": card.hook]
      if let contrast = card.contrast { value["contrast"] = contrast }
      if let example = card.example { value["example"] = example }
      item["memoryCard"] = value
    }
    if let review = term.review {
      item["reviewState"] = ["due": day(review.due), "reps": review.reps, "lapses": review.lapses]
    }
    if let latestExplanation {
      item["latestExplanation"] = PromptBuilder.normalizedWhitespace(String(latestExplanation.prefix(600)))
    }
    return item
  }

  static func searchHistory(_ arguments: [String: Any], in history: [HistoryEntry], now: Date = Date()) -> [[String: Any]] {
    let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let limit = min(max(int(arguments["limit"]) ?? 10, 1), 30)
    let since = int(arguments["days"]).map { now.addingTimeInterval(-Double($0) * 86_400) } ?? .distantPast
    return history
      .filter { $0.createdAt >= since }
      .filter { entry in
        guard !query.isEmpty else { return true }
        return entry.sourceText.localizedCaseInsensitiveContains(query)
          || entry.translatedText.localizedCaseInsensitiveContains(query)
          || (entry.followUps ?? []).contains { $0.question.localizedCaseInsensitiveContains(query) }
      }
      .prefix(limit)
      .map { entry -> [String: Any] in
        var item: [String: Any] = [
          "date": day(entry.createdAt),
          "action": entry.actionName,
          "source": String(PromptBuilder.normalizedWhitespace(entry.sourceText).prefix(300)),
          "result": String(PromptBuilder.normalizedWhitespace(entry.translatedText).prefix(300)),
        ]
        if let context = entry.selectionContext, !context.isEmpty {
          item["context"] = String(PromptBuilder.normalizedWhitespace(context).prefix(200))
        }
        let questions = (entry.followUps ?? []).map(\.question)
        if !questions.isEmpty { item["questions"] = questions }
        return item
      }
  }

  static func stats(
    _ arguments: [String: Any],
    terms: [LearningTerm],
    history: [HistoryEntry],
    now: Date = Date()
  ) -> [String: Any] {
    let days = min(max(int(arguments["days"]) ?? 7, 1), 365)
    let stats = LearningLedger.stats(terms: terms, history: history, from: now.addingTimeInterval(-Double(days) * 86_400), to: now)
    return [
      "days": days,
      "lookups": stats.lookups,
      "newTerms": stats.newTerms,
      "repeatedTerms": stats.repeatedTerms,
      "followUpQuestions": stats.followUps,
      "followUpSubjects": stats.categoryCounts,
      "passagesStudied": stats.sentenceLookups,
      "termsInRecord": terms.count,
      "termsInReview": terms.filter { $0.review != nil }.count,
      "dueToday": terms.filter { $0.review.map { ReviewScheduler.isDue($0, now: now) } ?? false }.count,
    ]
  }

  static func report(_ report: LearningReport?, terms: [LearningTerm]) -> [String: Any] {
    guard let report else { return ["report": NSNull(), "note": "No diagnosis has been written yet."] }
    func names(_ ids: [UUID]) -> [String] { ids.compactMap { id in terms.first { $0.id == id }?.headword } }
    return [
      "written": day(report.createdAt),
      "summary": report.summary,
      "issues": report.issues.map {
        ["title": $0.title, "detail": $0.detail, "suggestion": $0.suggestion, "terms": names($0.termIDs)]
      },
      "reviewFirst": names(report.focusTermIDs),
    ]
  }

  /// The term a tool call names, by any spelling the record knows.
  static func term(named name: String, in terms: [LearningTerm]) -> LearningTerm? {
    let key = LearningLedger.key(for: name)
    guard !key.isEmpty else { return nil }
    return terms.first { $0.key == key || $0.forms.contains(key) }
      ?? terms.first { LearningLedger.key(for: $0.headword) == key || LearningLedger.key(for: $0.display) == key }
  }

  // MARK: - Public dictionary APIs

  static let datamuseRelations: [String: String] = [
    "synonyms": "rel_syn", "antonyms": "rel_ant", "means_like": "ml", "sounds_like": "sl",
    "spelled_like": "sp", "associated": "rel_trg", "adjectives_for": "rel_jjb", "nouns_for": "rel_jja",
  ]

  static func datamuseURL(word: String, relation: String) -> URL? {
    guard let parameter = datamuseRelations[relation], isEnglishWord(word) else { return nil }
    var components = URLComponents(string: "https://api.datamuse.com/words")
    components?.queryItems = [URLQueryItem(name: parameter, value: word), URLQueryItem(name: "max", value: "15")]
    return components?.url
  }

  static func dictionaryURL(word: String) -> URL? {
    guard isEnglishWord(word),
      let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    else { return nil }
    return URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)")
  }

  /// Only plain English words or short phrases leave the Mac.
  static func isEnglishWord(_ word: String) -> Bool {
    let trimmed = word.trimmingCharacters(in: .whitespaces)
    return !trimmed.isEmpty && trimmed.count <= 40
      && trimmed.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) && $0.isASCII || " -'".unicodeScalars.contains($0) }
  }

  static func datamuseResult(_ data: Data) -> [[String: Any]] {
    guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
    return items.prefix(15).compactMap { item in
      guard let word = item["word"] as? String else { return nil }
      return ["word": word]
    }
  }

  static func dictionaryResult(_ data: Data) -> [String: Any] {
    guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], let entry = entries.first else {
      return ["found": false]
    }
    var result: [String: Any] = ["found": true, "word": entry["word"] as? String ?? ""]
    let phonetics = (entry["phonetics"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    if let phonetic = (entry["phonetic"] as? String) ?? phonetics.first { result["phonetic"] = phonetic }
    result["meanings"] = (entry["meanings"] as? [[String: Any]] ?? []).prefix(4).map { meaning -> [String: Any] in
      let definitions = (meaning["definitions"] as? [[String: Any]] ?? []).prefix(3).map { definition -> [String: Any] in
        var value: [String: Any] = ["definition": definition["definition"] as? String ?? ""]
        if let example = definition["example"] as? String { value["example"] = example }
        return value
      }
      var value: [String: Any] = [
        "partOfSpeech": meaning["partOfSpeech"] as? String ?? "",
        "definitions": Array(definitions),
      ]
      let synonyms = (meaning["synonyms"] as? [String] ?? []).prefix(8)
      if !synonyms.isEmpty { value["synonyms"] = Array(synonyms) }
      return value
    }
    return result
  }

  // MARK: - Helpers

  static func json(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    else { return "{}" }
    let text = String(decoding: data, as: UTF8.self)
    // A tool result is context for one reply; bound it so a large record
    // cannot crowd out the question.
    return text.count > 12_000 ? String(text.prefix(12_000)) + "…(truncated)" : text
  }

  static func day(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  static func int(_ value: Any?) -> Int? {
    if let number = value as? Int { return number }
    if let number = value as? Double { return Int(number) }
    if let string = value as? String { return Int(string) }
    return nil
  }
}
