import Foundation

/// One axis the saved-word list can be narrowed along.
///
/// Language pair is here beside the tagged dimensions even though no model
/// decides it: to a reader browsing the list it is one more row of the same
/// rail, and splitting "the ones a model wrote" from "the ones the app knew
/// already" would be an implementation detail on display.
enum VocabularyFacet: String, CaseIterable, Identifiable, Sendable {
  case unit
  case topic
  case partOfSpeech
  case difficulty
  case register
  case languagePair

  var id: String { rawValue }

  var title: String {
    switch self {
    case .unit: "Type"
    case .topic: "Topic"
    case .partOfSpeech: "Part of speech"
    case .difficulty: "Level"
    case .register: "Register"
    case .languagePair: "Language"
    }
  }
}

/// One selectable row of the rail: a value of a facet, and how it is written.
///
/// Identity is the facet and key alone. The label travels with the value for
/// display, but two rows for the same key are the same row however they came
/// to be spelled.
struct VocabularyFacetValue: Hashable, Identifiable, Sendable {
  /// The key an entry gets on a facet it was never filed under.
  static let untaggedKey = ""

  let facet: VocabularyFacet
  let key: String
  let label: String

  var id: String { "\(facet.rawValue)/\(key)" }
  var isUntagged: Bool { key == Self.untaggedKey }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.facet == rhs.facet && lhs.key == rhs.key
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(facet)
    hasher.combine(key)
  }

  static func untagged(_ facet: VocabularyFacet) -> Self {
    Self(facet: facet, key: untaggedKey, label: "Not tagged")
  }
}

/// What the rail currently has armed.
///
/// Values inside one facet are an OR, and facets are ANDed with each other.
/// That is how a faceted list is read everywhere else — picking a second verb
/// widens, picking a topic narrows — and the alternative makes every second
/// click empty the grid.
struct VocabularyFilter: Equatable, Sendable {
  private(set) var selection: Set<VocabularyFacetValue> = []

  var isEmpty: Bool { selection.isEmpty }
  var count: Int { selection.count }

  func isOn(_ value: VocabularyFacetValue) -> Bool { selection.contains(value) }

  mutating func toggle(_ value: VocabularyFacetValue) {
    if selection.contains(value) {
      selection.remove(value)
    } else {
      selection.insert(value)
    }
  }

  mutating func clear() { selection.removeAll() }

  /// The same filter with one facet's own choices dropped.
  func ignoring(_ facet: VocabularyFacet) -> VocabularyFilter {
    var copy = self
    copy.selection = selection.filter { $0.facet != facet }
    return copy
  }

  /// Drops choices that no longer exist — a topic whose last entry was
  /// deleted, say. Without this a stale value keeps the grid empty and the row
  /// that would let the reader turn it off is no longer drawn.
  mutating func prune(to available: Set<VocabularyFacetValue>) {
    selection = selection.filter { available.contains($0) }
  }
}

/// One block of the rail.
struct VocabularyFacetSection: Identifiable, Sendable {
  struct Row: Identifiable, Sendable {
    let value: VocabularyFacetValue
    let count: Int
    var id: String { value.id }
  }

  let facet: VocabularyFacet
  let rows: [Row]

  var id: String { facet.rawValue }
}

enum VocabularyFacets {
  /// How many entries a topic needs before it earns a row of its own.
  ///
  /// A topic with one entry is not a category, it is that entry wearing a
  /// second name, and a rail padded out with dozens of them is harder to scan
  /// than no rail at all. The entry stays reachable through search and through
  /// every other facet.
  static let topicFloor = 2

  /// Which rows of a facet an entry answers to. Empty means it was never filed
  /// under this facet, and it answers to "Not tagged" instead.
  static func values(of entry: VocabularyEntry, facet: VocabularyFacet)
    -> [VocabularyFacetValue]
  {
    switch facet {
    case .unit:
      guard let unit = entry.tags?.unit else { return [] }
      return [VocabularyFacetValue(facet: facet, key: unit.rawValue, label: unit.displayName)]
    case .partOfSpeech:
      guard let pos = entry.tags?.partOfSpeech else { return [] }
      return [VocabularyFacetValue(facet: facet, key: pos.rawValue, label: pos.displayName)]
    case .register:
      guard let register = entry.tags?.register else { return [] }
      return [
        VocabularyFacetValue(facet: facet, key: register.rawValue, label: register.displayName)
      ]
    case .difficulty:
      guard let difficulty = entry.tags?.difficulty else { return [] }
      return [
        VocabularyFacetValue(
          facet: facet,
          key: String(difficulty.rawValue),
          label: difficulty.displayName
        )
      ]
    case .topic:
      let topics = entry.tags?.topics ?? []
      return topics.map { VocabularyFacetValue(facet: facet, key: $0.lowercased(), label: $0) }
    case .languagePair:
      let key = "\(entry.sourceLanguage.rawValue)>\(entry.targetLanguage.rawValue)"
      let label = "\(entry.sourceLanguage.displayName) → \(entry.targetLanguage.displayName)"
      return [VocabularyFacetValue(facet: facet, key: key, label: label)]
    }
  }

  static func matches(_ entry: VocabularyEntry, filter: VocabularyFilter) -> Bool {
    guard !filter.isEmpty else { return true }
    let byFacet = Dictionary(grouping: filter.selection, by: \.facet)
    for (facet, wanted) in byFacet {
      let owned = values(of: entry, facet: facet)
      let answers =
        owned.isEmpty
        ? wanted.contains(where: \.isUntagged)
        : owned.contains { wanted.contains($0) }
      guard answers else { return false }
    }
    return true
  }

  static func apply(_ filter: VocabularyFilter, to entries: [VocabularyEntry])
    -> [VocabularyEntry]
  {
    guard !filter.isEmpty else { return entries }
    return entries.filter { matches($0, filter: filter) }
  }

  /// The rail, built against the entries that are in play.
  ///
  /// Counts for a facet are taken with that facet's own choices lifted, so
  /// arming "Verb" leaves "Noun · 28" beside it instead of collapsing every
  /// sibling to zero. Anything else makes the rail unusable the moment it is
  /// used once.
  static func sections(
    for entries: [VocabularyEntry],
    filter: VocabularyFilter
  ) -> [VocabularyFacetSection] {
    VocabularyFacet.allCases.compactMap { facet in
      let scope = apply(filter.ignoring(facet), to: entries)
      var counts: [VocabularyFacetValue: Int] = [:]
      var untagged = 0
      for entry in scope {
        let owned = values(of: entry, facet: facet)
        if owned.isEmpty {
          untagged += 1
        } else {
          for value in owned { counts[value, default: 0] += 1 }
        }
      }

      var rows = counts
        .map { VocabularyFacetSection.Row(value: $0.key, count: $0.value) }
        .filter { row in
          // A one-off topic is noise unless the reader is standing on it, in
          // which case removing the row would strand them inside a filter with
          // no way to leave it.
          facet != .topic || row.count >= topicFloor || filter.isOn(row.value)
        }
      rows.sort { lhs, rhs in
        if let order = declaredOrder(facet), let left = order[lhs.value.key],
          let right = order[rhs.value.key]
        {
          return left < right
        }
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        return lhs.value.label.localizedCaseInsensitiveCompare(rhs.value.label) == .orderedAscending
      }
      if untagged > 0 {
        rows.append(
          VocabularyFacetSection.Row(value: .untagged(facet), count: untagged)
        )
      }

      // One row is not a choice, it is a caption. The section is dropped
      // unless it can actually divide the collection.
      guard rows.count > 1 || rows.contains(where: { filter.isOn($0.value) }) else { return nil }
      return VocabularyFacetSection(facet: facet, rows: rows)
    }
  }

  /// Every row the rail can currently draw, for pruning a stale selection.
  static func availableValues(for entries: [VocabularyEntry]) -> Set<VocabularyFacetValue> {
    var values: Set<VocabularyFacetValue> = []
    for facet in VocabularyFacet.allCases {
      values.insert(.untagged(facet))
      for entry in entries {
        for value in self.values(of: entry, facet: facet) { values.insert(value) }
      }
    }
    return values
  }

  /// Closed dimensions keep the order they are declared in — beginner before
  /// expert, noun before particle — because that order carries meaning that
  /// sorting by count would throw away. Topic has no such order and falls
  /// through to count.
  private static func declaredOrder(_ facet: VocabularyFacet) -> [String: Int]? {
    switch facet {
    case .unit:
      Dictionary(
        uniqueKeysWithValues: VocabularyUnit.allCases.enumerated().map { ($1.rawValue, $0) })
    case .partOfSpeech:
      Dictionary(
        uniqueKeysWithValues: VocabularyPartOfSpeech.allCases.enumerated().map {
          ($1.rawValue, $0)
        })
    case .register:
      Dictionary(
        uniqueKeysWithValues: VocabularyRegister.allCases.enumerated().map { ($1.rawValue, $0) })
    case .difficulty:
      Dictionary(
        uniqueKeysWithValues: VocabularyDifficulty.allCases.enumerated().map {
          (String($1.rawValue), $0)
        })
    case .topic, .languagePair:
      nil
    }
  }

  /// The topics already in use, most-used first.
  ///
  /// This is what a tagging request offers the model to reuse. Ordering by use
  /// puts the established buckets in front of the long tail, which is what
  /// keeps a collection converging on a handful of topics instead of growing a
  /// new one per word.
  static func rankedTopics(of entries: [VocabularyEntry], limit: Int = 24) -> [String] {
    var counts: [String: (label: String, count: Int)] = [:]
    for entry in entries {
      for topic in entry.tags?.topics ?? [] {
        let key = topic.lowercased()
        counts[key] = (counts[key]?.label ?? topic, (counts[key]?.count ?? 0) + 1)
      }
    }
    return
      counts
      .values
      .sorted {
        $0.count != $1.count
          ? $0.count > $1.count
          : $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
      }
      .prefix(limit)
      .map(\.label)
  }
}

// MARK: - Grouping

/// How the collection is broken into headed sections.
///
/// Filtering and grouping answer different questions — "show me these" against
/// "show me all of it, in order" — and a reader browsing a vocabulary list
/// wants both. The axes are the ones the rail already knows how to read, so
/// grouping borrows the facets rather than inventing a parallel set; only
/// collection date is its own, since bucketing by recency is a thing to browse
/// rather than a thing to filter on.
enum VocabularyGrouping: Hashable, Identifiable, CaseIterable, Sendable {
  case none
  case facet(VocabularyFacet)
  case month

  static var allCases: [VocabularyGrouping] {
    [.none] + VocabularyFacet.allCases.map(Self.facet) + [.month]
  }

  var id: String {
    switch self {
    case .none: "none"
    case .facet(let facet): facet.rawValue
    case .month: "month"
    }
  }

  /// What the pull-down calls it when it is the armed choice.
  var title: String {
    switch self {
    case .none: "No groups"
    case .facet(let facet): facet.title
    case .month: "Collected"
    }
  }
}

/// One headed run of the collection.
struct VocabularyGroup: Identifiable, Sendable {
  let key: String
  let title: String
  let entries: [VocabularyEntry]

  var id: String { key }
}

extension VocabularyFacets {
  /// Breaks entries into sections. Empty for `.none`, which the caller draws
  /// as one ungrouped run instead.
  ///
  /// An entry filed under two topics appears under both. That is the useful
  /// reading of "group by topic" — a section should hold everything about its
  /// subject — and it means the sections can sum to more than the collection
  /// holds, which is why the count in the filter bar keeps counting entries.
  static func groups(
    of entries: [VocabularyEntry],
    by grouping: VocabularyGrouping
  ) -> [VocabularyGroup] {
    switch grouping {
    case .none:
      return []
    case .month:
      return monthGroups(of: entries)
    case .facet(let facet):
      return facetGroups(of: entries, facet: facet)
    }
  }

  private static func facetGroups(
    of entries: [VocabularyEntry],
    facet: VocabularyFacet
  ) -> [VocabularyGroup] {
    var buckets: [VocabularyFacetValue: [VocabularyEntry]] = [:]
    var untagged: [VocabularyEntry] = []
    for entry in entries {
      let values = self.values(of: entry, facet: facet)
      if values.isEmpty {
        untagged.append(entry)
      } else {
        for value in values { buckets[value, default: []].append(entry) }
      }
    }

    let order = declaredOrder(facet)
    var groups =
      buckets
      .map { VocabularyGroup(key: $0.key.id, title: $0.key.label, entries: $0.value) }
      .sorted { lhs, rhs in
        if let order, let left = order[lhs.sortKey], let right = order[rhs.sortKey] {
          return left < right
        }
        if lhs.entries.count != rhs.entries.count { return lhs.entries.count > rhs.entries.count }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      }
    if !untagged.isEmpty {
      groups.append(
        VocabularyGroup(key: "\(facet.rawValue)/untagged", title: "Not tagged", entries: untagged)
      )
    }
    return groups
  }

  /// Newest month first, which is the order the collection itself is in.
  private static func monthGroups(of entries: [VocabularyEntry]) -> [VocabularyGroup] {
    let calendar = Calendar.current
    var buckets: [String: (title: String, entries: [VocabularyEntry])] = [:]
    for entry in entries {
      let parts = calendar.dateComponents([.year, .month], from: entry.createdAt)
      guard let year = parts.year, let month = parts.month else { continue }
      // Zero-padded so the key sorts the way the calendar reads.
      let key = String(format: "%04d-%02d", year, month)
      let title = entry.createdAt.formatted(.dateTime.year().month(.wide))
      buckets[key] = (title, (buckets[key]?.entries ?? []) + [entry])
    }
    return
      buckets
      .sorted { $0.key > $1.key }
      .map { VocabularyGroup(key: $0.key, title: $0.value.title, entries: $0.value.entries) }
  }
}

extension VocabularyGroup {
  /// The bare value behind `key`, which carries its facet as a prefix.
  fileprivate var sortKey: String {
    key.split(separator: "/", maxSplits: 1).last.map(String.init) ?? key
  }
}
