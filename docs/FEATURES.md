# Desktop feature coverage

This file maps the original desktop behaviors to their native implementation.

| Capability | Native implementation |
|---|---|
| Offline dictionary | Extensible provider registry, Japanese/English-to-Chinese SQLite packs, automatic language candidates and override, shared sourced cards, entry/sense saves; [coverage and limitations](DICTIONARY_DATA.md) |
| Streaming translate | `TranslationClient` with provider-specific SSE/JSON decoders |
| Translate, polish, summarize, analyze, usage, context, synonyms, code | `PromptBuilder` and action tabs |
| OpenAI, ChatGPT API, Azure, Claude, Gemini, Ollama, Groq, DeepSeek, Moonshot, MiniMax, Cohere, Cerebras, ChatGLM, Kimi, TeamoRouter, custom | Editable provider profiles and native `URLSession` requests |
| Follow-up questions | Multi-turn thread under the result, suggested questions per content type, saved onto the result's history row |
| Selected-text lookup | macOS Accessibility API plus bounded surrounding context |
| Compact selection preview | Native SwiftUI preview with speech and explicit Edit actions |
| Selection pop-up | Compact translation panel near the selected text, with its own compact action tab strip and a pin that keeps it open when you click elsewhere |
| Screenshot OCR | Interactive `screencapture` region plus Vision recognition |
| Writing replacement | Accessibility read, streaming translation, and focused-control replacement |
| TTS | `AVSpeechSynthesizer` with source-text autoplay, manual source and result playback in each pane's own language, and cancellation |
| Pronunciation readings | `PronunciationGuide` per language, applied by `PromptBuilder` to the looked-up term and to short translations |
| History | Atomic JSON storage, search, restore, favorites, delete |
| Vocabulary | Atomic JSON storage, deduplication, search, delete |
| Custom actions | Editable prompts with source, target, and text variables |
| Global shortcuts | Carbon hot-key registration with conflict reporting |
| Menu bar | `MenuBarExtra` actions and quit/settings access |
| Launch at login | `SMAppService.mainApp` |
| Proxy | Ephemeral `URLSessionConfiguration` proxy settings |
| Theme and window behavior | System/light/dark, always-on-top, auto-hide, Dock policy |
| Credential storage | AES-GCM sealed file in Application Support, key derived from the Mac's hardware UUID |

## Verification boundaries

The built-in self-test verifies prompt isolation, the 1,600-character context
bound, endpoint policy, provider stream decoding, shortcut parsing, credential
storage round-trips, and model catalog paging, ordering and cache keying. The
release build runs with warnings treated as errors and the bundle is checked by
strict `codesign` verification.

Live provider calls require the user's own credentials or local Ollama model.
Accessibility and Screen Recording behaviors require the matching macOS
permissions, so those boundaries must be accepted on the target Mac before the
global selection, writing, and screenshot workflows can complete.
