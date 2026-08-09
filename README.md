# PhraseLens

> Understand any text, right where you find it.

PhraseLens is a native macOS language workspace for translating, explaining,
polishing, summarizing, and reading text aloud. Select text in another app and
use a global shortcut to get a compact result beside your current workflow, or
open the full workspace when you need more control.

It is built with SwiftUI and native macOS APIs. There is no browser extension,
embedded web runtime, or required hosted account.

## What it can do

- Translate typed, pasted, or selected text with streaming responses.
- Run focused actions for translation, polishing, summarization, analysis,
  context explanations, and code explanations.
- Look up selected text from other macOS apps through Accessibility APIs.
- Capture a screen region and extract text with Vision OCR.
- Translate text in a focused editable control and replace it through the
  Accessibility API.
- Speak source text with Microsoft Edge Neural voices or macOS system voices.
- Keep local history and vocabulary collections with search and restore.
- Add custom prompt actions using `${sourceLang}`, `${targetLang}`, and
  `${text}` variables.
- Run from the menu bar with configurable global shortcuts.
- Connect to hosted providers, compatible custom endpoints, or a local Ollama
  server.

## Default shortcuts

| Action | Shortcut |
| --- | --- |
| Translate selected text in a compact pop-up | `⌥F` |
| Open the full PhraseLens workspace | `⌥⇧F` |
| Screenshot OCR | `⌥S` |
| Translate and replace text in the focused control | `⌥W` |

All shortcuts can be changed in Settings. The selected-text and writing
workflows require macOS Accessibility permission. Screenshot OCR requires
Screen Recording permission.

## Supported providers

PhraseLens includes editable provider profiles for OpenAI, ChatGPT API,
Azure, Claude, Gemini, Ollama, Groq, DeepSeek, Moonshot, MiniMax, Cohere,
Cerebras, ChatGLM, Kimi, TeamoRouter, and compatible custom endpoints.

Provider credentials are stored in the macOS Keychain. API requests go to the
provider configured by the user; PhraseLens does not provide a proxy or collect
credentials.

## Requirements

- macOS 14 or newer
- Swift 6.2 or newer
- An API key for the selected provider, or a local Ollama server
- Accessibility permission for selection lookup and writing replacement
- Screen Recording permission for screenshot OCR

## Build and run

Clone the repository and run the signed app bundle:

```bash
git clone https://github.com/mxggle/phrase-lens.git
cd phrase-lens
./scripts/run.sh
```

`run.sh` builds the release executable, packages it as `PhraseLens.app`,
verifies the code signature, and opens the bundle. Use the bundle rather than
the raw SwiftPM executable because macOS Accessibility consent is tied to the
signed application identity.

Run the automated self-test:

```bash
./scripts/test.sh
```

Create the app, ZIP archive, and DMG installer:

```bash
./scripts/package-app.sh
```

The outputs are written to `.build/`:

```text
.build/PhraseLens.app
.build/PhraseLens.zip
.build/PhraseLens.dmg
```

For a direct release build with warnings treated as errors:

```bash
swift build -c release -Xswiftc -warnings-as-errors
```

## Privacy and security

- API keys are stored in Keychain, not `UserDefaults` or source files.
- Provider endpoints must use HTTPS. Plain HTTP is accepted only for a
  loopback Ollama endpoint.
- URLs containing embedded credentials are rejected.
- Selected-text context is bounded and treated as untrusted prompt data before
  it is sent to an AI provider.
- History, vocabulary, settings, and custom actions are stored locally on this
  Mac.
- Edge Neural TTS sends the text being spoken to Microsoft's speech service;
  macOS system speech can be selected instead.

Review the provider's data handling and retention policy before using PhraseLens
with sensitive text.

## Project structure

```text
Sources/NextAITranslatorNative/
├── App/          Application lifecycle and shared model
├── Models/       Settings, providers, actions, and persisted data models
├── Services/     Translation, Accessibility, OCR, TTS, storage, and hotkeys
└── Views/        SwiftUI workspace, pop-up, settings, history, and actions
packaging/        App bundle metadata and icon
scripts/          Test, package, run, and toolchain helpers
docs/             Feature coverage and design-system notes
```

## License

PhraseLens is distributed under the GNU Affero General Public License,
version 3 or later. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

This project is a from-scratch native macOS implementation based on the
behavior and user-facing concepts of [NextAI Translator](https://github.com/nextai-translator/nextai-translator).
