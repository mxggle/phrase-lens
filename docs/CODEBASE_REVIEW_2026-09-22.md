# PhraseLens codebase review — 2026-09-22

Reviewed the current working tree on `main`, based on `69138f7`, including the existing uncommitted dictionary implementation and other local changes. This is a review, not a fix or release acceptance. No application source was changed for this review.

**Result:** 22 actionable findings: 3 P1, 17 P2, and 2 P3. No P0 was established. P1 means fix before the next release; P2 means a concrete correctness, reliability, or security-boundary defect; P3 means lower-impact behavior or resource consistency.

**Evidence labels:** **Reproduced** means an isolated executable exercised the current implementation. **Code path** means the defect follows from the inspected control/data flow but the OS interaction or failure condition was not exercised. Reproductions use synthetic credentials, temporary storage/UserDefaults, and a loopback fixture server. The OAuth reproduction changes only the token endpoint in a temporary source copy so no real authentication service is contacted.

## Highest priority

**R01 · P1 · In-place writing can overwrite a different field or discard newer edits.**

Location: `Sources/PhraseLens/App/AppModel.swift:1400–1426`; `Services/AccessibilityService.swift:555–580`.

The writing action reads the current field, waits for a network stream, then `replaceCurrentEditableText` obtains the *current* focused element and selection again. Switching from field A to field B while waiting writes A's translation into B; editing A while waiting can also be overwritten. The task is not retained or cancelled by `stopTranslation`. The original process, AX element, value, and selection are never compared at commit time.

Fix: capture an edit transaction containing the source process/element, original value and range; translate that snapshot; validate it before applying; abort if it changed. Track and cancel the writing task. Acceptance: switch fields, type during translation, press Stop, and launch a second writing request; none may overwrite unrelated/newer text. **Code path; no real user fields were modified.**

**R02 · P1 · OAuth refresh is saved under whichever provider is selected when it finishes.**

Location: `Services/SettingsStore.swift:189–214`, especially `208–209`; related request setup at `App/AppModel.swift:446–465` and `Views/SettingsView.swift:779–792`.

`validCredentials` suspends during refresh, then reads `settings.provider.provider` again to choose the credential storage key. A switch from OpenAI to Claude during that wait saves the refreshed OpenAI credentials in Claude's slot and publishes them into the current provider state. Switching between the two OAuth-capable providers can replace the wrong account. Logging out during an in-flight refresh has the same missing generation boundary. Requests also capture configuration separately from the later credential lookup.

Fix: resolve credentials for an explicit immutable provider/auth configuration, coalesce refreshes per credential identity, and gate UI/storage completion on an authentication generation. A logout must invalidate pending work. Acceptance: delayed refresh + provider switch/logout/concurrent requests; only the intended credential record changes. **Reproduced:** `OAUTH_REFRESH_SAVED_UNDER_WRONG_PROVIDER=true` using fake tokens and a delayed loopback endpoint. No real token exposure was demonstrated.

**R03 · P1 · A failed or unfinished stream can be recorded as a completed translation.**

Location: `Services/TranslationClient.swift:54–77`, `425–571`; completion at `App/AppModel.swift:478–502`.

The decoder discards Anthropic `type:error`, Responses `response.failed`, and Ollama error frames. The stream wrapper treats EOF as success whenever any text was emitted and no recognized truncation reason appeared; it never requires the provider's terminal-success event. A partial answer followed by a service error therefore becomes `Completed`, enters normal history, and can reach the in-place replacement path in R01.

Fix: represent text, error, successful termination and incomplete termination explicitly; parse provider error events and require an appropriate terminal event. Preserve partial text with failure metadata instead of marking it complete. Acceptance: partial text + error, partial text + EOF, failure before text, and successful terminal events for each protocol. **Reproduced end to end:** the loopback server returned partial text followed by an Ollama error, and the real AppModel reported success and saved it. Anthropic/Responses error decoding was also reproduced directly. Anthropic explicitly documents errors inside otherwise successful streaming HTTP responses: [streaming documentation](https://platform.claude.com/docs/en/build-with-claude/streaming).

## Other correctness and reliability findings

**R04 · P2 · Writing reads the entire field but may replace only its selection.**

Location: `Services/AccessibilityService.swift:541–552`, `566–582`.

`currentEditableText` always returns the full AX value. The writer replaces only `selectedRange` when it is nonempty. Selecting one word in a paragraph thus sends the full paragraph for translation and inserts the full translated paragraph at the word's position, leaving the rest of the original paragraph around it. Fix by using the same captured scope for reading and replacement. Test a nonempty selection and a caret-only field separately. **Code path.**

**R05 · P2 · The default HTTP proxy configuration bypasses the proxy for HTTPS traffic.**

Location: `Services/TranslationClient.swift:372–382`; duplicated in `ModelCatalogClient.swift:323–336` and `OpenAIOAuthService.swift:1073–1087`.

The UI's proxy protocol is used to turn HTTP and HTTPS destination proxying on mutually exclusively. With the default `scheme=http`, `HTTPSEnable` is false, so HTTPS provider traffic goes direct. Apple's local `CFNetworkCopyProxiesForURL` returned `kCFProxyTypeNone` for this exact dictionary and an HTTPS destination. In addition, catalog/OAuth sessions omit the configured bypass list, and the proxy username exposed in Settings is unused by these clients.

Fix: centralize proxy/session construction, distinguish proxy transport from destination scheme, and implement or remove unsupported authentication controls. Apply bypass behavior consistently. Acceptance: local proxy records translation/catalog/OAuth requests to HTTPS destinations, with explicit bypass hosts tested separately. **Reproduced routing decision; no live commercial proxy was tested.** Apple documents the separate [HTTPS enable flag](https://developer.apple.com/documentation/cfnetwork/kcfnetworkproxieshttpsenable).

**R06 · P2 · Credential read errors silently become an empty store that the next save overwrites.**

Location: `Services/CredentialStore.swift:178–201`.

`loadedPayload` catches every read/decryption/decode error and caches an empty payload. An unsupported envelope version also returns empty. Saving one new provider then rewrites the original file without the other credentials. This can destroy recoverable data after corruption, migration, a hardware-identity change, or opening a newer format with an older app.

Fix: distinguish missing storage from unreadable/incompatible storage, propagate an actionable error, preserve the original file, and require an explicit recovery/reset before overwriting it. Acceptance: damaged authentication tag, invalid JSON and unknown version remain untouched after a failed read/save attempt. **Reproduced with a synthetic encrypted file:** read-as-empty and subsequent overwrite both occurred.

**R07 · P2 · Legacy credential migration reports success even when persistence fails.**

Location: `Services/CredentialStore.swift:157–173`.

The migration flag is set before `mutate` writes, and `try?` suppresses persistence failures. `imported` is set inside the mutation closure before the write succeeds. A disk-full or permission error can therefore report success and permanently hide the retry/import button despite having saved nothing.

Fix: make persistence part of the migration transaction; set the flag and return success only after a successful write; surface write failures. Test a non-writable destination through an injectable legacy store. **Code path; real Keychain data was not imported.**

**R08 · P2 · Responses reasoning/tool deltas are treated as translation text.**

Location: `Services/TranslationClient.swift:484–485`.

The generic string `delta` fallback accepts all event types, including `response.reasoning_summary_text.delta`, reasoning text, and tool-argument deltas. Such content is appended to the answer and can be saved, spoken or used as replacement text. This is output contamination, not evidence of a provider confidentiality breach.

Fix: allowlist answer-text delta events and handle all other event types separately. Test reasoning summary, reasoning text, function arguments, answer text and refusal events. **Reproduced:** a synthetic reasoning-summary event returned visible text. The official [Codex Responses decoder](https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/sse/responses.rs) distinguishes these event families.

**R09 · P2 · Editing input leaves follow-ups attached to the previous result/history row.**

Location: `App/AppModel.swift:567–575`, `674–675`, `705–724`, `864–873`.

For an AI result, editing the input changes provenance but retains the answer, follow-up turns and `currentHistoryID`. `canAskFollowUp` stays true. The next follow-up combines the edited source with the old answer, then stores that conversation under the old source's history row. An already-running translation/follow-up is also not invalidated by this edit path.

Fix: make the result's source/action/languages/history identity an immutable context. On edits, cancel obsolete work and reset/detach follow-ups, or explicitly preserve a separate result context for them. **Reproduced end to end:** a follow-up about the edited source was written to the original history row.

**R10 · P2 · Stopping a partially answered follow-up loses it from saved history.**

Location: `App/AppModel.swift:765–796`.

`stopFollowUp` changes the request ID before cancelling. The cancelled task therefore returns at its generation guard and never reaches `settleFollowUp`/persistence. The partial turn stays visible in memory, but disappears after restoring history or relaunching unless a later operation happens to save the thread.

Fix: have the stop operation capture and persist the partial turn against its original history ID before invalidation, including any buffered text not yet published. **Reproduced with a delayed local stream:** visible partial answer, absent persisted follow-up.

**R11 · P2 · Bookmark toggling can delete a same-spelled word from another language pair.**

Location: `App/AppModel.swift:878–895`; correct identity definition in `Models/AppModels.swift:945–953`.

The UI lookup compares only case-insensitive spelling, while storage identity also includes source and target language. A saved German `gift` makes the English `gift` result appear collected; pressing the bookmark removes the German card instead of saving the English one. Different target-language explanations have the same problem.

Fix: resolve the current result's language pair and use the same identity function for lookup, display, collection and removal. **Reproduced:** a German card marked the English-to-Japanese result collected.

**R12 · P2 · Short-word language preferences are applied to entire sentences.**

Location: `Services/LanguageDetector.swift:8–23`; resolver at `73–89`.

Any Han character forces Japanese, and any ASCII-only alphabetic text forces English before statistical detection. Consequently a full Chinese sentence becomes Japanese, and ordinary French/Spanish sentences without accented characters become English. This changes prompts and speech voices. Selection/OCR source resolution additionally ignores the configured source language, so changing the source picker does not correct these captured inputs.

Fix: constrain the preference to genuinely ambiguous short terms, let sentence/context evidence reach the recognizer, and provide an explicit source override for captured text. **Reproduced:** `我今天想去图书馆学习中文。 → ja`, `Bonjour, je suis heureux de vous rencontrer. → en`, `Hola, buenos dias. → en`.

**R13 · P2 · Short complete English sentences are intercepted as dictionary queries.**

Location: `Services/DictionaryLanguageResolver.swift:43–47`; routing at `App/AppModel.swift:402–408`.

The candidate test excludes Japanese sentence punctuation, `!?;`, but not an ASCII full stop. A complete sentence such as `This is a complete sentence.` passes the six-word/80-character check. The default Translate action then shows a dictionary miss instead of translating it automatically.

Fix: consistently detect sentence punctuation/structure while preserving legitimate abbreviations and fixed phrases. Add positive phrase and negative sentence fixtures for both Japanese and English. **Reproduced:** the exact sentence returns `true` from `isLookupCandidate`.

**R14 · P2 · Endpoint validation confuses DNS names and bracketed IPv6 addresses.**

Location: `Services/EndpointValidator.swift:18–43`.

The private-address test treats every hostname beginning with `fc` or `fd` as a private IPv6 literal. Conversely Foundation returns bracketed IPv6 hosts here, so `::1` and private IPv6 comparisons fail. Reproduced results: `https://fc.example.com/...` is rejected; `http://[::1]:11434/api/chat` is rejected for Ollama; `https://[fd00::1]/...` is accepted for a non-Ollama provider despite the stated private-literal policy.

Fix: parse actual IPv4/IPv6 literals, normalize bracketed hosts, and apply address-range checks only after a successful literal parse. Test public DNS prefixes, IPv4, IPv6 and mapped IPv6 forms. **Reproduced; no requests to these test destinations were sent.**

**R15 · P2 · Clipboard fallback can overwrite newer clipboard content or race another capture.**

Location: `Services/AccessibilityService.swift:650–674`; capture task at `App/AppModel.swift:1326–1332`.

The fallback clears the global clipboard, awaits repeatedly, treats any change as its Copy response, and unconditionally restores the old clipboard in `defer`. Another copy or clipboard-manager update during that interval can be mistaken for the selection and erased. Two rapid selection hotkeys can overlap these transactions: the capture generation check rejects stale UI results only after both clipboard operations have already occurred.

Fix: serialize capture/clipboard transactions, cancel stale capture work before side effects, verify source identity throughout, and do not restore over changes the transaction cannot establish it owns. Test overlapping captures and a user copy during the wait. **Code path; the review did not manipulate the real clipboard.**

**R16 · P2 · OAuth callback handling exposes unnecessary reachability and lets unrelated requests abort login.**

Location: `Services/OpenAIOAuthService.swift:282–284`, `340–354`, `402–408`.

The listener is created with a port but no loopback-only local endpoint. The handler also does not require `/auth/callback`, and an unrelated GET or invalid-state request finishes the active continuation with an error. An `error` query is accepted before validating its state. A client able to reach the listener can terminate an active login without knowing the state. PKCE/state still protect the successful code path; token theft was not established.

Fix: bind explicitly to loopback, require the exact method/path and matching state for both success and error responses, ignore unrelated requests, and bind callbacks to an attempt ID. Add callback request size/time limits and cancellation cleanup. **Code path; no live OAuth listener or browser login was started.**

**R17 · P2 · Dismissing the selection panel leaves its follow-up running.**

Location: `Views/SelectionTranslationPanel.swift:151–160`.

The close path cancels only when `isTranslating` or `isLookingUpDictionary` is true. A follow-up sets `isAnsweringFollowUp` instead, so dismissing the panel keeps that paid request running and allows hidden history writes, contrary to the panel's cancellation behavior for translations.

Fix: include all panel-owned work in cancellation, coordinated with partial-turn persistence in R10. Test closing during a follow-up and handing off to the main window, which should intentionally continue. **Code path.**

**R18 · P2 · Late speech delegate callbacks can clear a newer playback session.**

Location: `Services/SpeechService.swift:381–406`.

System speech completion/cancellation callbacks enqueue main-actor work that unconditionally clears `isSpeaking`. Audio callbacks similarly clear `audioPlayer` without checking the sender. If the user stops one utterance and starts another before the queued callback runs, the old callback marks the new session stopped; an old player callback can release the current player. The request generation used for Edge synthesis does not protect these delegate paths.

Fix: track the active utterance/player and generation, and ignore callbacks belonging to older sessions. Test queued cancellation followed immediately by a new system/Edge playback. **Code path; actual audio playback was not exercised.**

**R19 · P2 · A cancelled vocabulary organizer can clear its replacement task.**

Location: `App/AppModel.swift:1044–1048`, `1106–1118`.

Cancellation sets the task handle/progress to nil immediately, allowing a new run. When the old suspended task catches cancellation, its unconditional final cleanup sets both properties to nil again. It can therefore clear the new run's progress and cancel handle while that run continues in the background.

Fix: attach a generation to each organizing run and guard every progress/error/final cleanup assignment by that generation. Test cancel-and-restart while the first batch is awaiting a response. **Code path.**

**R20 · P2 · Vocabulary organization reports success for entries it did not tag.**

Location: `App/AppModel.swift:1081–1104`; `Services/VocabularyTagger.swift:156–189`.

The parser intentionally returns an empty or partial tag dictionary for unusable replies, but progress and the final success message increment by `batch.count`. A provider returning `[]`, malformed JSON, or tags for only one item can still produce `20 words organized` while most or all remain unfiled.

Fix: count successfully applied tag IDs, distinguish attempted/completed/skipped entries, and report partial or invalid results. Test empty, invalid and partial replies. **Code path; no tagging requests to real providers were made.**

**R21 · P3 · The 2,000-entry history cap is applied only on disk.**

Location: `Services/PersistentStores.swift:79–85`; `App/AppModel.swift:329–331`, `540–543`.

Both AppModel insertion paths grow the in-memory array without trimming it. After the cap is reached, the UI shows rows that storage has evicted; favoriting/updating those rows silently does nothing because `updateHistory` returns when their IDs are missing. Memory also grows throughout a long session.

Fix: return the authoritative bounded list from the store or apply one shared retention policy to disk and memory. Decide whether favorites should be protected from eviction. **Verified with a 2,000-row temporary store and the insertion sequence: 2,001 in memory versus 2,000 on disk.**

**R22 · P3 · Customized shortcuts do not update the application menu shortcuts.**

Location: `App/PhraseLensApp.swift:71–84`; dynamic global registration in `App/AppModel.swift:1218–1225`.

Selection/window/OCR menu commands retain hardcoded Option-F, Option-Shift-F and Option-S even after the corresponding global shortcut is changed or cleared. The menu advertises a different binding and the old shortcut remains active while PhraseLens is focused.

Fix: derive menu shortcuts from the same settings or omit duplicate menu accelerators for global commands. Test reassigning and clearing a shortcut with the app both focused and unfocused. **Code path.**

## Optimization and engineering priorities

These are improvement proposals, not additional confirmed vulnerabilities.

1. **Introduce testable service boundaries.** `AppModel.swift` is 1,703 lines and directly constructs translation, speech, AX, OCR and catalog services. Inject transport, clock, capture/write and playback interfaces. Separate request state, result context and library operations. This makes the races above testable without an actual desktop session.
2. **Add named automated tests and macOS CI.** `Package.swift` has one executable target and no test target; current checks live in executable self-test runners. The only checked-in workflow deploys the landing page. Keep the existing useful fixtures, but add asynchronous request/lifecycle tests and a macOS build/test workflow for pull requests. Test boundaries and outcomes, not copied implementation details.
3. **Centralize result provenance.** Store action ID, source/target language, completion state and producing configuration with each result. Follow-ups, speech and saving currently reconstruct meaning from mutable settings; history stores an action name, which can be renamed or duplicated. Persist partial-result status so restored fragments remain identifiable.
4. **Unify network policies.** Share proxy/bypass behavior, resource/request timeouts, error decoding, cancellation and session lifetime across translation, model catalogs and OAuth. Pool sessions by immutable network configuration or invalidate short-lived sessions explicitly. Add transcript fixtures for each supported protocol.
5. **Make persistence incremental and resilient.** History/follow-up updates rewrite the entire JSON array. Benchmark realistic large answers/dictionary snapshots, then consider transactional SQLite or an append/compaction design. Load history, vocabulary and actions independently so a corrupt history file does not prevent the other two from becoming available (`loadLibrary`, lines 1484–1497). Provide recoverable migration/error handling.
6. **Measure dictionary overhead before changing its design.** Bundled databases total 95,559,680 bytes (about 91.1 MiB). Query-plan inspection confirmed indexed form and entry lookups, so there is no evidence of a full-table-scan problem. Each lookup nevertheless reopens the database, decodes the manifest twice and prepares statements. Consider actor-owned connections, one-time manifest validation and a small bounded result cache after measuring cold/warm latency and memory. Keep attribution and stable source identities.
7. **Separate development launch from release operations.** `run.sh` terminates the packaged app and invokes the complete package script; that script rebuilds ZIP/DMG and submits for notarization whenever credential environment variables are present. Provide a signed development-bundle launch path and an explicitly requested release/notarization path. Run self-tests against the packaged resource layout before distributing artifacts. No packaging, notarization or upload was performed during this review.
8. **Make the credential threat model explicit.** The AES key derives from the hardware UUID plus public inputs; the implementation correctly comments that it does not protect against code running as the same user. This is a deliberate tradeoff, not demonstrated key compromise. If stronger local protection is required, evaluate a randomly generated installation key kept in Keychain with a stable signing identity. Keep documentation precise about credentials versus plaintext history/vocabulary.

## Validation performed

| Check | Result / boundary |
|---|---|
| `./scripts/test.sh` | Passed: warnings-as-errors Debug build, existing app self-tests, async dictionary self-tests, 2 Python importer tests |
| Release build with warnings as errors | Passed on Apple Swift 6.3.3, arm64 macOS 26 SDK |
| Release `--self-test` and `--dictionary-self-test` | Both passed |
| `zsh -n scripts/*.sh` and plist lint | Passed |
| Dictionary SQLite integrity | Both databases `ok`; no orphan form records |
| Dictionary records | Wiktionary: 103,334 entries, including 44,587 Japanese and 58,747 English; ECDICT: 59,137 English entries |
| SQLite query plans | Indexed lookups on forms and entry IDs; temporary sort for ordering |
| Additional review harness | Compiled current Swift sources with an alternate test entry point; all expected defect observations reproduced |
| Native AX/OCR/clipboard/audio UX | Inspected code paths; not exercised against user apps or data |
| Provider compatibility | Local protocol fixtures and primary-source checks; no real provider/account acceptance |
| Packaging/signing/notarization | Script review only; no release artifacts rebuilt or uploaded |

The current green test suite does not cover the reproduced defects. It also does not establish support across macOS 14/15/26, Intel hardware, live provider accounts, real permission flows, or release signing/notarization.

Temporary reproduction artifacts are at `/tmp/phraselens-review.021MjO/`: `AuditMain.swift`, `OAuthFixture.swift`, `server.py`, `results.txt`, and `build.log`. They contain only fixture credentials and may be removed by normal temporary-directory cleanup. The loopback server was stopped after testing.

Selected observed outputs:

```text
REASONING_DELTA_RENDERED=true
RESPONSES_FAILURE_IGNORED=true
ANTHROPIC_FAILURE_IGNORED=true
CORRUPT_CREDENTIALS_READ_AS_EMPTY=true
CORRUPT_CREDENTIALS_OVERWRITTEN=true
OTHER_LANGUAGE_WORD_MARKED_COLLECTED=true
SERVER_ERROR_MARKED_COMPLETED=true
STOPPED_FOLLOWUP_NOT_PERSISTED=true
EDITED_SOURCE_FOLLOWUP_WRITTEN_TO_OLD_HISTORY=true
OAUTH_REFRESH_SAVED_UNDER_WRONG_PROVIDER=true
DEFAULT_HTTP_PROXY_ROUTES_HTTPS: kCFProxyTypeNone
HISTORY_MEMORY_DISK_COUNTS=2001/2000
```

Recommended implementation order: R01–R03 first; then R04–R11 and the remaining cancellation/storage defects; then language routing and endpoint validation; finally performance and workflow improvements. Each fix should carry a focused regression at the actual failure boundary described above.
