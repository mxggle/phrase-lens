import Foundation

/// The assistant's background work: what follows a new sitting, annotation,
/// memory cards, the review queue, and the weekly diagnosis.
extension LearningModel {
  // MARK: - After a sitting

  /// A term has just been met in a new sitting.
  func didOpenSitting(on termID: UUID, now: Date = Date()) {
    guard var term = term(id: termID) else { return }
    if let review = term.review {
      term.review = ReviewScheduler.lookedUpAgain(review, now: now)
    } else if LearningLedger.isRepeat(term) {
      term.review = ReviewScheduler.enroll(now: now)
    }
    if term.review != self.term(id: termID)?.review { update([term]) }
    if LearningLedger.isStubborn(term) { collectIfNeeded(term) }
    scheduleAnalysis()
  }

  /// Saves a term that keeps coming back to Vocabulary, once.
  func collectIfNeeded(_ term: LearningTerm, now: Date = Date()) {
    guard settingsStore.settings.learningAutoCollect, term.autoCollectedAt == nil,
      isCollected?(term) == false
    else { return }
    let explanation = term.card.map { [$0.meaning, $0.hook].joined(separator: "\n\n") }
      ?? latestExplanation(for: term)
    guard let explanation, !explanation.isEmpty, var current = self.term(id: term.id) else { return }
    onCollect?(term, explanation)
    current.autoCollectedAt = now
    update([current])
  }

  /// The most recent answer the reader got for this term.
  func latestExplanation(for term: LearningTerm) -> String? {
    guard let history = historyProvider?() else { return nil }
    let ids = Set(term.encounters.flatMap(\.historyIDs))
    return history.filter { ids.contains($0.id) }.max { $0.createdAt < $1.createdAt }?.translatedText
  }

  // MARK: - Connection

  /// Background work follows the global default connection, the way
  /// Vocabulary's organizer does.
  private func resolvedConnection() -> (AIConnection, ProviderConfiguration)? {
    try? settingsStore.resolve(TranslationAction(name: "Learning assistant"))
  }

  /// Whether the default connection is ready: resolved, with a model and the
  /// credentials it needs.
  var canAnalyze: Bool { settingsStore.isConfigured(TranslationAction(name: "Learning assistant")) }

  // MARK: - Annotation

  var pendingAnnotation: [LearningTerm] {
    terms.filter { term in
      term.annotationVersion != LearningAnnotator.version
        || term.encounters.contains { $0.at > (term.annotatedAt ?? .distantPast) }
    }
  }

  /// Terms that keep coming back are worth the most, then the newest.
  private func prioritized(_ terms: [LearningTerm]) -> [LearningTerm] {
    terms.sorted { lhs, rhs in
      lhs.encounters.count == rhs.encounters.count
        ? lhs.lastSeen > rhs.lastSeen
        : lhs.encounters.count > rhs.encounters.count
    }
  }

  /// Runs a little annotation a short while after lookups settle, so a burst
  /// of them shares one request. Bounded, since it runs unattended.
  func scheduleAnalysis(after delay: Duration = .seconds(20)) {
    guard isEnabled, settingsStore.settings.learningAutoAnalyze, analysisTask == nil, canAnalyze else { return }
    scheduledAnalysis?.cancel()
    scheduledAnalysis = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self, self.analysisTask == nil else { return }
      let task = Task { await self.runAnalysis(maximumBatches: 2, announcing: false) }
      self.analysisTask = task
      await task.value
      self.analysisTask = nil
    }
  }

  /// Annotates everything pending, with progress.
  func analyzeAll() {
    guard analysisTask == nil else { return }
    scheduledAnalysis?.cancel()
    errorMessage = nil
    analysisTask = Task { [weak self] in
      await self?.runAnalysis(maximumBatches: nil, announcing: true)
      self?.analysisTask = nil
    }
  }

  func cancelAnalysis() {
    analysisTask?.cancel()
    analysisTask = nil
    analysisProgress = nil
  }

  private func runAnalysis(maximumBatches: Int?, announcing: Bool) async {
    let pending = prioritized(pendingAnnotation)
    guard let (connection, configuration) = resolvedConnection() else {
      if announcing { errorMessage = TranslationError.missingAPIKey.localizedDescription }
      return
    }
    let selected = maximumBatches.map { Array(pending.prefix($0 * LearningAnnotator.batchSize)) } ?? pending
    let proxy = settingsStore.settings.proxy
    let language = settingsStore.settings.targetLanguage
    if announcing { analysisProgress = VocabularyOrganizeProgress(completed: 0, total: selected.count) }
    defer { if announcing { analysisProgress = nil } }

    var done = 0
    do {
      if !selected.isEmpty {
        let (key, accountId) = try await settingsStore.validCredentials(for: connection, proxy: proxy)
        for start in stride(from: 0, to: selected.count, by: LearningAnnotator.batchSize) {
          try Task.checkCancellation()
          // Read the batch afresh: lookups and deletions go on while it runs.
          let batch = selected[start..<min(start + LearningAnnotator.batchSize, selected.count)]
            .compactMap { term(id: $0.id) }
          let snapshot = terms
          let candidates = await Task.detached(priority: .utility) {
            LearningRelations.candidates(for: batch, in: snapshot, limit: LearningAnnotator.candidateLimit)
          }.value
          let requests = batch.map { LearningAnnotator.Request(term: $0, candidates: candidates[$0.id] ?? []) }
          if let annotations = try await annotator.annotate(
            requests, explanationLanguage: language, configuration: configuration,
            apiKey: key, accountId: accountId, proxy: proxy
          ) {
            var updated = terms
            LearningAnnotator.apply(annotations, to: &updated)
            replaceTerms(updated)
          }
          done += batch.count
          if announcing { analysisProgress = VocabularyOrganizeProgress(completed: done, total: selected.count) }
        }
      }
      await makeMissingCards(limit: announcing ? 6 : 2, announcing: announcing)
    } catch is CancellationError {
    } catch TranslationError.cancelled {
    } catch {
      if announcing { errorMessage = error.localizedDescription }
    }
  }

  // MARK: - Cards

  private func makeMissingCards(limit: Int, announcing: Bool) async {
    let needing = terms
      .filter { LearningLedger.isStubborn($0) && $0.card == nil }
      .sorted { $0.lastSeen > $1.lastSeen }
      .prefix(limit)
    for term in needing {
      guard !Task.isCancelled else { return }
      await makeCard(for: term.id, announcing: announcing)
    }
  }

  /// Writes, or rewrites, the memory card for one term.
  func makeCard(for termID: UUID, announcing: Bool = true) async {
    guard !cardsInProgress.contains(termID), let term = term(id: termID) else { return }
    guard let (connection, configuration) = resolvedConnection() else {
      if announcing { errorMessage = TranslationError.missingAPIKey.localizedDescription }
      return
    }
    cardsInProgress.insert(termID)
    defer { cardsInProgress.remove(termID) }
    let relatedIDs = Set((term.relations ?? []).map(\.termID))
    let prompt = LearningCoach.cardPrompt(
      for: term,
      related: terms.filter { relatedIDs.contains($0.id) },
      explanation: latestExplanation(for: term),
      explanationLanguage: settingsStore.settings.targetLanguage
    )
    let proxy = settingsStore.settings.proxy
    do {
      let (key, accountId) = try await settingsStore.validCredentials(for: connection, proxy: proxy)
      let reply = try await coach.complete(
        prompt, configuration: configuration, apiKey: key, accountId: accountId, proxy: proxy
      )
      guard let card = LearningCoach.card(fromJSON: reply) else {
        if announcing { errorMessage = TranslationError.invalidResponse.localizedDescription }
        return
      }
      guard var current = self.term(id: termID) else { return }
      current.card = card
      update([current])
    } catch is CancellationError {
    } catch TranslationError.cancelled {
    } catch {
      if announcing { errorMessage = error.localizedDescription }
    }
  }

  // MARK: - Review

  /// What is due today: the terms that will not stick first, then by due time.
  func dueTerms(now: Date = Date()) -> [LearningTerm] {
    terms
      .filter { $0.review.map { ReviewScheduler.isDue($0, now: now) } ?? false }
      .sorted { lhs, rhs in
        let left = LearningLedger.isStubborn(lhs)
        let right = LearningLedger.isStubborn(rhs)
        if left != right { return left }
        return (lhs.review?.due ?? .distantPast) < (rhs.review?.due ?? .distantPast)
      }
  }

  var dueCount: Int { dueTerms().count }

  var enrolledTerms: [LearningTerm] {
    terms.filter { $0.review != nil }.sorted { ($0.review?.due ?? .distantPast) < ($1.review?.due ?? .distantPast) }
  }

  func enroll(_ termID: UUID, now: Date = Date()) {
    guard var term = term(id: termID), term.review == nil else { return }
    var state = ReviewScheduler.enroll(now: now)
    // Enrolled by hand means "quiz me", so it is due straight away.
    state.due = now
    term.review = state
    update([term])
  }

  func unenroll(_ termID: UUID) {
    guard var term = term(id: termID), term.review != nil else { return }
    term.review = nil
    update([term])
  }

  func grade(_ termID: UUID, _ grade: ReviewGrade, now: Date = Date()) {
    guard var term = term(id: termID), let review = term.review else { return }
    term.review = ReviewScheduler.grade(review, grade, now: now)
    update([term])
  }

  // MARK: - Report

  static let reportPeriod: TimeInterval = 7 * 86_400

  var latestReport: LearningReport? { reports.first }

  var isReportStale: Bool {
    guard let latest = reports.first else { return true }
    return Date().timeIntervalSince(latest.createdAt) >= Self.reportPeriod
  }

  /// Writes the weekly diagnosis on its own when the last one is a week old
  /// and there is enough new material to say something about.
  func writeReportIfDue() {
    guard isEnabled, settingsStore.settings.learningAutoAnalyze, isReportStale, !isWritingReport, canAnalyze,
      let history = historyProvider?()
    else { return }
    let end = Date()
    let stats = LearningLedger.stats(terms: terms, history: history, from: end.addingTimeInterval(-Self.reportPeriod), to: end)
    guard stats.lookups + stats.sentenceLookups >= 10 else { return }
    Task { await writeReport(announcing: false) }
  }

  func writeReport(announcing: Bool = true) async {
    guard !isWritingReport else { return }
    guard let (connection, configuration) = resolvedConnection() else {
      if announcing { errorMessage = TranslationError.missingAPIKey.localizedDescription }
      return
    }
    let history = historyProvider?() ?? []
    let end = Date()
    let start = end.addingTimeInterval(-Self.reportPeriod)
    let stats = LearningLedger.stats(terms: terms, history: history, from: start, to: end)
    guard stats.lookups + stats.sentenceLookups > 0 else {
      if announcing {
        errorMessage = L10n.isChinese
          ? "最近 7 天还没有可以分析的查询。" : "There are no lookups from the last 7 days to diagnose yet."
      }
      return
    }
    let passages = history.filter {
      $0.createdAt >= start && LearningLedger.isPassageStudy(text: $0.sourceText, mode: LearningLedger.mode(of: $0))
    }
    let input = LearningCoach.ReportInput(
      periodStart: start,
      periodEnd: end,
      stats: stats,
      terms: LearningCoach.reportTerms(from: terms, since: start),
      passages: passages.prefix(6).map(\.sourceText),
      passageQuestions: passages.flatMap { ($0.followUps ?? []).filter { !$0.answer.isEmpty }.map(\.question) }
    )
    isWritingReport = true
    defer { isWritingReport = false }
    let proxy = settingsStore.settings.proxy
    do {
      let (key, accountId) = try await settingsStore.validCredentials(for: connection, proxy: proxy)
      let reply = try await coach.complete(
        LearningCoach.reportPrompt(input, explanationLanguage: settingsStore.settings.targetLanguage),
        configuration: configuration, apiKey: key, accountId: accountId, proxy: proxy
      )
      guard let report = LearningCoach.report(fromJSON: reply, input: input) else {
        if announcing { errorMessage = TranslationError.invalidResponse.localizedDescription }
        return
      }
      addReport(report)
    } catch is CancellationError {
    } catch TranslationError.cancelled {
    } catch {
      if announcing { errorMessage = error.localizedDescription }
    }
  }
}
