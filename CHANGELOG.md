# Changelog

All notable changes to PhraseLens are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.0] — 2026-08-22

### Added

- **Saved words are filed for you, and the collection can be cut apart.** A vocabulary
  list past a screenful was a wall: a headword, a fixed expression and a whole sentence
  kept for its shape tiled together with nothing to tell them apart, and the only way
  back to one of them was remembering how it was spelled. Every word is now filed along
  five dimensions as it is saved — what kind of thing it is, its part of speech, the
  subject it belongs to, its register, and how hard it is, with the native rung ("N2",
  "B1") kept alongside for the languages that have one. Four of the five are closed
  sets, which is what lets the filter rail draw stable rows; topic is open, because what
  a reader's material is about is decided by the material, and a request offers the
  topics already in use back to the model so a collection converges on a handful of
  buckets instead of coining a synonym every twenty words.
- **A filter rail with counts that stay honest.** Rows inside a dimension widen the
  result; rows across dimensions narrow it. Each dimension's counts are taken with its
  own choices lifted, so arming *Word* leaves *Phrase* and *Sentence* standing with
  their real totals rather than collapsing every sibling to zero — no click lands
  somewhere empty. The rail folds into a pull-down on a narrow window.
- **Grouping.** Break the collection into pinned sections by any of the same dimensions,
  or by the month you collected it. Closed dimensions keep their declared order rather
  than sorting by size, and a word filed under two topics is browsable under both.
- **Organize.** Words collected before this existed are picked up by one pass, twenty per
  request through the provider you already configured, saving each batch as it lands so
  a cancelled or dropped run keeps everything it finished.

Every tag is optional at every layer. Words saved before this existed decode untouched,
a model that cannot judge a dimension is told to leave it out rather than guess, and
anything unfiled stays reachable through a *Not tagged* row instead of dropping out of
the collection. Tags are read on every launch from the file that holds the words
themselves, so an unrecognized value costs that value and not the collection.

### Fixed

- **The answer comes back in the language you picked, even when the source is a wall of
  another one.** Summarize, Analyze and Explain in Context all ended their command
  prompt with the material itself, and a model that reads several hundred words of
  Japanese last answers in Japanese. Each now closes on the line naming the target
  language, and the shared answer-language rule states outright that the material never
  overrides it. Words, examples and quotes stay in the source language; everything
  written *about* them is in yours.

## [0.5.3] — 2026-08-22

### Fixed

- **The beachball after a screenshot capture is gone.** A crop holding no text raised
  the error alert, and that alert arrived while the main window was still coming back
  from being hidden for the capture — so its backing surfaces were allocated and
  synchronised against a render server that was already rebuilding the window behind
  it, and the main thread sat there. Sampling a capture over a blank region put 929 ms
  on the main thread, 668 ms of it inside a Core Animation commit; the same capture
  over text cost 138 ms, because that path raises no alert. An empty crop is an outcome
  rather than a failure, so it now takes the route an empty selection already takes — a
  line in the status bar — and the same capture costs 103 ms.

## [0.5.2] — 2026-08-22

### Fixed

- **Screenshot OCR reads Chinese and Japanese again.** The recognizer was handed a
  fixed language list with English at its head. Vision does not try those languages in
  turn — it picks one model from the head of the list — so a Latin language in first
  place meant CJK text was dropped outright: a screenshot of Chinese or Japanese came
  back empty as "no text was found", and one that mixed scripts kept the English and
  turned the rest into glyph soup. The script is now detected from the screenshot
  itself, and a shot carrying Japanese, both Chinese scripts and English at once reads
  correctly.
- A capture could be read before it had finished being written. `screencapture` hands
  the interactive selection to a helper and can exit before that helper has flushed the
  PNG, so the single check for the finished file sometimes ran first and the capture was
  reported as cancelled. It now waits for the file to settle.
- A click that never became a drag no longer raises an error. The empty capture it
  writes used to travel all the way to a failed recognition; it is treated as a
  cancelled selection now, the same as pressing Escape.

## [0.5.1] — 2026-08-22

### Changed

- **The source box is always editable.** Text captured from another app used to
  arrive read-only, and editing it meant reaching for a pencil button in the pane's
  footer first. The box is now a plain editor whatever the text came from: a click
  puts the caret where it lands, and looking one word up and typing the next no
  longer costs a trip to the footer.
- **The translator's controls moved into the chrome they belong to.** The strip that
  held the action tabs and both language pickers above the split is gone. The tabs
  sit beside the section title in the top bar, each language picker sits in the
  header of the pane it describes with the swap button between them, and Collect and
  Copy sit in the result header — leaving the foot of that pane to the follow-up
  question alone.

### Fixed

- Editing captured text now drops the sentence that was captured around it. A word
  typed over a selection was still translated against the surrounding sentence of the
  *previous* selection.
- The language and action pickers draw their own fill, border, and trailing chevron.
  The menu style they used handed the label to an AppKit cell that kept the text and
  discarded the rest, then drew the indicator on the wrong edge.

## [0.5.0] — 2026-08-19

### Added

- **Sign in with your ChatGPT account.** OpenAI and ChatGPT API providers now offer
  an authentication mode next to the API key: sign in through the browser with OAuth
  2.0 PKCE, and translations run on your ChatGPT subscription through the Codex
  Responses backend instead of a Platform API key. The token is refreshed on its own
  when it expires, the models the subscription actually serves are listed from the
  backend's own catalog, and signing out removes the token.
- **The selection pop-up can be pinned.** It used to close on any click outside it,
  so glancing at the source app while reading a result threw the result away and the
  lookup had to be repeated. The pin in its title bar keeps it on screen until you
  close it with Escape or the close button; the choice is remembered, and Settings ›
  Selection carries the same switch as "Keep the pop-up open".

### Changed

- **Credentials no longer live in the Keychain.** A Keychain item can only be read
  by the code signature that wrote it, so switching provider — which reads the key
  for the provider you switched to — asked for the login password every time. Keys
  and OAuth tokens now sit in a `0600` file in PhraseLens's own Application Support
  folder, sealed with AES-GCM under a key derived from this Mac's hardware UUID, and
  are read once per launch. Nothing reads the Keychain on its own any more: when an
  earlier build left a key there, the provider's credential section offers an
  "Import from Keychain" button, and only pressing it raises the password panel.
- **One model control instead of two.** The model pop-up and the "Model ID override"
  field both edited the same setting, so a catalog choice and a hand-typed id fought
  over one value. There is now a single searchable model field: type to filter the
  provider's catalog, or type an id it does not list and use that.
- **The model catalog is remembered.** It used to live in the settings pane's own
  state, so leaving the pane threw it away and every visit began with a manual
  fetch. Catalogs are now stored per provider, endpoint and authentication mode,
  refreshed in the background when they are more than a day old, and kept when a
  refresh fails.

### Fixed

- Gemini's model list is paged, and only the first page was ever read — most of the
  catalog was missing from the picker.
- Catalogs that carry publication dates (OpenAI-compatible providers, Groq) list the
  newest models first instead of alphabetically; undated catalogs keep the order the
  provider chose.
- Embedding, rerank, transcription, speech and image models are filtered out for
  every provider, not just OpenAI. Picking one produced a failure that read like a
  bad API key.
- A failed catalog refresh no longer empties the model list.
- **The ChatGPT OAuth model list was mostly wrong.** Two things went wrong at once.
  The picker merged the fetched catalog with a hardcoded list, and six of those eight
  built-in names — gpt-5.4-nano, gpt-5.3-codex, gpt-5.2, gpt-5.2-codex, gpt-5.1-codex,
  gpt-5.1-codex-mini — are refused by the Codex backend for a ChatGPT account, so most
  of what the menu offered could not be used. Meanwhile the catalog request claimed
  client version 0.115.0, and the backend only lists models a client that old could
  drive, which hid gpt-5.5 and the gpt-5.6 family. The fetched catalog now stands on
  its own, and the request claims a version that reaches the current models.
- Codex models are ordered by the backend's own ranking and hidden by its own
  `visibility` field, rather than by a hand-kept list of slugs that went stale and a
  guess at which names looked internal.

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

[Unreleased]: https://github.com/mxggle/phrase-lens/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/mxggle/phrase-lens/compare/v0.5.3...v0.6.0
[0.5.3]: https://github.com/mxggle/phrase-lens/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/mxggle/phrase-lens/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/mxggle/phrase-lens/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/mxggle/phrase-lens/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/mxggle/phrase-lens/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/mxggle/phrase-lens/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/mxggle/phrase-lens/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/mxggle/phrase-lens/releases/tag/v0.2.0
