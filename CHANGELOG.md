# Changelog

All notable changes to PhraseLens are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] — 2026-08-16

### Added

- **Follow-up questions.** Keep asking about a result without leaving it. The thread
  renders directly under the answer and shares its scroller, so the text you asked
  about stays on screen.
  - One-tap suggested questions, chosen by what you are reading: a word offers
    examples, nuance, collocations, word parts and a memory hook; a sentence offers a
    breakdown, grammar and rephrasings; code offers a walkthrough, risks and a better
    version.
  - <kbd>⌘</kbd><kbd>L</kbd> puts the cursor in the composer, and answers stream in
    turn by turn.
  - The whole exchange is sent as a real multi-turn conversation to every provider
    (OpenAI-compatible, Anthropic, Gemini, Ollama, Cohere): your original request, the
    answer it produced, and up to eight earlier turns.
  - Threads are saved onto the result's history entry — reopening it from History
    brings the conversation back with it.
- Self-tests covering prompt substitution for every built-in action, the Compare
  Synonyms structure, and how a request decides whether its answer is Markdown.

### Changed

- **Built-in prompts are now the templates you can see.** Each action kept a second,
  hand-written copy of its prompt in code, and the two had drifted; the editable
  template in Settings is now literally what gets sent. Only the branches a static
  template cannot express remain in code — Translate's single-word dictionary lookup,
  its silent variant for rewriting a focused field, and Explain in Context's fallback
  when no surrounding text was captured.
- **Every built-in prompt rewritten** around what a reader actually needs back:
  answers stay in one language throughout, stay shaped for a narrow panel, and name
  the sections they must produce. Analyze breaks a passage into translation,
  chunk-by-chunk breakdown, what is worth learning, and what to watch out for;
  Compare Synonyms leads with the decision guide and always includes an example
  sentence per word; Explain Code separates how it works from what to watch out for;
  Polishing leaves an already-good passage alone and never changes the language.
- Summarize now renders as Markdown by default, which is what its bullets were always
  meant to be.

### Fixed

- A single-word translation came back as a dictionary entry written in Markdown but
  was rendered literally, showing raw `**` and `###`. Markdown rendering now follows
  what the request asked the model for.
- A sidebar collapsed by dragging its divider could not be reopened.
- Focusing the follow-up composer while an answer streamed could pin a CPU core:
  SwiftUI and AppKit fought over first-responder status on every rebuild.

### Documentation

- The landing page gained a live follow-up section, the ⌘L shortcut, and an FAQ entry
  on what a follow-up sends back to the provider.
- This changelog.

## [0.3.1] — 2026-08-15

### Fixed

- Clicking the Dock icon after closing the main window did nothing; it now reopens.
- Replies cut off by a provider's length or safety limit are labelled as truncated
  instead of silently looking finished, and partial results survive a failed request.
- Switching between the selection pop-up and the main window no longer cancels an
  in-flight translation.
- Low-contrast caption text across the app.

### Added

- Inline error recovery in the selection pop-up: Retry, Open Settings, Stop, and
  expandable captured text.
- Shortcut recorder flags a clash with another action by name, arms one field at a
  time, and records function and arrow keys.
- Settings flags unsaved API keys before you navigate away and lets you remove one.
- Confirmation before destructive deletes in the library; redesigned vocabulary cards.
- Visible keyboard focus on buttons and toggles, not just text fields.
- Optional notarization in `package-app.sh`.

### Changed

- Markdown rendering is cached across re-renders instead of re-parsed every frame.

## [0.3.0] — 2026-08-14

### Added

- Keyboard action switching (<kbd>⌘</kbd><kbd>1</kbd>–<kbd>9</kbd>, <kbd>⌘</kbd><kbd>⇧</kbd><kbd>[</kbd> / <kbd>]</kbd>) and selection-panel motion.
- Landing page, deployed to GitHub Pages.

## [0.2.0] — 2026-08-14

### Added

- Native macOS app icon and a unified logo across the sidebar, selection panel and
  settings.
- High-density Compare Synonyms analysis: anchor line, comparison cards, quick
  decision guide.

### Changed

- The About pane resolves the bundle version dynamically.

[Unreleased]: https://github.com/mxggle/phrase-lens/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/mxggle/phrase-lens/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/mxggle/phrase-lens/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/mxggle/phrase-lens/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/mxggle/phrase-lens/releases/tag/v0.2.0
