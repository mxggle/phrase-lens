import Foundation

/// One lookup: the text, the action it runs under, and the answer streaming
/// back. Switching action or text starts the request again.
@MainActor
final class LookupSession: ObservableObject {
  @Published var text: String
  @Published private(set) var action: TranslationAction?
  @Published private(set) var output = ""
  @Published private(set) var errorMessage: String?
  @Published private(set) var isRunning = false
  /// The language the text was read as, shown beside the answer.
  @Published private(set) var detectedSource: LanguageCode = .auto

  let store: MobileSettingsStore
  private var task: Task<Void, Never>?
  /// Bumped on every start so a request that was replaced cannot write into
  /// the one that replaced it.
  private var generation = 0

  init(store: MobileSettingsStore, text: String = "") {
    self.store = store
    self.text = text
    action = store.settings.defaultAction
  }

  var actions: [TranslationAction] { store.settings.actions }

  var isMarkdown: Bool {
    guard let action else { return false }
    return PromptBuilder.expectsMarkdown(action, text: text)
  }

  func select(_ action: TranslationAction) {
    self.action = action
    run()
  }

  func run() {
    task?.cancel()
    generation += 1
    let current = generation
    output = ""
    errorMessage = nil

    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else {
      isRunning = false
      return
    }
    guard let action = action ?? store.settings.defaultAction else {
      errorMessage = L10n.isChinese ? "还没有可用的动作，请在 App 里添加一个。" : "Add an action in the app first."
      isRunning = false
      return
    }
    self.action = action

    let settings = store.settings
    let source = LanguageDetector.detect(clean)
    detectedSource = source
    let prompt = PromptBuilder.build(
      text: clean,
      source: source,
      target: settings.targetLanguage,
      action: action
    )
    let configuration = settings.configuration(for: action)
    let apiKey = MobileCredentials.apiKey(for: configuration.provider)

    isRunning = true
    task = Task { [weak self] in
      let stream = TranslationClient().stream(
        prompt: prompt,
        configuration: configuration,
        apiKey: apiKey,
        proxy: ProxySettings()
      )
      do {
        for try await chunk in stream {
          guard let self, self.generation == current else { return }
          self.output += chunk
        }
      } catch let error as TranslationError where error == .cancelled {
        // Replaced or stopped on purpose; nothing to report.
      } catch {
        guard let self, self.generation == current else { return }
        self.errorMessage = error.localizedDescription
      }
      guard let self, self.generation == current else { return }
      self.isRunning = false
    }
  }

  func stop() {
    task?.cancel()
    generation += 1
    isRunning = false
  }
}
