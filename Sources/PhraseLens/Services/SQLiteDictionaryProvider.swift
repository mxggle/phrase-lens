import Foundation
import SQLite3

/// Connections are opened/closed within a single actor turn. No pointers cross
/// suspension points, and disk/JSON work never runs on the UI actor.
actor SQLiteDictionaryProvider: DictionaryProvider {
  nonisolated let descriptor: DictionaryDescriptor
  let databaseURL: URL

  init(databaseURL: URL, descriptor: DictionaryDescriptor) {
    self.databaseURL = databaseURL
    self.descriptor = descriptor
  }

  func lookup(_ candidates: [LexicalCandidate], sourceLanguage: String, definitionLanguage: String) throws -> [DictionaryMatch] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      if let database { sqlite3_close(database) }
      throw DictionaryDataError.unavailable
    }
    defer { sqlite3_close(database) }
    var metadata: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT value FROM metadata WHERE key='manifest'", -1, &metadata, nil) == SQLITE_OK else {
      throw DictionaryDataError.invalid
    }
    defer { sqlite3_finalize(metadata) }
    guard sqlite3_step(metadata) == SQLITE_ROW, let raw = sqlite3_column_text(metadata, 0) else {
      throw DictionaryDataError.invalid
    }
    let manifest = Data(String(cString: raw).utf8)
    guard try JSONDecoder().decode(DictionaryPackVersion.self, from: manifest).schemaVersion == 1,
      try JSONDecoder().decode(DictionaryDescriptor.self, from: manifest) == descriptor else {
      throw DictionaryDataError.invalid
    }
    var statement: OpaquePointer?
    let sql = "SELECT e.payload, f.kind FROM forms f JOIN entries e ON e.id=f.entry_id WHERE f.language=? AND f.term=? AND json_extract(e.payload, '$.definitionLanguage')=? ORDER BY CASE f.kind WHEN 'headword' THEN 0 WHEN 'reading' THEN 1 ELSE 2 END, e.id LIMIT 40"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw DictionaryDataError.invalid }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    var matches: [DictionaryMatch] = []
    var seen = Set<String>()
    for candidate in candidates {
      try Task.checkCancellation()
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      sqlite3_bind_text(statement, 1, sourceLanguage, -1, transient)
      sqlite3_bind_text(statement, 2, candidate.text, -1, transient)
      sqlite3_bind_text(statement, 3, definitionLanguage, -1, transient)
      var step = sqlite3_step(statement)
      while step == SQLITE_ROW {
        guard let bytes = sqlite3_column_text(statement, 0), let kind = sqlite3_column_text(statement, 1) else {
          throw DictionaryDataError.invalid
        }
        let entry = try JSONDecoder().decode(DictionaryEntry.self, from: Data(String(cString: bytes).utf8))
        guard entry.sourceLanguage == sourceLanguage,
          descriptor.definitionLanguages.contains(entry.definitionLanguage) else { throw DictionaryDataError.invalid }
        if seen.insert(entry.id).inserted {
          matches.append(DictionaryMatch(entry: entry, dictionary: descriptor, matchedForm: candidate.text,
                                         matchKind: String(cString: kind)))
        }
        step = sqlite3_step(statement)
      }
      guard step == SQLITE_DONE else { throw DictionaryDataError.invalid }
    }
    return matches
  }
}

private struct DictionaryPackVersion: Decodable {
  var schemaVersion: Int
}

enum DictionaryDataError: LocalizedError {
  case unavailable, invalid
  var errorDescription: String? {
    switch self {
    case .unavailable: "The offline dictionary could not be opened. Reinstall the app to restore its data."
    case .invalid: "The dictionary data is incompatible or damaged."
    }
  }
}

enum BundledDictionaries {
  static func registry() throws -> DictionaryRegistry {
    let resources: Bundle
    if Bundle.main.bundleURL.pathExtension == "app" {
      // SwiftPM's generated accessor expects a bundle at the .app root, which
      // codesign rejects. Packaged apps use Contents/Resources and never fall
      // back to the developer's build directory if their data is missing.
      guard let url = Bundle.main.resourceURL?.appendingPathComponent("PhraseLens_PhraseLens.bundle"),
        let bundle = Bundle(url: url) else { throw DictionaryDataError.unavailable }
      resources = bundle
    } else { resources = Bundle.module }
    guard let directory = resources.url(forResource: "Dictionaries", withExtension: nil) else {
      throw DictionaryDataError.unavailable
    }
    let manifests = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    let providers: [any DictionaryProvider] = try manifests.map { url in
      let data = try Data(contentsOf: url)
      guard try JSONDecoder().decode(DictionaryPackVersion.self, from: data).schemaVersion == 1 else {
        throw DictionaryDataError.invalid
      }
      let descriptor = try JSONDecoder().decode(DictionaryDescriptor.self, from: data)
      return SQLiteDictionaryProvider(databaseURL: url.deletingPathExtension().appendingPathExtension("sqlite"), descriptor: descriptor)
    }
    guard !providers.isEmpty else { throw DictionaryDataError.unavailable }
    return DictionaryRegistry(providers: providers)
  }
}
