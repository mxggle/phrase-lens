#if DEBUG
import Foundation

/// Drives the learning assistant's model-backed work end to end from the
/// command line, against a library directory and a settings domain that are
/// both copies, so a live check never writes to the reader's own.
///
///     PhraseLens --learning-probe <library-dir> <defaults-suite> <credentials-dir> analyze|report|ask [question]
@MainActor
enum LearningProbe {
  static func run(arguments: [String]) async -> Int32 {
    guard let index = arguments.firstIndex(of: "--learning-probe"), arguments.count > index + 4 else {
      print("usage: --learning-probe <library-dir> <defaults-suite> <credentials-dir> analyze|report|ask [question]")
      return 2
    }
    let library = LibraryStore(directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
    guard let defaults = UserDefaults(suiteName: arguments[index + 2]) else { return 2 }
    let credentials = CredentialStore(directory: URL(fileURLWithPath: arguments[index + 3], isDirectory: true), defaults: defaults)
    let settings = SettingsStore(defaults: defaults, credentials: credentials)
    let command = arguments[index + 4]
    let learning = LearningModel(library: library, settingsStore: settings)
    let history = (try? await library.history()) ?? []
    learning.historyProvider = { history }
    learning.isCollected = { _ in true }
    await learning.load(history: history)

    if let (connection, configuration) = try? settings.resolve(TranslationAction(name: "probe")) {
      print("connection: \(connection.name) · \(configuration.provider.rawValue) · \(configuration.model) · protocol \(AgentProtocol.of(configuration))")
    } else {
      print("no usable connection")
      return 1
    }
    print("terms: \(learning.terms.count), pending annotation: \(learning.pendingAnnotation.count)")

    switch command {
    case "analyze":
      learning.analyzeAll()
      while learning.analysisTask != nil { try? await Task.sleep(for: .milliseconds(200)) }
      for term in learning.terms.sorted(by: { $0.lastSeen > $1.lastSeen }) {
        let senses = term.encounters.compactMap(\.sense).joined(separator: " / ")
        let related = (term.relations ?? []).compactMap { relation in
          learning.term(id: relation.termID).map { "\($0.headword) [\(relation.kind.rawValue)] \(relation.note)" }
        }
        print("- \(term.headword) lemma=\(term.lemma ?? "-") reading=\(term.reading ?? "-") senses=\(senses)")
        for line in related { print("    ↔ \(line)") }
        if let card = term.card { print("    card: \(card.meaning) | \(card.hook)") }
      }
    case "report":
      await learning.writeReport()
      if let report = learning.latestReport {
        print("summary: \(report.summary)")
        for issue in report.issues {
          let names = issue.termIDs.compactMap { learning.term(id: $0)?.headword }
          print("- \(issue.title): \(issue.detail) → \(issue.suggestion) \(names)")
        }
      }
    case "ask":
      let question = arguments.count > index + 5 ? arguments[index + 5] : "我最近学习上卡在哪里？"
      learning.askAssistant(question)
      while learning.isAssistantRunning { try? await Task.sleep(for: .milliseconds(200)) }
      for message in learning.assistantMessages where message.role == .assistant {
        for event in message.events { print("tool: \(event.summary)\(event.failed ? " (failed)" : "")") }
        print(message.isError ? "ERROR: \(message.text)" : message.text)
      }
    default:
      print("unknown command \(command)")
      return 2
    }
    if let error = learning.errorMessage { print("error: \(error)") }
    await learning.flush()
    return learning.errorMessage == nil ? 0 : 1
  }
}
#endif
