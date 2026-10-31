import Foundation

/// The learning assistant's state: the study record, the follow-up habits it
/// reads from history, and the background work that annotates and reviews.
///
/// The record in memory is the source of truth while the app runs. Every
/// change is written out behind it in order, so a slow write can never put an
/// older snapshot on disk after a newer one.
@MainActor
final class LearningModel: ObservableObject {
  @Published private(set) var terms: [LearningTerm] = [] {
    didSet { termIDByHistory = Self.index(terms) }
  }
  /// Which term each filed history row belongs to.
  private(set) var termIDByHistory: [UUID: UUID] = [:]
  @Published private(set) var reports: [LearningReport] = []
  /// Which part of the study section is showing, and the term open in it.
  @Published var tab: LearningTab = .overview
  @Published var selectedTermID: UUID?
  @Published var termFilter: LearningTermFilter = .all
  @Published private(set) var isLoaded = false
  /// How often this reader asks about each subject after looking up a term,
  /// and after studying a passage. Read from history, never stored.
  @Published private(set) var termHabitCounts: [FollowUpCategory: Int] = [:]
  @Published private(set) var passageHabitCounts: [FollowUpCategory: Int] = [:]

  // Background work, driven from `LearningModel+Analysis.swift`.
  /// A run the reader started, or nil when none is running.
  @Published var analysisProgress: VocabularyOrganizeProgress?
  @Published var isWritingReport = false
  @Published var cardsInProgress = Set<UUID>()
  /// The last failure of work the reader asked for. Unattended work fails
  /// quietly and is retried the next time it is due.
  @Published var errorMessage: String?
  var analysisTask: Task<Void, Never>?
  var scheduledAnalysis: Task<Void, Never>?
  let annotator = LearningAnnotator()
  let coach = LearningCoach()
  // The study assistant, driven from `LearningModel+Assistant.swift`.
  @Published var assistantMessages: [AssistantMessage] = []
  @Published var isAssistantRunning = false
  var assistantTask: Task<Void, Never>?
  let agent = AgentClient()
  /// Supplied by the owner: the history the record was filed from, and how
  /// to save a term to Vocabulary.
  var historyProvider: (() -> [HistoryEntry])?
  var isCollected: ((LearningTerm) -> Bool)?
  var onCollect: ((LearningTerm, String) -> Void)?

  let settingsStore: SettingsStore
  let library: LibraryStore
  /// What each history row's thread asked about, so a deleted row or an
  /// edited thread can be taken back out of the counts.
  private var questionCategories: [UUID: (passage: Bool, categories: [FollowUpCategory])] = [:]
  private var backfilledHistory = false
  private var isBackfilling = false
  private var pendingEntries: [HistoryEntry] = []
  private var pendingForgets = Set<UUID>()
  private var saveTask: Task<Void, Never>?

  init(library: LibraryStore, settingsStore: SettingsStore) {
    self.library = library
    self.settingsStore = settingsStore
  }

  var isEnabled: Bool { settingsStore.settings.learningEnabled }

  // MARK: - Loading

  /// Reads the record, and on first run files the history that predates it.
  func load(history: [HistoryEntry]) async {
    let stored = (try? await library.learning()) ?? LearningLibrary()
    terms = stored.terms
    reports = stored.reports
    backfilledHistory = stored.backfilledHistory
    rebuildHabits(from: history)
    isLoaded = true
    await backfillIfNeeded(history: history)
  }

  /// Files existing history once, the first time the record is switched on.
  func backfillIfNeeded(history: [HistoryEntry]) async {
    guard isLoaded, isEnabled, !backfilledHistory, !isBackfilling else { return }
    isBackfilling = true
    var filed = await Task.detached(priority: .utility) { LearningLedger.backfill(history) }.value
    // Whatever happened while the backfill ran is replayed on top of it.
    for entry in pendingEntries { LearningLedger.record(entry, into: &filed) }
    LearningLedger.forget(historyIDs: pendingForgets, in: &filed)
    pendingEntries = []
    pendingForgets = []
    isBackfilling = false
    terms = ReviewScheduler.enrollBacklog(filed, now: Date())
    backfilledHistory = true
    persist()
  }

  // MARK: - Recording

  /// Files a finished result. Returns the term it was filed under, if any.
  @discardableResult
  func record(_ entry: HistoryEntry) -> LearningTerm? {
    guard isEnabled, isLoaded else { return nil }
    guard !isBackfilling else {
      pendingEntries.append(entry)
      return nil
    }
    var updated = terms
    let before = updated.count
    guard let index = LearningLedger.record(entry, into: &updated) else { return nil }
    let isNewSitting =
      updated.count > before
      || updated[index].encounters.contains { $0.historyIDs == [entry.id] }
    terms = updated
    persist()
    if isNewSitting { didOpenSitting(on: updated[index].id) }
    return terms.first { $0.id == updated[index].id }
  }

  /// Called with the thread of a history row whenever it changes.
  func recordFollowUps(for entry: HistoryEntry) {
    updateHabits(for: entry)
    guard isEnabled, isLoaded else { return }
    let questions = (entry.followUps ?? []).filter { !$0.answer.isEmpty }.map(\.question)
    var updated = terms
    guard LearningLedger.attachFollowUps(historyID: entry.id, questions: questions, to: &updated)
    else { return }
    terms = updated
    persist()
  }

  /// Takes deleted history back out of the record.
  func forget(historyIDs: Set<UUID>) {
    for id in historyIDs { questionCategories[id] = nil }
    recountHabits()
    if isBackfilling {
      pendingForgets.formUnion(historyIDs)
      pendingEntries.removeAll { historyIDs.contains($0.id) }
    }
    var updated = terms
    LearningLedger.forget(historyIDs: historyIDs, in: &updated)
    guard updated != terms else { return }
    terms = updated
    persist()
  }

  /// Empties the record. History stays; it is not read in again.
  func clearAll() {
    terms = []
    reports = []
    backfilledHistory = true
    persist()
  }

  // MARK: - Reading the record

  func term(for text: String, language: LanguageCode) -> LearningTerm? {
    guard isLoaded else { return nil }
    return LearningLedger.term(for: text, language: language, in: terms)
  }

  func term(id: UUID) -> LearningTerm? {
    terms.first { $0.id == id }
  }

  /// What an explanation of `text` should know about the reader, or nil when
  /// the record has nothing to add or is not to be shared.
  func memory(for text: String, language: LanguageCode) -> LearnerMemory? {
    guard isEnabled, isLoaded, settingsStore.settings.learningMemoryInPrompts else { return nil }
    let isTerm = LearningLedger.isLookup(text: text, mode: nil)
    let habits = LearningLedger.habits(from: isTerm ? termHabitCounts : passageHabitCounts)
    let term = isTerm ? self.term(for: text, language: language) : nil
    return LearningLedger.memory(for: term, in: terms, habits: habits)
  }

  /// The chips under an answer, most asked-for first. Ties keep the order the
  /// chips were written in.
  func ranked(_ suggestions: [FollowUpSuggestion], forTerm isTerm: Bool) -> [FollowUpSuggestion] {
    let counts = isTerm ? termHabitCounts : passageHabitCounts
    guard !counts.isEmpty else { return suggestions }
    return suggestions.enumerated().sorted { lhs, rhs in
      let left = FollowUpCategory.of(chipSymbol: lhs.element.symbol, sentence: !isTerm).flatMap { counts[$0] } ?? 0
      let right = FollowUpCategory.of(chipSymbol: rhs.element.symbol, sentence: !isTerm).flatMap { counts[$0] } ?? 0
      return left == right ? lhs.offset < rhs.offset : left > right
    }.map(\.element)
  }

  private static func index(_ terms: [LearningTerm]) -> [UUID: UUID] {
    var index: [UUID: UUID] = [:]
    for term in terms {
      for encounter in term.encounters {
        for id in encounter.historyIDs { index[id] = term.id }
      }
    }
    return index
  }

  /// The term a history row was filed under.
  func term(forHistoryID id: UUID) -> LearningTerm? {
    termIDByHistory[id].flatMap(term(id:))
  }

  /// Opens one term's page.
  func select(_ id: UUID) {
    selectedTermID = id
    tab = .terms
  }

  /// Opens the term list under a filter.
  func showTerms(_ filter: LearningTermFilter) {
    termFilter = filter
    selectedTermID = nil
    tab = .terms
  }

  /// Relations, once per pair, newest first.
  func recentRelationPairs(limit: Int) -> [RelationPair] {
    let byID = Dictionary(terms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var pairs: [RelationPair] = []
    for term in terms {
      for relation in term.relations ?? [] where term.id.uuidString < relation.termID.uuidString {
        guard let other = byID[relation.termID] else { continue }
        pairs.append(RelationPair(id: term.id.uuidString + relation.termID.uuidString, left: term, right: other, relation: relation))
      }
    }
    return Array(pairs.sorted { $0.relation.createdAt > $1.relation.createdAt }.prefix(limit))
  }

  var repeatedTerms: [LearningTerm] {
    terms.filter(LearningLedger.isRepeat).sorted { $0.lastSeen > $1.lastSeen }
  }

  var stubbornTerms: [LearningTerm] {
    terms.filter { LearningLedger.isStubborn($0) }.sorted { $0.lastSeen > $1.lastSeen }
  }

  // MARK: - Habits

  private func rebuildHabits(from history: [HistoryEntry]) {
    questionCategories = [:]
    for entry in history { classify(entry) }
    recountHabits()
  }

  private func updateHabits(for entry: HistoryEntry) {
    classify(entry)
    recountHabits()
  }

  private func classify(_ entry: HistoryEntry) {
    let mode = LearningLedger.mode(of: entry)
    let isTerm = LearningLedger.isLookup(text: entry.sourceText, mode: mode)
    let isPassage = LearningLedger.isPassageStudy(text: entry.sourceText, mode: mode)
    let questions = (entry.followUps ?? []).filter { !$0.answer.isEmpty }.map(\.question)
    guard isTerm || isPassage, !questions.isEmpty else {
      questionCategories[entry.id] = nil
      return
    }
    questionCategories[entry.id] = (!isTerm, questions.map(LearningLedger.category(of:)))
  }

  private func recountHabits() {
    var term: [FollowUpCategory: Int] = [:]
    var passage: [FollowUpCategory: Int] = [:]
    for (isPassage, categories) in questionCategories.values {
      for category in categories {
        if isPassage { passage[category, default: 0] += 1 } else { term[category, default: 0] += 1 }
      }
    }
    if term != termHabitCounts { termHabitCounts = term }
    if passage != passageHabitCounts { passageHabitCounts = passage }
  }

  // MARK: - Background work


  /// Replaces terms in place, by id, and writes the record out.
  func update(_ changed: [LearningTerm]) {
    guard !changed.isEmpty else { return }
    let byID = Dictionary(changed.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    terms = terms.map { byID[$0.id] ?? $0 }
    persist()
  }

  /// Replaces the whole set, for merges that remove terms as well as change them.
  func replaceTerms(_ updated: [LearningTerm]) {
    terms = updated
    persist()
  }

  func addReport(_ report: LearningReport) {
    reports.insert(report, at: 0)
    if reports.count > 26 { reports.removeLast(reports.count - 26) }
    persist()
  }

  func persist() {
    let snapshot = LearningLibrary(terms: terms, reports: reports, backfilledHistory: backfilledHistory)
    let previous = saveTask
    saveTask = Task { [library] in
      await previous?.value
      try? await library.saveLearning(snapshot)
    }
  }

  func flush() async {
    await saveTask?.value
  }
}
