import Foundation

struct DictionaryRegistry: Sendable {
  var providers: [any DictionaryProvider]
  var processors: [String: any LexicalProcessor] = [
    "ja": JapaneseLexicalProcessor(), "en": EnglishLexicalProcessor(),
  ]

  func lookup(_ request: DictionaryRequest) async throws -> DictionaryLookupResult {
    try Task.checkCancellation()
    let languages = DictionaryLanguageResolver.candidates(
      text: request.text, context: request.context, override: request.sourceOverride)
    var result = DictionaryLookupResult(request: request, languages: languages, matches: [], notices: [], supportsPair: false)
    for language in languages {
      let candidates = (processors[language] ?? ExactLexicalProcessor()).candidates(for: request.text)
      for provider in providers where provider.descriptor.supports(source: language, definition: request.definitionLanguage) {
        result.supportsPair = true
        do {
          let matches = try await provider.lookup(candidates, sourceLanguage: language, definitionLanguage: request.definitionLanguage)
          try Task.checkCancellation()
          result.matches += matches.filter {
            $0.entry.sourceLanguage == language && $0.entry.definitionLanguage == request.definitionLanguage
          }
        } catch is CancellationError { throw CancellationError() }
        catch { result.notices.append("\(provider.descriptor.name): \(error.localizedDescription)") }
      }
    }
    var seen = Set<String>()
    let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
    result.matches = result.matches.filter { seen.insert($0.id).inserted }
      .enumerated().sorted { left, right in
        let a = left.element.entry.headword == query ? 0 : 1
        let b = right.element.entry.headword == query ? 0 : 1
        return a == b ? left.offset < right.offset : a < b
      }.map(\.element)
    // Retain provider/source grouping for ambiguous spellings. Never merge
    // definitions from different languages just because the headword matches.
    return result
  }
}
