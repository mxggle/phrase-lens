import Foundation

enum LanguageCode: String, Codable, CaseIterable, Identifiable, Sendable {
  case auto
  case english = "en"
  case japanese = "ja"
  case simplifiedChinese = "zh-Hans"
  case traditionalChinese = "zh-Hant"
  case korean = "ko"
  case french = "fr"
  case german = "de"
  case spanish = "es"
  case portuguese = "pt"
  case italian = "it"
  case russian = "ru"
  case arabic = "ar"
  case hindi = "hi"
  case thai = "th"
  case turkish = "tr"
  case vietnamese = "vi"
  case indonesian = "id"
  case dutch = "nl"
  case polish = "pl"
  case ukrainian = "uk"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .auto: "Detect language"
    case .english: "English"
    case .japanese: "日本語"
    case .simplifiedChinese: "简体中文"
    case .traditionalChinese: "繁體中文"
    case .korean: "한국어"
    case .french: "Français"
    case .german: "Deutsch"
    case .spanish: "Español"
    case .portuguese: "Português"
    case .italian: "Italiano"
    case .russian: "Русский"
    case .arabic: "العربية"
    case .hindi: "हिन्दी"
    case .thai: "ไทย"
    case .turkish: "Türkçe"
    case .vietnamese: "Tiếng Việt"
    case .indonesian: "Bahasa Indonesia"
    case .dutch: "Nederlands"
    case .polish: "Polski"
    case .ukrainian: "Українська"
    }
  }

  var localeIdentifier: String {
    switch self {
    case .auto: Locale.current.identifier
    case .simplifiedChinese: "zh-Hans"
    case .traditionalChinese: "zh-Hant"
    default: rawValue
    }
  }

  var edgeVoiceIdentifier: String {
    switch self {
    case .auto, .english: "en-US-EmmaMultilingualNeural"
    case .japanese: "ja-JP-NanamiNeural"
    case .simplifiedChinese: "zh-CN-XiaoxiaoNeural"
    case .traditionalChinese: "zh-TW-HsiaoChenNeural"
    case .korean: "ko-KR-SunHiNeural"
    case .french: "fr-FR-DeniseNeural"
    case .german: "de-DE-KatjaNeural"
    case .spanish: "es-ES-ElviraNeural"
    case .portuguese: "pt-BR-FranciscaNeural"
    case .italian: "it-IT-ElsaNeural"
    case .russian: "ru-RU-SvetlanaNeural"
    case .arabic: "ar-SA-ZariyahNeural"
    case .hindi: "hi-IN-SwaraNeural"
    case .thai: "th-TH-PremwadeeNeural"
    case .turkish: "tr-TR-EmelNeural"
    case .vietnamese: "vi-VN-HoaiMyNeural"
    case .indonesian: "id-ID-GadisNeural"
    case .dutch: "nl-NL-ColetteNeural"
    case .polish: "pl-PL-ZofiaNeural"
    case .ukrainian: "uk-UA-PolinaNeural"
    }
  }
}

enum ActionMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case translate
  case polishing
  case summarize
  case analyze
  case explainContext
  case explainCode

  var id: String { rawValue }

  var title: String {
    switch self {
    case .translate: "Translate"
    case .polishing: "Polish"
    case .summarize: "Summarize"
    case .analyze: "Analyze"
    case .explainContext: "Explain in Context"
    case .explainCode: "Explain Code"
    }
  }

  var symbol: String {
    switch self {
    case .translate: "character.bubble"
    case .polishing: "wand.and.stars"
    case .summarize: "text.redaction"
    case .analyze: "chart.bar.doc.horizontal"
    case .explainContext: "book.pages"
    case .explainCode: "chevron.left.forwardslash.chevron.right"
    }
  }
}

struct TranslationAction: Codable, Identifiable, Hashable, Sendable {
  var id: UUID
  var name: String
  var mode: ActionMode?
  var rolePrompt: String
  var commandPrompt: String
  var outputMarkdown: Bool

  init(
    id: UUID = UUID(),
    name: String,
    mode: ActionMode? = nil,
    rolePrompt: String = "",
    commandPrompt: String = "",
    outputMarkdown: Bool = false
  ) {
    self.id = id
    self.name = name
    self.mode = mode
    self.rolePrompt = rolePrompt
    self.commandPrompt = commandPrompt
    self.outputMarkdown = outputMarkdown
  }

  static let builtIns: [TranslationAction] = ActionMode.allCases.map { mode in
    TranslationAction(
      id: UUID(uuidString: Self.stableUUID(for: mode))!,
      name: mode.title,
      mode: mode,
      outputMarkdown: [.analyze, .explainContext, .explainCode].contains(mode)
    )
  }

  private static func stableUUID(for mode: ActionMode) -> String {
    switch mode {
    case .translate: "00000000-0000-4000-8000-000000000001"
    case .polishing: "00000000-0000-4000-8000-000000000002"
    case .summarize: "00000000-0000-4000-8000-000000000003"
    case .analyze: "00000000-0000-4000-8000-000000000004"
    case .explainContext: "00000000-0000-4000-8000-000000000005"
    case .explainCode: "00000000-0000-4000-8000-000000000006"
    }
  }
}

enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case openAI = "OpenAI"
  case chatGPT = "ChatGPT API"
  case azure = "Azure OpenAI"
  case anthropic = "Claude"
  case gemini = "Gemini"
  case ollama = "Ollama"
  case groq = "Groq"
  case deepSeek = "DeepSeek"
  case moonshot = "Moonshot"
  case miniMax = "MiniMax"
  case cohere = "Cohere"
  case cerebras = "Cerebras"
  case chatGLM = "ChatGLM"
  case kimi = "Kimi"
  case teamoRouter = "TeamoRouter"
  case custom = "OpenAI-compatible"

  var id: String { rawValue }

  var defaultEndpoint: String {
    switch self {
    case .openAI, .chatGPT: "https://api.openai.com/v1/chat/completions"
    case .azure: ""
    case .anthropic: "https://api.anthropic.com/v1/messages"
    case .gemini: "https://generativelanguage.googleapis.com/v1beta"
    case .ollama: "http://127.0.0.1:11434/api/chat"
    case .groq: "https://api.groq.com/openai/v1/chat/completions"
    case .deepSeek: "https://api.deepseek.com/chat/completions"
    case .moonshot, .kimi: "https://api.moonshot.cn/v1/chat/completions"
    case .miniMax: "https://api.minimax.chat/v1/text/chatcompletion_v2"
    case .cohere: "https://api.cohere.com/v2/chat"
    case .cerebras: "https://api.cerebras.ai/v1/chat/completions"
    case .chatGLM: "https://open.bigmodel.cn/api/paas/v4/chat/completions"
    case .teamoRouter, .custom: ""
    }
  }

  var defaultModel: String {
    switch self {
    case .openAI, .chatGPT, .custom: "gpt-4o-mini"
    case .azure: "gpt-4o-mini"
    case .anthropic: "claude-sonnet-4-5"
    case .gemini: "gemini-2.5-flash"
    case .ollama: "qwen3:8b"
    case .groq: "llama-3.3-70b-versatile"
    case .deepSeek: "deepseek-chat"
    case .moonshot, .kimi: "moonshot-v1-8k"
    case .miniMax: "MiniMax-M2.7"
    case .cohere: "command-a-03-2025"
    case .cerebras: "llama-3.3-70b"
    case .chatGLM: "glm-4-plus"
    case .teamoRouter: ""
    }
  }

  var usesAPIKey: Bool { self != .ollama }
}

struct ProviderConfiguration: Codable, Equatable, Sendable {
  var provider: ProviderKind = .openAI
  var endpoint = ProviderKind.openAI.defaultEndpoint
  var model = ProviderKind.openAI.defaultModel
  var organization = ""
  var apiVersion = "2024-10-21"
  var extendedThinking = false
  var reasoningEnabled = false

  init(
    provider: ProviderKind = .openAI,
    endpoint: String = ProviderKind.openAI.defaultEndpoint,
    model: String = ProviderKind.openAI.defaultModel,
    organization: String = "",
    apiVersion: String = "2024-10-21",
    extendedThinking: Bool = false,
    reasoningEnabled: Bool = false
  ) {
    self.provider = provider
    self.endpoint = endpoint
    self.model = model
    self.organization = organization
    self.apiVersion = apiVersion
    self.extendedThinking = extendedThinking
    self.reasoningEnabled = reasoningEnabled
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case endpoint
    case model
    case organization
    case apiVersion
    case extendedThinking
    case reasoningEnabled
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decodeIfPresent(ProviderKind.self, forKey: .provider) ?? .openAI
    endpoint =
      try container.decodeIfPresent(String.self, forKey: .endpoint)
      ?? provider.defaultEndpoint
    model =
      try container.decodeIfPresent(String.self, forKey: .model)
      ?? provider.defaultModel
    organization = try container.decodeIfPresent(String.self, forKey: .organization) ?? ""
    apiVersion =
      try container.decodeIfPresent(String.self, forKey: .apiVersion)
      ?? "2024-10-21"
    extendedThinking =
      try container.decodeIfPresent(Bool.self, forKey: .extendedThinking)
      ?? false
    reasoningEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .reasoningEnabled)
      ?? false
  }

  var supportsReasoningControl: Bool {
    guard let url = URL(string: endpoint),
      url.host?.lowercased() == "opencode.ai",
      url.path.contains("/zen/go/v1/chat/completions")
    else { return false }
    return model.lowercased().contains("deepseek-v4")
  }
}

enum AppTheme: String, Codable, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  var id: String { rawValue }
  var title: String { rawValue.capitalized }
}

enum TTSProvider: String, Codable, CaseIterable, Identifiable, Sendable {
  case edge
  case system

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .edge: "Microsoft Edge Neural"
    case .system: "macOS System Voice"
    }
  }
}

struct ShortcutSettings: Codable, Equatable, Sendable {
  var translateSelection = "⌥F"
  var showWindow = "⌥⇧F"
  var screenshotOCR = "⌥S"
  var writing = "⌥W"
}

struct ProxySettings: Codable, Equatable, Sendable {
  var enabled = false
  var scheme = "http"
  var host = ""
  var port = 8080
  var username = ""
  var noProxy = "localhost,127.0.0.1"
}

struct AppSettings: Codable, Equatable, Sendable {
  var provider = ProviderConfiguration()
  var sourceLanguage: LanguageCode = .auto
  var targetLanguage: LanguageCode = .simplifiedChinese
  var favoriteLanguages: [LanguageCode] = [.simplifiedChinese, .japanese, .english]
  var defaultActionID = TranslationAction.builtIns[0].id
  var autoTranslate = true
  var autoSpeakSelection = false
  var autoHideWhenInactive = false
  var alwaysOnTop = false
  var launchAtLogin = false
  var showDockIcon = true
  var useCompactSelectionPreview = true
  var useClipboardFallback = true
  var theme: AppTheme = .system
  var fontSize = 15.0
  var speechRate = 0.48
  var speechVolume = 1.0
  var ttsProvider: TTSProvider?
  var writingTargetLanguage: LanguageCode = .english
  var shortcuts = ShortcutSettings()
  var proxy = ProxySettings()

  var resolvedTTSProvider: TTSProvider { ttsProvider ?? .edge }
}

struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  var createdAt = Date()
  var sourceText: String
  var translatedText: String
  var sourceLanguage: LanguageCode
  var targetLanguage: LanguageCode
  var actionName: String
  var provider: ProviderKind
  var model: String
  var selectionContext: String?
  var favorite = false
}

struct VocabularyEntry: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  var createdAt = Date()
  var word: String
  var explanation: String
  var sourceLanguage: LanguageCode
  var targetLanguage: LanguageCode
}

struct TranslationPrompt: Equatable, Sendable {
  let system: String
  let user: String
}

struct SelectionSnapshot: Equatable, Sendable {
  var text: String
  var surroundingText: String?
  var screenRect: CGRect?
}

enum TranslationError: LocalizedError, Equatable {
  case missingAPIKey
  case invalidEndpoint(String)
  case invalidResponse
  case provider(String)
  case noInput
  case selectionUnavailable
  case accessibilityPermissionRequired
  case cancelled

  var errorDescription: String? {
    switch self {
    case .missingAPIKey: "Add an API key in Settings."
    case .invalidEndpoint(let reason): "Invalid API endpoint: \(reason)"
    case .invalidResponse: "The provider returned an unreadable response."
    case .provider(let message): message
    case .noInput: "Enter or select text first."
    case .selectionUnavailable:
      "Selected text could not be read. Keep it selected in the other app, release the shortcut keys, and press ⌥F again."
    case .accessibilityPermissionRequired:
      "Accessibility permission is required for selected-text and writing tools."
    case .cancelled: "Translation cancelled."
    }
  }
}
