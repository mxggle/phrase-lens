import Foundation

/// Self tests for the learning assistant. Everything checked here is a pure
/// function, so the suite runs without a provider or a library on disk.
enum LearningSelfTests {
  static func run() -> [String] {
    var failures: [String] = []
    ledgerFailures(&failures)
    memoryFailures(&failures)
    habitFailures(&failures)
    analysisFailures(&failures)
    reviewFailures(&failures)
    coachFailures(&failures)
    agentFailures(&failures)
    toolFailures(&failures)
    return failures
  }

  static func entry(
    _ text: String,
    at date: Date,
    language: LanguageCode = .english,
    context: String? = nil,
    action: String = "Definition",
    questions: [String] = []
  ) -> HistoryEntry {
    HistoryEntry(
      createdAt: date,
      sourceText: text,
      translatedText: "explanation of \(text)",
      sourceLanguage: language,
      targetLanguage: .simplifiedChinese,
      actionName: action,
      model: "test",
      selectionContext: context,
      followUps: questions.isEmpty ? nil : questions.map { FollowUpTurn(question: $0, answer: "answer") }
    )
  }

  // MARK: - Ledger

  private static func ledgerFailures(_ failures: inout [String]) {
    check(
      LearningLedger.key(for: "Run") == LearningLedger.key(for: "run")
        && LearningLedger.key(for: "ｶﾀｶﾅ") == LearningLedger.key(for: "カタカナ")
        && LearningLedger.key(for: "“word.”") == "word",
      "learning keys must fold case, width, and stray edge punctuation",
      &failures
    )
    check(
      LearningLedger.key(for: "が") != LearningLedger.key(for: "か")
        && LearningLedger.key(for: "café") != LearningLedger.key(for: "cafe"),
      "learning keys must keep kana voicing and accents, which tell words apart",
      &failures
    )
    check(
      LearningLedger.isLookup(text: "apple", mode: .definition)
        && LearningLedger.isLookup(text: "お疲れ様", mode: nil)
        && LearningLedger.isLookup(text: "take it easy", mode: .translate)
        && !LearningLedger.isLookup(text: "This is a long sentence, with a clause.", mode: .translate)
        && !LearningLedger.isLookup(text: "apple", mode: .polishing)
        && !LearningLedger.isLookup(text: "42", mode: .translate),
      "lookup detection should take words and short phrases under study actions only",
      &failures
    )

    check(
      LearningLedger.sentence(
        containing: "decisive",
        in: "First sentence here. The decisive word appears now. Third one follows."
      ) == "The decisive word appears now."
        && LearningLedger.sentence(containing: "晴れる", in: "今日は雨です。明日は晴れるでしょう。")
          == "明日は晴れるでしょう。"
        && LearningLedger.sentence(containing: "word", in: nil) == nil
        && LearningLedger.sentence(containing: "word", in: "word") == nil,
      "the sentence around a term was not cut from its context",
      &failures
    )
    let longContext = String(repeating: "filler words ", count: 60) + "the pivotal term " + String(repeating: "more ", count: 80)
    let cut = LearningLedger.sentence(containing: "pivotal", in: longContext) ?? ""
    check(
      cut.contains("pivotal") && cut.count <= LearningLedger.sentenceLimit + 2,
      "a long sentence must be windowed around the term",
      &failures
    )

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400
    let first = entry("apple", at: start, context: "I ate an apple today.")
    let rerun = entry("Apple", at: start.addingTimeInterval(600), action: "Explain Usage")
    let nextDay = entry("apple", at: start.addingTimeInterval(day), questions: ["give me examples"])
    var terms: [LearningTerm] = []
    for item in [first, rerun, nextDay] { LearningLedger.record(item, into: &terms) }
    check(
      terms.count == 1 && terms[0].encounters.count == 2
        && terms[0].encounters[0].historyIDs == [first.id, rerun.id]
        && terms[0].encounters[0].sentence == "I ate an apple today."
        && terms[0].encounters[0].actions == ["Definition", "Explain Usage"]
        && terms[0].encounters[1].followUps?.map(\.question) == ["give me examples"],
      "lookups within the merge window must share a sitting, later ones open a new one",
      &failures
    )
    check(
      LearningLedger.isRepeat(terms[0]) && !LearningLedger.isStubborn(terms[0])
        && LearningLedger.distinctDays(terms[0]) == 2,
      "repeat and stubborn thresholds misread a term",
      &failures
    )
    let refiled = terms
    LearningLedger.record(first, into: &terms)
    check(terms == refiled, "recording the same history row twice must change nothing", &failures)

    var lemmaTerms: [LearningTerm] = []
    LearningLedger.record(entry("running", at: start), into: &lemmaTerms)
    LearningLedger.record(entry("ran", at: start.addingTimeInterval(day)), into: &lemmaTerms)
    check(
      lemmaTerms.count == 1 && lemmaTerms[0].lemma == "run" && lemmaTerms[0].encounters.count == 2,
      "inflected English forms should file under their lemma",
      &failures
    )

    var japanese: [LearningTerm] = []
    LearningLedger.record(entry("勉強", at: start, language: .auto), into: &japanese)
    LearningLedger.record(entry("勉強", at: start.addingTimeInterval(day), language: .japanese), into: &japanese)
    check(
      japanese.count == 1 && japanese[0].language == .japanese && japanese[0].encounters.count == 2,
      "a language left on Auto must resolve before filing",
      &failures
    )

    var followed = terms
    LearningLedger.attachFollowUps(historyID: nextDay.id, questions: ["why", "how"], to: &followed)
    check(
      followed[0].encounters[1].followUps?.map(\.question) == ["why", "how"],
      "a thread's questions must replace the ones filed for its row",
      &failures
    )

    var pruned = terms
    pruned[0].relations = []
    var other = LearningTerm(language: .english, key: "pear", display: "pear", forms: ["pear"], encounters: [
      LearningEncounter(at: start, surface: "pear", historyIDs: [UUID()], actions: ["Definition"])
    ])
    other.relations = [LearningRelation(termID: pruned[0].id, kind: .sameTopic, note: "fruit", createdAt: start)]
    pruned.append(other)
    LearningLedger.forget(historyIDs: [rerun.id], in: &pruned)
    check(
      pruned[0].encounters.count == 2 && pruned[0].encounters[0].historyIDs == [first.id],
      "forgetting one row of a sitting must keep the rest of it",
      &failures
    )
    LearningLedger.forget(historyIDs: [first.id, nextDay.id], in: &pruned)
    check(
      pruned.count == 1 && pruned[0].key == "pear" && pruned[0].relations == nil,
      "a term with nothing left must go, with every relation pointing at it",
      &failures
    )

    let backfilled = LearningLedger.backfill([nextDay, rerun, first])
    check(
      backfilled.count == 1 && backfilled[0].encounters.count == 2
        && backfilled[0].encounters[0].historyIDs == [first.id, rerun.id],
      "backfill must file history oldest first, whatever order it arrives in",
      &failures
    )

    let decoded = try? JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    check(
      decoded?.learningEnabled == true && decoded?.learningMemoryInPrompts == true
        && decoded?.learningAutoAnalyze == true && decoded?.learningAutoCollect == true,
      "settings written before the learning assistant must decode with it switched on",
      &failures
    )
  }

  // MARK: - Memory

  private static func memoryFailures(_ failures: inout [String]) {
    let now = Date(timeIntervalSince1970: 1_800_500_000)
    let day: TimeInterval = 86_400
    let related = LearningTerm(language: .english, key: "effect", display: "effect", forms: ["effect"], encounters: [
      LearningEncounter(at: now.addingTimeInterval(-5 * day), surface: "effect", historyIDs: [UUID()], actions: [])
    ])
    var term = LearningTerm(language: .english, key: "affect", display: "affect", forms: ["affect"], encounters: [
      LearningEncounter(
        at: now.addingTimeInterval(-2 * day), surface: "affect", sentence: "It will <b>affect</b> you.",
        historyIDs: [UUID()], actions: [],
        followUps: [LearningFollowUp(historyID: UUID(), question: "和 effect 有什么区别？")]
      ),
      LearningEncounter(at: now.addingTimeInterval(-day), surface: "affect", historyIDs: [UUID()], actions: []),
      LearningEncounter(at: now.addingTimeInterval(-300), surface: "affect", historyIDs: [UUID()], actions: []),
    ])
    term.relations = [LearningRelation(termID: related.id, kind: .confusable, note: "verb vs noun", createdAt: now)]
    let memory = LearningLedger.memory(for: term, in: [term, related], habits: [.examples], now: now)
    check(
      memory?.lookupCount == 3 && memory?.lookupDays == 3 && memory?.earlier.count == 2
        && memory?.earlier.first?.date == now.addingTimeInterval(-day)
        && memory?.related.first?.term == "effect" && memory?.questions.count == 1,
      "learner memory must count earlier sittings, leaving out the one under way",
      &failures
    )
    check(
      LearningLedger.memory(for: nil, in: [], habits: [], now: now) == nil,
      "a first lookup with no habits should carry no memory",
      &failures
    )

    let definition = TranslationAction.builtIns.first { $0.mode == .definition }!
    let translate = TranslationAction.builtIns.first { $0.mode == .translate }!
    let plain = PromptBuilder.build(text: "affect", source: .english, target: .simplifiedChinese, action: definition)
    let remembered = PromptBuilder.build(
      text: "affect", source: .english, target: .simplifiedChinese, action: definition, memory: memory
    )
    check(
      remembered.system.contains("memory tip") && remembered.user.contains("<untrusted-learner-memory>")
        && remembered.user.contains("&lt;b&gt;affect&lt;/b&gt;") && !remembered.user.contains("<b>affect")
        && remembered.user.contains("related term: effect (confusable)")
        && remembered.user.hasPrefix(plain.user),
      "an explanation must receive the record escaped, after its own request",
      &failures
    )
    check(
      PromptBuilder.build(text: "affect", source: .english, target: .simplifiedChinese, action: translate, memory: memory)
        == PromptBuilder.build(text: "affect", source: .english, target: .simplifiedChinese, action: translate)
        && PromptBuilder.build(
          text: "affect", source: .english, target: .simplifiedChinese, action: definition, writing: true, memory: memory
        ) == PromptBuilder.build(
          text: "affect", source: .english, target: .simplifiedChinese, action: definition, writing: true
        ),
      "Translate and writing replacement must never carry the study record",
      &failures
    )
    let habitOnly = LearnerMemory(
      lookupCount: 1, lookupDays: 1, earlier: [], questions: [], related: [], hook: nil, habits: [.examples]
    )
    let adaptive = PromptBuilder.build(
      text: "affect", source: .english, target: .simplifiedChinese, action: definition, memory: habitOnly
    )
    check(
      adaptive.system.contains("usually asks for two or three natural example sentences")
        && !adaptive.system.contains("memory tip"),
      "a first lookup should still get the answer the reader usually asks for",
      &failures
    )
  }

  // MARK: - Habits

  private static func habitFailures(_ failures: inout [String]) {
    check(
      LearningLedger.category(of: "这个词和 affect 有什么区别？") == .nuance
        && LearningLedger.category(of: "Can you give me some examples?") == .examples
        && LearningLedger.category(of: "怎么读？") == .pronunciation
        && LearningLedger.category(of: "嗯") == .other,
      "typed follow-ups were filed under the wrong subject",
      &failures
    )
    if let chip = FollowUpSuggestion.suggestions(for: "word", mode: nil).first(where: { $0.symbol == "link" }) {
      check(
        LearningLedger.category(of: chip.question) == .collocations,
        "a one-tap chip must be recognized exactly",
        &failures
      )
    }
    check(
      LearningLedger.habits(from: [.examples: 4, .nuance: 1, .other: 3]) == [.examples]
        && LearningLedger.habits(from: [.examples: 2]).isEmpty
        && LearningLedger.habits(from: [.other: 9]).isEmpty,
      "habits must need repetition and a real share of all questions",
      &failures
    )
  }

  // MARK: - Relations and annotation

  static func term(_ text: String, _ language: LanguageCode = .english, at date: Date, sentence: String? = nil) -> LearningTerm {
    LearningTerm(
      language: language, key: LearningLedger.key(for: text), display: text,
      forms: [LearningLedger.key(for: text)],
      encounters: [LearningEncounter(at: date, surface: text, sentence: sentence, historyIDs: [UUID()], actions: ["Definition"])]
    )
  }

  private static func analysisFailures(_ failures: inout [String]) {
    check(
      LearningRelations.score("affect", "effect") >= 0.8
        && LearningRelations.score("adapt", "adopt") >= 0.8
        && LearningRelations.score("inject", "injection") >= 0.6
        && LearningRelations.score("勉強", "強制") >= LearningRelations.threshold
        && LearningRelations.score("apple", "zebra") == 0
        && LearningRelations.score("勉強", "かばん") == 0,
      "spelling similarity misjudged a pair",
      &failures
    )
    check(
      LearningRelations.editDistance(Array("kitten"), Array("sitting"), limit: 5) == 3
        && LearningRelations.editDistance(Array("kitten"), Array("sitting"), limit: 2) == 3,
      "edit distance is wrong or does not stop at its limit",
      &failures
    )

    let now = Date(timeIntervalSince1970: 1_801_000_000)
    let affect = term("affect", at: now, sentence: "It may <affect> the result.")
    let effect = term("effect", at: now.addingTimeInterval(-86_400))
    let zebra = term("zebra", at: now)
    let candidates = LearningRelations.candidates(for: [affect], in: [affect, effect, zebra], limit: 6)
    check(
      candidates[affect.id]?.first?.id == effect.id && candidates[affect.id]?.contains { $0.id == zebra.id } == false,
      "relation candidates must come from the record, best first, and leave unrelated terms out",
      &failures
    )

    let request = LearningAnnotator.Request(term: affect, candidates: [effect])
    let prompt = LearningAnnotator.prompt(for: [request], explanationLanguage: .simplifiedChinese)
    check(
      prompt.user.contains("sitting s0") && prompt.user.contains("candidate c0: effect")
        && prompt.user.contains("&lt;affect&gt;") && !prompt.user.contains("<affect>")
        && (prompt.user.contains("Simplified Chinese") || prompt.user.contains("简体中文")),
      "the annotator prompt lost a sitting, a candidate, or its escaping",
      &failures
    )

    let reply = """
      Here you go:
      ```json
      [{"index":"0","lemma":"affect","reading":"","senses":{"s0":"影响","s9":"bogus"},
        "relations":[{"candidate":"c0","kind":"look-alike","note":"affect 多作动词，effect 多作名词。"},
                     {"candidate":"c7","kind":"synonym","note":"out of range"},
                     {"candidate":"c0","kind":"wat","note":"bad kind"}]}]
      ```
      """
    let parsed = LearningAnnotator.annotations(fromJSON: reply, for: [request])
    check(
      parsed?.count == 1 && parsed?[0].lemma == "affect" && parsed?[0].reading == nil
        && parsed?[0].senses == [affect.encounters[0].id: "影响"]
        && parsed?[0].relations == [.init(termID: effect.id, kind: .confusable, note: "affect 多作动词，effect 多作名词。")],
      "annotator replies must keep what parses and drop what does not",
      &failures
    )
    check(
      LearningAnnotator.annotations(fromJSON: "I cannot help with that.", for: [request]) == nil,
      "a reply with no array must not count as an answer",
      &failures
    )

    var terms = [affect, effect, zebra]
    if let parsed { LearningAnnotator.apply(parsed, to: &terms, now: now) }
    let annotated = terms.first { $0.id == affect.id }
    let other = terms.first { $0.id == effect.id }
    check(
      annotated?.annotationVersion == LearningAnnotator.version && annotated?.encounters[0].sense == "影响"
        && annotated?.relations?.first?.termID == effect.id && other?.relations?.first?.termID == affect.id,
      "annotations must land on the term and relations on both ends",
      &failures
    )

    let past = term("走った", .japanese, at: now.addingTimeInterval(-86_400 * 3))
    var plain = term("走る", .japanese, at: now)
    plain.relations = [LearningRelation(termID: zebra.id, kind: .sameTopic, note: "x", createdAt: now)]
    var zebraLinked = zebra
    zebraLinked.relations = [LearningRelation(termID: past.id, kind: .sameTopic, note: "y", createdAt: now)]
    var japanese = [past, plain, zebraLinked]
    LearningAnnotator.apply(
      [.init(termID: past.id, lemma: "走る", reading: "はしる", senses: [:], relations: [])], to: &japanese, now: now
    )
    let merged = japanese.first { $0.key == LearningLedger.key(for: "走る") }
    check(
      japanese.count == 2 && merged?.encounters.count == 2 && merged?.reading == "はしる"
        && merged?.forms.contains(LearningLedger.key(for: "走った")) == true
        && japanese.first { $0.id == zebra.id }?.relations?.map(\.termID) == [merged?.id].compactMap { $0 },
      "a lemma that reveals two terms are one must merge them and repoint relations",
      &failures
    )
  }

  // MARK: - Review

  private static func reviewFailures(_ failures: inout [String]) {
    let now = Date(timeIntervalSince1970: 1_802_000_000)
    let day: TimeInterval = 86_400
    let enrolled = ReviewScheduler.enroll(now: now)
    check(
      !ReviewScheduler.isDue(enrolled, now: now.addingTimeInterval(60))
        && ReviewScheduler.isDue(enrolled, now: now.addingTimeInterval(day)),
      "a newly enrolled term must wait until tomorrow",
      &failures
    )
    let first = ReviewScheduler.grade(enrolled, .good, now: now.addingTimeInterval(day))
    let second = ReviewScheduler.grade(first, .good, now: now.addingTimeInterval(2 * day))
    let third = ReviewScheduler.grade(second, .good, now: now.addingTimeInterval(5 * day))
    check(
      first.interval == 1 && second.interval == 3 && abs(third.interval - 7.5) < 0.001 && third.reps == 3,
      "good answers must space reviews out by the ease factor",
      &failures
    )
    let forgot = ReviewScheduler.grade(third, .again, now: now.addingTimeInterval(13 * day))
    check(
      forgot.reps == 0 && forgot.lapses == 1 && forgot.ease < third.ease
        && forgot.due == now.addingTimeInterval(13 * day + ReviewScheduler.relearnDelay),
      "a forgotten card must reset and come back within the session",
      &failures
    )
    let relooked = ReviewScheduler.lookedUpAgain(third, now: now.addingTimeInterval(6 * day))
    check(
      relooked.lapses == 1 && relooked.reps == 0 && relooked.due == now.addingTimeInterval(6 * day)
        && ReviewScheduler.lookedUpAgain(third, now: now.addingTimeInterval(5 * day + 60)) == third,
      "looking a term up again must count as forgetting it, except on a day it was reviewed",
      &failures
    )
    check(
      ReviewScheduler.grade(enrolled, .easy, now: now).interval == 3
        && ReviewScheduler.grade(first, .easy, now: now).interval > ReviewScheduler.grade(first, .good, now: now).interval
        && ReviewScheduler.grade(enrolled, .hard, now: now).ease < enrolled.ease,
      "easy and hard grades moved the schedule the wrong way",
      &failures
    )
  }

  // MARK: - Coach

  private static func coachFailures(_ failures: inout [String]) {
    let now = Date(timeIntervalSince1970: 1_803_000_000)
    let card = LearningCoach.card(fromJSON: """
      {"meaning":"影响","hook":"a-ffect: Action → 动作 → 动词","example":"It affects us.","exampleTranslation":"它影响我们。"}
      """)
    check(
      card?.meaning == "影响" && card?.hook.hasPrefix("a-ffect") == true && card?.contrast == nil,
      "a memory card reply did not parse",
      &failures
    )
    check(LearningCoach.card(fromJSON: "{\"meaning\":\"x\"}") == nil, "a card without a hook must be refused", &failures)

    let affect = term("affect", at: now, sentence: "It may affect the result.")
    let prompt = LearningCoach.cardPrompt(for: affect, related: [], explanation: "<b>bold</b>", explanationLanguage: .english)
    check(
      prompt.user.contains("met in: It may affect the result.") && prompt.user.contains("&lt;b&gt;bold"),
      "the card prompt must quote the reader's own sentence, escaped",
      &failures
    )

    let effect = term("effect", at: now)
    let input = LearningCoach.ReportInput(
      periodStart: now.addingTimeInterval(-7 * 86_400), periodEnd: now,
      stats: LearningStats(lookups: 5, newTerms: 2, repeatedTerms: 1, followUps: 3, sentenceLookups: 1, categoryCounts: ["nuance": 2]),
      terms: [affect, effect], passages: ["A long passage about something."], passageQuestions: ["why?"]
    )
    let reportPrompt = LearningCoach.reportPrompt(input, explanationLanguage: .simplifiedChinese)
    check(
      reportPrompt.user.contains("t0: affect") && reportPrompt.user.contains("t1: effect")
        && reportPrompt.user.contains("follow-up subjects: nuance 2"),
      "the report prompt must label every term it may cite",
      &failures
    )
    let report = LearningCoach.report(fromJSON: """
      {"summary":"本周易混词多。","issues":[{"title":"形近词混淆","detail":"affect 与 effect","suggestion":"对比记忆","terms":["t0","t1","t9","x"]},
      {"detail":"no title"}],"focus":["t1","t1","t5"]}
      """, input: input, now: now)
    check(
      report?.summary == "本周易混词多。" && report?.issues.count == 1
        && report?.issues.first?.termIDs == [affect.id, effect.id] && report?.focusTermIDs == [effect.id],
      "a report must keep only issues it can show and terms that are in the record",
      &failures
    )

    let history = [
      entry("affect", at: now.addingTimeInterval(-3_600), questions: ["和 effect 的区别？"]),
      entry("This sentence is long enough to be a passage, with a clause.", at: now.addingTimeInterval(-7_200), action: "Analyze", questions: ["语法要点？"]),
      entry("old", at: now.addingTimeInterval(-30 * 86_400)),
    ]
    var recorded: [LearningTerm] = []
    for item in history { LearningLedger.record(item, into: &recorded) }
    let stats = LearningLedger.stats(terms: recorded, history: history, from: now.addingTimeInterval(-7 * 86_400), to: now)
    check(
      stats.lookups == 1 && stats.newTerms == 1 && stats.followUps == 2 && stats.sentenceLookups == 1
        && stats.categoryCounts["nuance"] == 1 && stats.categoryCounts["grammar"] == 1,
      "period stats miscounted lookups, passages, or follow-ups",
      &failures
    )
  }

  // MARK: - Agent client

  static func configuration(_ provider: ProviderKind, model: String) -> ProviderConfiguration {
    ProviderConfiguration(provider: provider, endpoint: provider.defaultEndpoint, model: model)
  }

  private static func agentFailures(_ failures: inout [String]) {
    var codex = configuration(.openAI, model: "gpt-5")
    codex.authMode = .oauthCodex
    check(
      AgentProtocol.of(configuration(.anthropic, model: "claude-sonnet-5-5")) == .anthropic
        && AgentProtocol.of(configuration(.openAI, model: "gpt-5")) == .openAI
        && AgentProtocol.of(configuration(.deepSeek, model: "deepseek-chat")) == .openAI
        && AgentProtocol.of(configuration(.gemini, model: "gemini-2.5-flash")) == .textJSON
        && AgentProtocol.of(configuration(.ollama, model: "llama3")) == .textJSON
        && AgentProtocol.of(codex) == .textJSON,
      "each connection must be asked to use tools in a protocol it speaks",
      &failures
    )

    let tools = [LearningTools.getTerm, LearningTools.searchTerms]
    let call = AgentToolCall(id: "toolu_1", name: "get_term", arguments: #"{"term":"affect"}"#)
    let messages: [AgentMessage] = [
      .user("Why do I keep forgetting affect?"),
      .assistant(text: "Let me look.", toolCalls: [call], raw: nil),
      .toolResult(callID: "toolu_1", name: "get_term", content: #"{"term":"affect"}"#),
    ]
    let anthropic = try? AgentClient.request(
      system: "SYSTEM", messages: messages, tools: tools, protocol: .anthropic,
      configuration: configuration(.anthropic, model: "claude-sonnet-5-5"), apiKey: "key", accountId: nil
    )
    let anthropicBody = anthropic?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let anthropicMessages = anthropicBody?["messages"] as? [[String: Any]]
    let resultTurn = (anthropicMessages?.last?["content"] as? [[String: Any]])?.first
    let toolUse = (anthropicMessages?[1]["content"] as? [[String: Any]])?.last
    check(
      anthropicBody?["stream"] as? Bool == false && anthropicBody?["system"] as? String == "SYSTEM"
        && (anthropicBody?["tools"] as? [[String: Any]])?.first?["input_schema"] != nil
        && anthropicBody?["temperature"] == nil
        && anthropicMessages?.count == 3 && resultTurn?["type"] as? String == "tool_result"
        && resultTurn?["tool_use_id"] as? String == "toolu_1"
        && toolUse?["type"] as? String == "tool_use" && (toolUse?["input"] as? [String: Any])?["term"] as? String == "affect"
        && anthropic?.value(forHTTPHeaderField: "x-api-key") == "key",
      "an Anthropic tool turn must carry tools, tool_use, and tool_result in the Messages shape",
      &failures
    )
    let thinking = #"[{"type":"thinking","thinking":"hm","signature":"sig"},{"type":"tool_use","id":"toolu_1","name":"get_term","input":{"term":"affect"}}]"#
    let echoed = AgentClient.anthropicMessages([.user("q"), .assistant(text: "", toolCalls: [call], raw: thinking)])
    check(
      ((echoed.last?["content"] as? [[String: Any]])?.first?["signature"] as? String) == "sig",
      "Claude's thinking blocks must be echoed back exactly as they came",
      &failures
    )

    let openAI = try? AgentClient.request(
      system: "SYSTEM", messages: messages, tools: tools, protocol: .openAI,
      configuration: configuration(.openAI, model: "gpt-4o-mini"), apiKey: "key", accountId: nil
    )
    let openAIBody = openAI?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let openAIMessages = openAIBody?["messages"] as? [[String: Any]]
    check(
      openAIBody?["stream"] as? Bool == false
        && ((openAIBody?["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])?["name"] as? String == "get_term"
        && openAIMessages?.map { $0["role"] as? String ?? "" } == ["system", "user", "assistant", "tool"]
        && (openAIMessages?[2]["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "toolu_1"
        && openAIMessages?[3]["tool_call_id"] as? String == "toolu_1",
      "an OpenAI tool turn must carry tools, tool_calls, and tool messages in the Chat Completions shape",
      &failures
    )

    let anthropicReply = AgentClient.anthropicReply(Data(#"""
      {"content":[{"type":"thinking","thinking":"x","signature":"s"},{"type":"text","text":"Checking."},
      {"type":"tool_use","id":"toolu_9","name":"search_terms","input":{"filter":"stubborn"}}],"stop_reason":"tool_use"}
      """#.utf8))
    check(
      anthropicReply?.text == "Checking." && anthropicReply?.toolCalls.first?.id == "toolu_9"
        && anthropicReply?.toolCalls.first?.argumentObject["filter"] as? String == "stubborn"
        && anthropicReply?.raw?.contains("signature") == true,
      "an Anthropic reply must yield its text, its tool calls, and its raw blocks",
      &failures
    )
    let openAIReply = AgentClient.openAIReply(Data(#"""
      {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
      {"id":"call_1","type":"function","function":{"name":"get_term","arguments":"{\"term\":\"adopt\"}"}},
      {"id":"call_2","type":"function","function":{"name":"get_stats","arguments":{"days":14}}}]}}]}
      """#.utf8))
    check(
      openAIReply?.text == "" && openAIReply?.toolCalls.count == 2
        && openAIReply?.toolCalls[0].argumentObject["term"] as? String == "adopt"
        && LearningTools.int(openAIReply?.toolCalls[1].argumentObject["days"]) == 14,
      "an OpenAI reply must yield tool calls whether arguments come as text or as an object",
      &failures
    )

    let text = AgentClient.textPrompt(system: "SYSTEM", messages: messages + [.toolResult(callID: "x", name: "get_stats", content: "{}")], tools: tools)
    check(
      text.system.contains("- get_term:") && text.system.contains(#"{"tool_calls":"#)
        && text.user.hasPrefix("<tool-results>") && text.user.contains("[get_term]") && text.user.contains("[get_stats]")
        && text.priorTurns.last?.content.contains(#""name":"get_term""#) == true,
      "the prompt-described protocol must list the tools and return results in one turn",
      &failures
    )
    let requested = AgentClient.textReply("```json\n{\"tool_calls\":[{\"name\":\"get_term\",\"arguments\":{\"term\":\"affect\"}}]}\n```")
    let answered = AgentClient.textReply("You keep mixing **affect** and effect.")
    check(
      requested.toolCalls.first?.name == "get_term" && requested.toolCalls.first?.argumentObject["term"] as? String == "affect"
        && answered.toolCalls.isEmpty && answered.text.hasPrefix("You keep"),
      "a prompt-described reply must be read as a tool request or as the answer",
      &failures
    )
  }

  // MARK: - Tools

  private static func toolFailures(_ failures: inout [String]) {
    let now = Date(timeIntervalSince1970: 1_804_000_000)
    let day: TimeInterval = 86_400
    var affect = term("affect", at: now.addingTimeInterval(-3 * day), sentence: "It may affect the result.")
    affect.encounters.append(LearningEncounter(at: now.addingTimeInterval(-day), surface: "affected", sentence: "It affected us.", historyIDs: [UUID()], actions: ["Definition"], sense: "influence"))
    affect.encounters.append(LearningEncounter(at: now, surface: "affect", historyIDs: [UUID()], actions: ["Definition"]))
    affect.forms.append(LearningLedger.key(for: "affected"))
    let effect = term("effect", at: now)
    let study = term("勉強", .japanese, at: now)
    affect.relations = [LearningRelation(termID: effect.id, kind: .confusable, note: "verb vs noun", createdAt: now)]
    affect.review = ReviewScheduler.enroll(now: now.addingTimeInterval(-2 * day))
    let terms = [affect, effect, study]

    check(
      LearningTools.searchTerms(["filter": "repeated"], in: terms, now: now).map { $0["term"] as? String } == ["affect"]
        && LearningTools.searchTerms(["filter": "due"], in: terms, now: now).count == 1
        && LearningTools.searchTerms(["language": "ja"], in: terms, now: now).first?["term"] as? String == "勉強"
        && LearningTools.searchTerms(["query": "influence"], in: terms, now: now).count == 1
        && LearningTools.searchTerms(["limit": 1], in: terms, now: now).count == 1,
      "search_terms filtered the record wrongly",
      &failures
    )
    check(
      LearningTools.term(named: "Affected", in: terms)?.id == affect.id && LearningTools.term(named: "zebra", in: terms) == nil,
      "a tool must find a term by any spelling the record knows",
      &failures
    )
    let detail = LearningTools.termDetail(affect, in: terms, latestExplanation: "**affect** means…", now: now)
    let sittings = detail["sittings"] as? [[String: Any]]
    check(
      sittings?.count == 3 && sittings?[1]["sense"] as? String == "influence"
        && (detail["related"] as? [[String: Any]])?.first?["term"] as? String == "effect"
        && detail["latestExplanation"] as? String == "**affect** means…" && detail["notSticking"] as? Bool == true,
      "get_term must return the sittings, relations, and the latest explanation",
      &failures
    )

    let history = [
      entry("affect", at: now.addingTimeInterval(-day), questions: ["和 effect 的区别？"]),
      entry("old word", at: now.addingTimeInterval(-40 * day)),
    ]
    check(
      LearningTools.searchHistory(["query": "effect 的区别"], in: history, now: now).count == 1
        && LearningTools.searchHistory(["days": 7], in: history, now: now).count == 1
        && LearningTools.searchHistory([:], in: history, now: now).count == 2,
      "search_history must match follow-up questions and respect its window",
      &failures
    )

    check(
      LearningTools.isEnglishWord("affect") && LearningTools.isEnglishWord("take off")
        && !LearningTools.isEnglishWord("勉強") && !LearningTools.isEnglishWord("a/b")
        && LearningTools.datamuseURL(word: "affect", relation: "synonyms")?.absoluteString == "https://api.datamuse.com/words?rel_syn=affect&max=15"
        && LearningTools.datamuseURL(word: "affect", relation: "bogus") == nil
        && LearningTools.dictionaryURL(word: "take off")?.absoluteString == "https://api.dictionaryapi.dev/api/v2/entries/en/take%20off",
      "public dictionary lookups must send one English word and nothing else",
      &failures
    )
    let related = LearningTools.datamuseResult(Data(#"[{"word":"impact","score":100},{"word":"touch"}]"#.utf8))
    let entryResult = LearningTools.dictionaryResult(Data(#"""
      [{"word":"affect","phonetic":"/əˈfɛkt/","meanings":[{"partOfSpeech":"verb","definitions":[{"definition":"To influence.","example":"It affects us."}],"synonyms":["influence"]}]}]
      """#.utf8))
    check(
      related.map { $0["word"] as? String } == ["impact", "touch"]
        && entryResult["phonetic"] as? String == "/əˈfɛkt/"
        && ((entryResult["meanings"] as? [[String: Any]])?.first?["synonyms"] as? [String]) == ["influence"]
        && LearningTools.dictionaryResult(Data("{}".utf8))["found"] as? Bool == false,
      "dictionary API replies were not read",
      &failures
    )
    check(
      LearningTools.json(["text": String(repeating: "x", count: 20_000)]).count < 12_100,
      "a tool result must be bounded",
      &failures
    )

    var backlog: [LearningTerm] = []
    for index in 0..<25 {
      var item = term("word\(index)", at: now.addingTimeInterval(-Double(index) * 60))
      item.encounters.append(LearningEncounter(at: now.addingTimeInterval(-Double(index) * 60 - 2 * day), surface: "word\(index)", historyIDs: [UUID()], actions: []))
      if index == 24 {
        item.encounters.append(LearningEncounter(at: now.addingTimeInterval(-5 * day), surface: "word24", historyIDs: [UUID()], actions: []))
      }
      backlog.append(item)
    }
    let enrolled = ReviewScheduler.enrollBacklog(backlog + [term("single", at: now)], now: now)
    let dueToday = enrolled.filter { $0.review.map { ReviewScheduler.isDue($0, now: now) } ?? false }
    check(
      enrolled.filter { $0.review != nil }.count == 25 && dueToday.count == 10
        && dueToday.contains { $0.display == "word24" } && enrolled.last?.review == nil,
      "a history backlog must be enrolled ten a day, the stubborn ones first",
      &failures
    )
  }

  private static func check(_ condition: @autoclosure () -> Bool, _ message: String, _ failures: inout [String]) {
    if !condition() { failures.append(message) }
  }
}
