import Foundation

struct DictionarySense: Codable, Hashable, Identifiable, Sendable {
  var id: String
  var glosses: [String]
  var labels: [String]
}

struct DictionaryEntry: Codable, Hashable, Identifiable, Sendable {
  var id: String
  var headword: String
  var sourceLanguage: String
  var definitionLanguage: String
  var readings: [String]
  var partOfSpeech: String?
  var senses: [DictionarySense]
  var sourceURL: String
}

struct DictionaryDescriptor: Codable, Hashable, Identifiable, Sendable {
  var id: String
  var name: String
  var revision: String
  var sourceLanguages: [String]
  var definitionLanguages: [String]
  var attribution: String
  var license: String
  var licenseURL: String
  var canPersist: Bool
  var canUseWithAI: Bool

  func supports(source: String, definition: String) -> Bool {
    sourceLanguages.contains(source) && definitionLanguages.contains(definition)
  }
}

struct DictionaryMatch: Codable, Hashable, Identifiable, Sendable {
  var entry: DictionaryEntry
  var dictionary: DictionaryDescriptor
  var matchedForm: String
  var matchKind: String
  var id: String { dictionary.id + ":" + entry.id }

  var plainText: String {
    let heading = ([entry.headword] + entry.readings).joined(separator: " · ")
    let definitions = entry.senses.enumerated().map { index, sense in
      "\(index + 1). \(sense.glosses.joined(separator: "; "))"
    }.joined(separator: "\n")
    return "\(heading)\n\(definitions)\n\n\(dictionary.attribution) · \(dictionary.license)\n\(entry.sourceURL)\n\(dictionary.licenseURL)"
  }
}

struct DictionarySnapshot: Codable, Hashable, Sendable {
  var query: String
  var definitionLanguage: String
  var matches: [DictionaryMatch]
}

struct DictionaryRequest: Sendable {
  var text: String
  var sourceOverride: String = "auto"
  var definitionLanguage: String = "zh"
  var context: String?
}

struct DictionaryLookupResult: Sendable {
  var request: DictionaryRequest
  var languages: [String]
  var matches: [DictionaryMatch]
  var notices: [String]
  var supportsPair: Bool
}

enum DictionaryLookupState {
  case idle
  case loading
  case result(DictionaryLookupResult)
  case failed(String)
}

struct LexicalCandidate: Hashable, Sendable {
  var text: String
  var reason: String
}

protocol DictionaryProvider: Sendable {
  var descriptor: DictionaryDescriptor { get }
  func lookup(_ candidates: [LexicalCandidate], sourceLanguage: String, definitionLanguage: String) async throws -> [DictionaryMatch]
}

protocol LexicalProcessor: Sendable {
  func candidates(for text: String) -> [LexicalCandidate]
}

enum DictionaryLanguages {
  static func name(_ code: String) -> String {
    if code == "zh" { return "中文" }
    if code == "auto" { return "Auto" }
    return LanguageCode(rawValue: code)?.displayName
      ?? Locale.current.localizedString(forLanguageCode: code) ?? code
  }
}
