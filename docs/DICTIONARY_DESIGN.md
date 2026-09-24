# Extensible dictionary lookup

Implemented locally on 2026-09-21. Source research and remaining coverage limits
are documented in [DICTIONARY_DATA.md](DICTIONARY_DATA.md).

## User behavior

The Translate action offers **Translation / Dictionary** result tabs for single
words in both the workspace and selection popup. Words default to offline
Dictionary; selecting Translation starts AI once and retains both results when
switching back. Sentences and ordinary phrases show only the translation surface.
The redundant dictionary shortcut beside the source text has been removed.

Eligibility uses word tokenization, not a character/space count. Unspaced
compounds and inflections split by the tokenizer (for example `食べました`) are
checked against real dictionary entries before exposing the Dictionary tab. A
non-match falls through to translation, so `資料館の展示と見どころ` is never shown
as an empty dictionary result. This is conservative: compounds missing from the
installed packs may have translation only. Registry/provider APIs still support
phrase lookup independently of the UI gate.

Settings → General → Dictionary enables word lookup and controls the independent
definition language. Dictionary settings, retry and empty states belong to its
tab; AI errors, follow-ups and result speech belong to Translation. Copy always
uses the visible result; switching tabs does not add history or repeat requests.
Editing the source clears both results and cancels pending work.

Japanese and English have bundled Chinese definitions. Chinese is `zh` and retains
the original source script. Other definition languages are selectable but return
an explicit unsupported-pair message until a matching provider is installed;
there is no silent language fallback or AI-generated dictionary definition.

Both surfaces share source-labelled entry cards with readings, senses, source and
license links, speech, copy with attribution, and save-entry/save-sense actions.
The Translation tab explicitly invokes the configured AI provider. It sends the
user's word/context, not dictionary content, and uses the AI target-language
setting. Empty dictionary results also provide a “View translation” button.

## Architecture

```text
word + local context + optional source override + definition-language preference
  → DictionaryLanguageResolver (ranked candidates)
  → language-specific LexicalProcessor
  → DictionaryRegistry (provider language capabilities)
  → SQLiteDictionaryProvider actor (bound read-only queries)
  → DictionaryMatch entries with source, revision and rights metadata
  → shared DictionaryResultsView / sourced history and vocabulary snapshots
```

- `DictionaryLanguageResolver` is independent of the translator's older
  Japanese-biased heuristics. Kana/Hangul are strong signals; shared Han and Latin
  scripts yield candidates. It bounds contextual analysis to 1,600 characters.
  Explicit source overrides take precedence, including selection and OCR input.
- `LexicalProcessor` preserves exact spelling and diacritics, adds width/kana or
  case aliases, and uses indexed source forms. Japanese polite-tense handling is
  deliberately limited; see the data document.
- `DictionaryProvider` is an asynchronous Sendable contract. Descriptors declare
  source and definition language codes, revision, attribution, license, persistence
  permission and permission for AI reuse. Registry processors are keyed by language.
- `DictionaryRegistry` filters providers by requested pair, preserves source entry
  boundaries, ranks literal headwords before aliases, and retains successful results
  alongside provider errors. It never substitutes another definition language.
- `AppModel` owns cancellable lookup state and request identity. Edits, language
  changes, clear, action changes and popup dismissal invalidate obsolete requests.
  Stale callbacks cannot overwrite the next lookup's displayed result.
- `DictionaryResultsView` is shared by the full workspace and native popup.
  No per-language views or language-pair switches are needed.

All bundled providers are offline. Context stays on-device during dictionary
lookup. AI and speech retain their existing provider settings and network behavior.

## Persistence

`AppSettings.dictionaryDefinitionLanguage` is a String language tag independent of
AI source/target languages. Old settings default to enabled lookup and Chinese.
Optional `dictionarySnapshot` fields preserve compatibility with old history and
vocabulary JSON. Snapshots retain query, actual language, source entry/sense IDs,
revision, content and attribution; old records retain their existing IDs.

Dictionary vocabulary identity includes provider, entry, definition language and
selected senses. The same word from AI or another dictionary remains distinct.
Dictionary-only saves do not trigger automatic AI categorization. Explicit AI
organization filters out sources whose descriptors disallow AI reuse. Sources
without persistence permission are excluded from saved snapshots and copying.

## Extending languages and sources

For another offline language pair:

1. Produce schema-v1 records and a manifest in `Resources/Dictionaries`; publish
   original glosses with their actual language and license metadata.
2. Add a `LexicalProcessor` only if exact lookup plus source-indexed forms is
   insufficient. Register it in `DictionaryRegistry.processors`.
3. Add detection, semantic, ambiguity and no-entry fixtures for the new language.
4. Rebuild: bundled manifests are discovered automatically, and their language
   codes appear in the existing controls. Result views and persistence need no
   language-specific changes.

An async French-to-English fixture already verifies a different source and
output language through this same registry and result model.

A future online provider implements the protocol but also needs explicit settings
for credentials/network use, timeout/retry policy, accurate online/offline status,
and finer operation-specific rights before adoption. The current `canPersist`
flag deliberately groups copying and storage because both bundled sources allow
both. Do not register a restricted commercial provider without adapting these
policies to its contract. Remote context transmission is not part of the current
provider protocol.

Possible later sources: [JMdict](https://www.edrdg.org/edrdg/licence.html) for
Japanese-to-English; a licensed Japanese-to-Chinese API for better Chinese coverage.
[Youdao's official dictionary API](https://ai.youdao.com/DOCSIRMA/html/dictionary/api/ydcd/index.html)
requires activation and restricts caching/reuse, so it is not bundled. macOS
Dictionary Services cannot guarantee the requested definition language.

## Validation and boundaries

`./scripts/test.sh` runs the existing app self-tests, async dictionary tests,
isolated AppModel integration tests, and importer regression fixtures. Coverage
includes source overrides, ambiguity, inflections, real Chinese meanings, bound
SQL queries, partial provider failure, cancellation, stale responses, compatible
JSON decoding, provenance, stable saves, restore and AI failure isolation.

The native workspace and popup were checked with an isolated preview library;
Japanese lookup, English irregular forms, save and history restore were exercised.
A separately packaged preview verifies bundled resource discovery and signing.
This is local validation, not a notarized release, comprehensive data-quality
certification, or a fresh acceptance of macOS cross-application permission flows.

### Result-tab regression checks (2026-09-24)

The isolated native preview was inspected in dark and light appearance: dictionary
and cached translation switching, language popover, workspace layout, and changing
a word to the reported Japanese title. Regression checks cover routing against
real bundled packs, retained results, copy selection, late lookup completion,
definition changes, disabled dictionaries and AI-error isolation. AI preview text
was a fixed fixture; this check does not claim a live provider response.
