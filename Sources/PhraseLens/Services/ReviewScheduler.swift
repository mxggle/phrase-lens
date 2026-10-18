import Foundation

/// Spaced repetition for the terms the reader keeps looking up.
///
/// A small SM-2 variant. Its one addition is the signal this app has and a
/// flashcard app does not: looking a term up again on a later day is a
/// forgotten review the reader never had to grade.
enum ReviewScheduler {
  static let startingEase = 2.5
  static let minimumEase = 1.3
  static let maximumEase = 3.0
  /// A forgotten card comes back within the same session.
  static let relearnDelay: TimeInterval = 10 * 60
  private static let day: TimeInterval = 86_400

  /// A newly enrolled term, first due tomorrow: it was just looked up, so
  /// asking about it today would only test short-term memory.
  static func enroll(now: Date) -> ReviewState {
    ReviewState(
      enrolledAt: now, due: now.addingTimeInterval(20 * 3_600), interval: 0,
      ease: startingEase, reps: 0, lapses: 0
    )
  }

  static func grade(_ state: ReviewState, _ grade: ReviewGrade, now: Date) -> ReviewState {
    var next = state
    next.lastReviewedAt = now
    next.lastGrade = grade
    switch grade {
    case .again:
      next.reps = 0
      next.lapses += 1
      next.ease = max(minimumEase, state.ease - 0.2)
      next.interval = 0
      next.due = now.addingTimeInterval(relearnDelay)
      return next
    case .hard:
      next.ease = max(minimumEase, state.ease - 0.15)
      next.interval = state.reps == 0 ? 1 : max(1, state.interval * 1.2)
    case .good:
      next.interval = goodInterval(state)
    case .easy:
      next.ease = min(maximumEase, state.ease + 0.15)
      // Always further out than Good, or the two buttons mean the same thing.
      next.interval = state.reps == 0 ? 3 : max(goodInterval(state) + 1, state.interval * state.ease * 1.3)
    }
    next.reps += 1
    next.due = now.addingTimeInterval(next.interval * day)
    return next
  }

  private static func goodInterval(_ state: ReviewState) -> Double {
    state.reps == 0 ? 1 : (state.reps == 1 ? 3 : max(1, state.interval * state.ease))
  }

  /// The term was looked up again: whatever the schedule said, it was not
  /// remembered. Lookups on the day a review already happened do not count.
  static func lookedUpAgain(_ state: ReviewState, now: Date, calendar: Calendar = .current) -> ReviewState {
    if let last = state.lastReviewedAt, calendar.isDate(last, inSameDayAs: now) { return state }
    if calendar.isDate(state.enrolledAt, inSameDayAs: now) { return state }
    var next = state
    next.reps = 0
    next.lapses += 1
    next.ease = max(minimumEase, state.ease - 0.2)
    next.interval = 0
    next.due = now
    return next
  }

  /// How many backlog terms are scheduled for each day.
  static let backlogPerDay = 10

  /// Enrolls the repeats found in history that predates the assistant.
  ///
  /// A long history can hold a hundred of them, and a first review with a
  /// hundred cards is one nobody finishes, so they are spread out: the ones
  /// that will not stick first, ten a day.
  static func enrollBacklog(_ terms: [LearningTerm], now: Date, calendar: Calendar = .current) -> [LearningTerm] {
    let backlog = terms.indices
      .filter { terms[$0].review == nil && LearningLedger.isRepeat(terms[$0]) }
      .sorted { lhs, rhs in
        let left = LearningLedger.isStubborn(terms[lhs], calendar: calendar)
        let right = LearningLedger.isStubborn(terms[rhs], calendar: calendar)
        if left != right { return left }
        return terms[lhs].lastSeen > terms[rhs].lastSeen
      }
    var result = terms
    for (position, index) in backlog.enumerated() {
      var state = enroll(now: now)
      state.due = now.addingTimeInterval(Double(position / backlogPerDay) * day)
      result[index].review = state
    }
    return result
  }

  /// Due at any point today counts as due now: reviews are a daily sitting.
  static func isDue(_ state: ReviewState, now: Date, calendar: Calendar = .current) -> Bool {
    guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
      return state.due <= now
    }
    return state.due < endOfDay
  }
}
