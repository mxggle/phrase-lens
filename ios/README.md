# PhraseLens for iOS

Select a word or passage in any app, tap **Share…**, then **PhraseLens**: the
answer streams into a sheet over the app you are reading in.

## Why the Share sheet

iOS does not let an app replace or add to the system **Translate** and
**Look Up** items in the text selection menu. An Action extension is the
closest hook it offers: it appears for any selected text, and its sheet opens
over the current app instead of switching away.

## What is in the MVP

- **Actions**: Translate, Definition, and Native Speaker to start, plus any
  custom action with your own role and command prompts (`${text}`,
  `${sourceLang}`, `${targetLang}`). Reorder, delete, pick a default, or add
  the other macOS built-ins back from the + menu.
- **Providers**: every API-key provider the macOS app supports (OpenAI,
  Claude, Gemini, DeepSeek, Groq, Azure OpenAI, OpenAI-compatible, …). The
  key lives in the device Keychain, shared by the app and the extension
  through the App Group.
- **Lookup screen** in the app for typed or pasted text.
- No surrounding-context capture, follow-ups, history, or speech yet.

## Shared code

The targets compile these files from the macOS app directly, so a provider
or prompt fix there reaches the phone:

`Sources/PhraseLens/Models/*`, `Services/PromptBuilder.swift`,
`Services/TranslationClient.swift`, `Services/EndpointValidator.swift`,
`Services/LanguageDetector.swift`, `Services/Localization.swift`,
`Views/DesignSystem.swift`, `Views/MarkdownText.swift`.

Keep those files free of AppKit. `ios/Shared` holds the iOS-only pieces both
targets use.

## Build

```sh
brew install xcodegen          # once
cd ios && ./scripts/build.sh   # regenerates the project, builds for the Simulator
open PhraseLens.xcodeproj      # or run from Xcode
```

`project.yml` is the source of truth; `PhraseLens.xcodeproj` is generated
from it and committed so the project opens without XcodeGen.

## Running on a phone

1. In Xcode, select the **PhraseLens** and **PhraseLensAction** targets and
   set your team under *Signing & Capabilities* (or set `DEVELOPMENT_TEAM`
   in `project.yml`).
2. If the bundle IDs `com.harry.phraselens.ios` / `.ios.action` or the App
   Group `group.com.harry.phraselens` are taken under your team, change them
   in `project.yml` and in `MobileSettingsStore.appGroup`.
3. Run the **PhraseLens** scheme on the device, add your provider and API key
   in Settings, then try Share → PhraseLens on selected text in Safari.
   The first time, PhraseLens may sit under **Edit Actions…**; add it to
   Favorites to keep it at the top.
