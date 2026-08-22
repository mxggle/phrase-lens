import Foundation

final class JSONFileStore<Value: Codable & Sendable>: @unchecked Sendable {
  private let directoryURL: URL
  private let fileURL: URL
  private var cached: Value?
  private var isDirectoryReady = false

  init(filename: String) {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    directoryURL = appSupport.appendingPathComponent(
      "PhraseLens",
      isDirectory: true
    )
    fileURL = directoryURL.appendingPathComponent(filename)
  }

  func load(default fallback: @autoclosure () -> Value) throws -> Value {
    if let cached { return cached }
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      let value = fallback()
      cached = value
      return value
    }
    let data = try Data(contentsOf: fileURL)
    let value = try JSONDecoder.persistence.decode(Value.self, from: data)
    cached = value
    return value
  }

  func save(_ value: Value) throws {
    if !isDirectoryReady {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      isDirectoryReady = true
    }
    let data = try JSONEncoder.persistence.encode(value)
    try data.write(to: fileURL, options: [.atomic])
    cached = value
  }
}

extension JSONEncoder {
  fileprivate static var persistence: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var persistence: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

actor LibraryStore {
  private let historyFile = JSONFileStore<[HistoryEntry]>(filename: "history.json")
  private let vocabularyFile = JSONFileStore<[VocabularyEntry]>(filename: "vocabulary.json")
  private let actionsFile = JSONFileStore<[TranslationAction]>(filename: "actions.json")

  func history() throws -> [HistoryEntry] {
    try historyFile.load(default: [])
  }

  func addHistory(_ entry: HistoryEntry) throws {
    var items = try history()
    items.insert(entry, at: 0)
    if items.count > 2_000 {
      items.removeLast(items.count - 2_000)
    }
    try historyFile.save(items)
  }

  func updateHistory(_ entry: HistoryEntry) throws {
    var items = try history()
    guard let index = items.firstIndex(where: { $0.id == entry.id }) else { return }
    items[index] = entry
    try historyFile.save(items)
  }

  func removeHistory(ids: Set<UUID>) throws {
    let items = try history().filter { !ids.contains($0.id) }
    try historyFile.save(items)
  }

  func vocabulary() throws -> [VocabularyEntry] {
    try vocabularyFile.load(default: [])
  }

  func addVocabulary(_ entry: VocabularyEntry) throws {
    var entry = entry
    var items = try vocabulary()
    if let index = items.firstIndex(where: {
      $0.word.localizedCaseInsensitiveCompare(entry.word) == .orderedSame
    }) {
      // Collecting a word twice replaces the explanation, and the fresh one is
      // what the next tagging run reads. Until that run lands the old filing is
      // still the best answer there is, so the card keeps its badges instead of
      // blanking and refilling.
      entry.tags = entry.tags ?? items[index].tags
      items[index] = entry
    } else {
      items.insert(entry, at: 0)
    }
    try vocabularyFile.save(items)
  }

  /// Files tags against whatever is on disk now, and hands back the result.
  ///
  /// Tagging runs in the background while the reader keeps collecting and
  /// deleting, so a batch sent a minute ago describes a list that has since
  /// moved. Merging into the current file rather than writing back the
  /// snapshot the batch was built from is what keeps a slow reply from
  /// resurrecting a word that was deleted while it was in flight.
  func applyVocabularyTags(_ tags: [UUID: VocabularyTags]) throws -> [VocabularyEntry] {
    guard !tags.isEmpty else { return try vocabulary() }
    var items = try vocabulary()
    var changed = false
    for index in items.indices {
      guard let update = tags[items[index].id] else { continue }
      items[index].tags = update
      changed = true
    }
    guard changed else { return items }
    try vocabularyFile.save(items)
    return items
  }

  func removeVocabulary(ids: Set<UUID>) throws {
    let items = try vocabulary().filter { !ids.contains($0.id) }
    try vocabularyFile.save(items)
  }

  func customActions() throws -> [TranslationAction] {
    try actionsFile.load(default: [])
  }

  func saveCustomActions(_ actions: [TranslationAction]) throws {
    try actionsFile.save(actions)
  }
}
