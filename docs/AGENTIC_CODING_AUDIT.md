# Agentic coding workflow audit

Audit date: 2026-09-12. Repository: PhraseLens (`nextai-translator-swift`).
Baseline: `main`, HEAD `69138f7e277a53b60bdcfb6f5125f32459df07f6`, plus the existing working-tree changes and untracked Swift source files.

**Assessment**

The repository already supports agent-assisted implementation with useful command-line checks. The largest opportunity is to make the path from a requested change to verified, reviewable delivery explicit and repeatable. Prioritize a shared verification command, macOS CI, isolated test dependencies, and evidence tied to the code being accepted.

This is a development-workflow audit. Recommendations involving source structure are limited to making changes easier to test and review. They are not a product-feature roadmap or a request to rewrite the application.

**Scope and evidence**

The audit inventoried all 54 tracked files and the untracked development/source files, scanned declarations and workflow-related dependencies across all 37 Swift source files (18,979 lines), and read the workflow scripts, package manifest, workflow configuration, documentation, self-test structure, and critical initialization, persistence, networking, and OS-integration paths. UI source was examined for test seams and automation support; this is not a claim of exhaustive line-by-line application correctness or security review.

The existing worktree contained 12 modified tracked files and three untracked Swift files, as well as `.claude/launch.json` and an empty `.commandcode/taste/taste.md`. Those changes were preserved. This report is the only intentional repository edit made by the audit; builds refreshed ignored `.build/` output.

| Check executed | Result | Meaning and limitation |
| --- | --- | --- |
| `./scripts/test.sh` | PASS; `SELF-TEST PASSED` | Current worktree builds in Debug with compiler warnings as errors and its embedded self-test passes. |
| Release build using the same flags as `scripts/package-app.sh:18` | PASS | `swift build --disable-sandbox -c release -Xswiftc -Osize -Xswiftc -warnings-as-errors`, after sourcing the toolchain environment. |
| `.build/release/PhraseLens --self-test` | PASS | Existing self-tests also pass in the optimized executable. |
| `swift test --disable-sandbox --skip-build`, with the repository toolchain environment | EXIT 1: `no tests found` | Confirms the absence of a standard test target; does not invalidate the separate embedded self-test. |
| `git diff --check` | PASS | Whitespace check on existing unstaged changes. |
| `zsh -n` on all four shell scripts | PASS | Shell syntax only. |
| `plutil -lint packaging/Info.plist` | PASS | Plist syntax only. |

The machine reported Apple Swift 6.3.3, arm64, and Command Line Tools. The default SDK query reported 26.5; the repository script explicitly selected `/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk`. SwiftPM reported restricted access to user-level caches, but the builds and embedded tests completed successfully. Those cache warnings are separate from the structural `no tests found` result.

No application GUI, live provider requests, interactive OAuth, user text replacement, signed packaging, notarization, or deployment was executed. Clean-machine reproducibility, remote branch protection, other macOS releases, and Intel behavior remain unverified. Build timings observed here are not clean-build benchmarks.

**Existing strengths worth keeping**

- SwiftPM has one executable target and no declared third-party package dependencies (`Package.swift:5`). Setup is relatively small.
- Debug and Release build scripts already use compiler warnings as errors (`scripts/test.sh:8`, `scripts/package-app.sh:18`).
- The embedded suite contains 110 static `check(...)` call sites, with some inside loops. This is not a count of independently reported test cases or a coverage percentage.
- Tests already protect context bounds/escaping, prompt construction, action migration, request bodies, stream event parsing, Markdown parsing, speech protocol helpers, panel geometry, model catalog helpers, credentials, and vocabulary facets.
- Credential round-trip tests use a temporary directory and synthetic credentials (`SelfTestRunner.swift:1123`). This is a good isolation pattern to extend.
- `docs/DESIGN_SYSTEM.md` documents shared components, layout invariants, and AppKit workarounds. `docs/FEATURES.md:28` already acknowledges live verification boundaries.
- Packaging checks the bundle identifier, refuses an absent signing identity, and verifies the signature (`scripts/package-app.sh:34`, `:48`, `:57`). Preserve these protections when shortening the development loop.
- Selection diagnostics report roles, counts, and timing rather than selected content (`AccessibilityService.swift:17`, `:177`). They can support sanitized acceptance evidence.

**Priorities**

P0 means establish before relying on unattended implementation and acceptance; P1 strengthens regression confidence; P2 reduces recurring friction. These labels describe workflow priorities, not a claim of active incidents.

| ID | Priority | Finding | Concrete improvement | Completion evidence |
| --- | --- | --- | --- | --- |
| W1 | P0 | No checked-in project `AGENTS.md` or development contract | Add a concise entry point linking commands, architecture, change-to-test mapping, and acceptance rules | A fresh session can locate the correct check and its limits without chat history |
| W2 | P0 | No Swift CI or shared quality entry point | Add `scripts/verify.sh`; call it from a macOS PR workflow | A deliberate failing test makes the PR check fail; logs are retained |
| W3 | P0 | Development launch invokes the release packaging and optional upload path | Separate signed development bundle assembly, archive creation, and explicit notarization | Development launch produces no release archives and cannot submit to Apple |
| W4 | P1 | Test execution is monolithic and rebuilds twice | Build once; add standard named test suites incrementally | Same built executable is checked, suites are filterable, failures identify cases |
| W5 | P1 | Application workflows cannot be instantiated in a fully isolated harness | Inject network, storage, clock, and OS integration dependencies at relevant boundaries | Workflow tests run without personal data, live credentials, hotkeys, or network |
| W6 | P1 | No repeatable native UI acceptance path | Add fixture-driven preview/smoke execution plus a small OS-permission checklist | Screenshots and observations identify fixture, build, OS, and outcome |
| W7 | P1 | Successful checks are not bound to the delivery candidate | Record source/fixture hashes, toolchain, checks, and artifact identity | Editing candidate inputs invalidates the associated acceptance evidence |
| W8 | P1 | Toolchain guidance and SDK selection are machine-dependent | Add a diagnostic command and document a tested toolchain/SDK combination | Unsupported configurations fail early with a precise remedy |
| W9 | P2 | Large shared files increase navigation and edit collisions | Extract testable policies and cohesive components as changes touch them | A routine task maps to a small set of owned files and focused tests |
| W10 | P2 | Formatting, resource generation, and local agent files lack shared conventions | Pin formatting behavior and make resource inputs explicit | Checks are stable across contributors and assets do not depend on personal paths |

**W1 — Put project knowledge in the repository**

The global agreements supplied to this session are useful but do not encode PhraseLens-specific facts. `README.md:138` provides build commands, while `docs/FEATURES.md` maps capabilities to implementations. Neither defines which checks a particular change requires or what evidence is sufficient to call it done. The repository has no project `AGENTS.md`, task template, review guide, or PR template.

Add a short root `AGENTS.md` that links to a development guide and test/acceptance matrix. Include the SwiftPM entry point, why interactive use needs a signed `.app`, safe validation commands, test data locations, shared design components, persistence compatibility obligations, and authorization boundaries for external actions. Treat facts that scripts can validate as executable checks rather than prose-only rules.

For nontrivial work, use a small task record: intended behavior, scope, acceptance examples, affected modules, validation commands, and remaining questions. Small fixes should not require a large planning framework. Once a repeated failure is understood, add the smallest useful regression or instruction. Official guidance likewise recommends short, practical repository instructions and task-specific references: [OpenAI best practices](https://learn.chatgpt.com/guides/best-practices), [AGENTS.md discovery](https://learn.chatgpt.com/docs/agent-configuration/agents-md).

**W2 — Make local checks and CI use the same entry point**

The only checked-in workflow is `.github/workflows/pages.yml`. It runs on Ubuntu and deploys `landing/`; it does not build or test Swift, and source-only changes do not trigger its path filter. This is a useful website deployment workflow, but it supplies no application regression gate.

Start `scripts/verify.sh` with the checks already available: toolchain diagnostics, relevant diff whitespace checks, shell syntax, plist syntax, and the existing self-test. Add formatting once a version and baseline have been chosen. Add Release compilation at a suitable pre-merge or candidate-validation boundary. Keep one implementation of each check; CI should call the same script rather than recreate its behavior in YAML.

Run this on a macOS runner with an explicitly selected compatible toolchain, PR/push triggers, timeouts, and retained failure logs. Include package, source, tests, scripts, and packaging inputs in any path filters. Routine PR verification should need no signing certificate, provider credential, or notarization secret. Read-only workflow permissions are sufficient for that check. Remote rules requiring the check are a separate repository setting and were not inspected here.

**W3 — Separate development, packaging, and external submission**

`scripts/run.sh:12` terminates a running executable from this checkout, then calls `package-app.sh` and opens the resulting app. The packaging script builds Release, replaces the bundle, strips and signs it, creates ZIP and DMG archives, and may call `notarytool submit` when notarization environment variables are present (`package-app.sh:86–108`). Thus the command documented as development startup can perform an external submission based on inherited environment state.

Create separate commands for building/signing a local runnable bundle, generating release archives, and explicitly notarizing a release candidate. Keep the stable signed bundle identity needed by this project's interactive permission workflow. Make development startup incapable of notarization even if credentials are present. Check build/signing prerequisites before terminating the current app, and assemble into a staging location before replacing the last usable bundle.

For releases, select an expected signing identity explicitly rather than taking the first identity returned by the machine. Add a gate for the exact candidate's verification results. Existing signature verification does not prove tests passed: `package-app.sh` currently never runs the self-test. A local signed-only package can remain supported, but its status should be distinct from an accepted distribution release. No release policy was changed during this audit.

**W4 — Preserve useful tests while improving their execution**

`Package.swift:16` declares only an executable target. `Tests/` contains no files. All tests reside in `Sources/PhraseLens/Services/SelfTestRunner.swift` (1,548 lines), execute through one synchronous `run()`, and report a global pass or a list of failure messages. The application dispatches `--self-test` in `PhraseLensApp.swift:11`; test code is part of the normal executable target.

The current test script invokes `swift build` with `-warnings-as-errors`, then `swift run` without that flag. This audit observed a second full compilation during the latter command. Fix this small feedback-loop issue by running the already-built binary or using `swift run --skip-build` after a successful build, with consistent product/configuration selection. Keep error propagation intact.

Then introduce a standard SwiftPM test target and migrate tests by domain. Swift Testing or XCTest can both serve named, focused tests; select one primary convention. Keep a small executable smoke test if it remains useful. Extract a core target only where it reduces dependency coupling; a large package split is not a prerequisite to the first useful test improvement.

A local `swift test --help` check confirms support for filtering, coverage, and xUnit output options in the installed toolchain. After selecting a framework, validate the actual report format consumed by CI. Do not impose a broad coverage percentage before identifying the important missing workflows.

**W5 — Test actual workflows with controlled dependencies**

`AppModel.swift:87–108` constructs the catalog, speech, translation, tagging, library, accessibility, and OCR implementations directly; only the settings store is an initializer parameter. Initialization also loads the library and registers hotkeys (`:137–139`). `JSONFileStore.init(filename:)` resolves the real Application Support directory (`PersistentStores.swift:9`), and `LibraryStore` fixes its three file stores (`:64`). `TranslationClient` privately creates its sessions (`TranslationClient.swift:3`, `:356`), while catalog refresh instantiates its client inside the task (`ModelCatalogStore.swift:125`).

These choices make deterministic application-flow tests harder. Extend the injection pattern already present in `SettingsStore` and `CredentialStore`: pass temporary storage roots, a fake translation stream/transport, a controllable clock when timing matters, and substitutes for OS integrations. Use a composition root to select real dependencies for the application and controlled ones for tests. Start with the translation/history boundary; avoid an interface for every type merely for symmetry.

Priority regression examples, not claims that these behaviors are currently broken:

| Scenario | Current evidence | Missing workflow evidence |
| --- | --- | --- |
| Request A is cancelled, B starts, A emits late data | Request-ID checks in `AppModel.swift:250–308` | Drive interleaved streams and assert only B owns output/status/history |
| Stream emits data then disconnects, returns an error, or stops | Decoder cases in the self-test | Exercise transport, cancellation, partial output, and persistence together |
| Model catalog has multiple pages | The test manually concatenates two parsed pages (`SelfTestRunner.swift:1235`) | Verify `fetchModels` requests the second page and handles failures/loops |
| History/settings were saved by an older version | Model decoding and settings round trips are tested | Open temporary legacy files through the real stores; test malformed/unwritable data paths |
| OAuth refresh/callback is cancelled or invalid | Config serialization and request headers are tested | Fake token endpoint and callback/lifecycle tests without browser login |
| Vocabulary changes while tagging is in flight | Tag parsing/facet helpers and merge implementation exist | Verify deletion/new collection and late replies through the storage flow |

Current prompt tests establish construction contracts; they do not establish that a live model always follows those instructions. Keep that distinction in handoffs. Real provider checks can be explicitly scoped integration exercises instead of dependencies of every coding task.

The credential test removes its temporary directory but creates a random UserDefaults suite without explicit persistent-domain cleanup (`SelfTestRunner.swift:1179`). Clean that suite in the test lifecycle when improving isolation; this is a small hygiene issue, not evidence of real credentials being overwritten.

**W6 — Give agents a repeatable way to observe native behavior**

The source scan found no `#Preview`, fixture launch mode, UI-test target, or explicit `accessibilityIdentifier` usage. Existing accessibility labels and geometry checks are useful, but they do not verify the rendered window or interaction. `docs/FEATURES.md:36` describes permissions without providing reproducible acceptance steps.

Add a development-only fixture path that seeds fake output, settings, and library data. It must also substitute network clients, speech, login hooks, hotkeys, and persistence so opening it cannot use the user's real accounts or library. Data-only fixtures alone are insufficient because `AppModel` initialization already starts runtime work.

Start with repeatable native scenarios for empty/loading/success/error output, long streamed content, compact/regular layout, pop-up pin/dismiss, and action editing. Capture both a relevant screenshot and behavioral assertions; a picture cannot prove cancellation or correct persistence. Add stable accessibility identifiers to controls targeted by automation as needed.

Keep a separate small interactive checklist for Accessibility capture, focus changes, clipboard restoration, writing into a disposable test field, and OCR permissions. Run those on a Mac with the intended signed bundle and explicit test material. A CI test without those permissions should report that boundary as not run, rather than claiming full acceptance.

Useful initial cases come directly from `CHANGELOG.md:32–55`: capture launched from the menu bar, a long streaming answer continuing to scroll, and selecting text inside a pop-up without dragging the panel. Convert observed regressions into repeatable cases before adding a broad screenshot matrix.

**W7 — Bind verification and acceptance to the same inputs**

The scripts print results to the terminal but do not emit a source manifest or durable test report. Packaging writes fixed `dist/PhraseLens.app`, `.zip`, and `.dmg` paths and rebuilds from the current tree. A prior successful check therefore cannot identify the later packaged candidate.

For a small local loop, record the commit, relevant dirty/untracked source hashes, toolchain/SDK, build configuration, fixture version, command exit codes, and check outcomes. For release acceptance or concurrent work, validate an isolated candidate containing the intended uncommitted files and package that same candidate. A Git commit alone is insufficient for the current dirty worktree, which includes required untracked Swift sources.

Use explicit `PASS`, `FAIL`, `BLOCKED`, and `NOT_RUN` results for each required check. Record local-only checks separately from interactive acceptance. Preserve failure logs and sanitized fixtures; do not include provider tokens, the user's selected text, or their real library. For distributables, record the relevant artifact checksum and signature information after the final mutation, including stapling if used.

Review should examine the diff, behavior contract, tests, and evidence. Pay particular attention when a patch changes implementation and weakens the corresponding test expectation. Human acceptance can then focus on interaction quality and product intent. A clean check run is evidence for its scope, not blanket approval to publish.

**W8 — Make the supported environment explicit**

`README.md:109` says “Swift 6.2 or Xcode 16+”, but Xcode 16 and 16.2 ship Swift 6.0, and 16.4 ships Swift 6.1. Those bundled compilers do not satisfy the package's Swift tools 6.2 requirement. Apple's [Xcode system requirements table](https://developer.apple.com/xcode/system-requirements) establishes those versions.

`toolchain-env.sh:8` prefers hard-coded Command Line Tools SDK directories and includes a 15.4 fallback. That is machine-oriented rather than a documented compiler/SDK compatibility contract. The code also references `glassEffect` behind a runtime availability guard (`Components.swift:1417`); an older-SDK compilation path should not be promised without actually testing it. This audit did not build against the fallback SDK.

Add `scripts/doctor.sh` to report the selected compiler, developer directory, SDK, architecture, writable cache paths, and required tools. Distinguish minimum runtime macOS from the build-machine and SDK requirements. Document a tested combination and make CI select it. Fail early on unsupported combinations; do not require developers to infer setup errors from Swift compiler diagnostics.

**W9 — Reduce navigation cost at the boundaries that matter**

Large files include `Components.swift` (1,871 lines), `SelfTestRunner.swift` (1,548), `AppModel.swift` (1,486), `SettingsView.swift` (1,200), `AccessibilityService.swift` (1,181), `AppModels.swift` (1,134), and `OpenAIOAuthService.swift` (1,116). File size alone is not a defect. The workflow cost is that unrelated tasks converge on shared files and pure logic is mixed with runtime integration.

First separate tests by domain and make the dependency seams in W5 controllable. Then, as relevant tasks arise, move selection matching/evidence policies away from OS traversal, move cohesive window coordination out of `AppModel`, and split shared UI components by responsibility. Keep stable public behavior and source-of-truth documentation. Avoid a standalone broad refactor that has no focused acceptance criteria.

For future concurrent agent tasks, use separate worktrees for independent mutations and define file ownership. Worktrees isolate source and build files, but do not automatically isolate Application Support, UserDefaults, global hotkeys, or OAuth's fixed callback port (`OpenAIOAuthService.swift:12–15`). Interactive tests need a deliberate data/runtime isolation strategy as well.

**W10 — Remove recurring environmental noise**

- No shared formatter configuration or format-check command exists. Choose and pin one Swift formatting convention, provide check-only and explicit write commands, and keep any baseline reformat in its own change. The installed toolchain already supplies `swift-format`.
- `scripts/generate-icons.swift:11–18` prefers a developer-specific upload path when it exists. Its fallback input is `packaging/AppLogo.png`, which is also overwritten as an output (`:210–216`). Preserve a separate raw input asset or require an explicit input argument; document outputs and validate their presence. Do not regenerate current assets merely to audit them.
- `.claude/launch.json` is untracked and only starts the landing-page server; `.commandcode/taste/taste.md` is empty. Decide which tool-specific configuration is shared and which remains local. These files currently do not provide a native-app development contract.
- Keep generated reports/builds out of ordinary source changes with deliberate ignore patterns. Keep fixtures synthetic and credentials outside the repository. No dependency lockfile is required solely for appearance: there are no declared package dependencies today; establish pinning when dependencies are introduced.
- Add small checks for version/bundle metadata consistency when formalizing release preparation. Documentation and the landing page should consume or be checked against the same release facts where practical.

**Proposed command contract — not implemented**

| Command | Intended use | Expected effects |
| --- | --- | --- |
| `./scripts/doctor.sh` | Diagnose setup | Report environment and prerequisites; no account access |
| `./scripts/verify.sh` | Default coding and CI gate | Build/check/test with controlled fixtures; no signed release, GUI, or external submission |
| `./scripts/test.sh` | Fast focused regression loop | Build once, run named tests; retain current tests during migration |
| `./scripts/run.sh` | Interactive local development | Build/sign a runnable app with documented data scope; no ZIP/DMG or notarization |
| `./scripts/qa.sh` | Candidate acceptance | Freeze/identify inputs, run required checks, retain evidence |
| `./scripts/package-app.sh` | Produce a requested distribution candidate | Package the verified candidate with explicit signature/status metadata |
| Explicit notarization/publishing command | Authorized external release step | Submit only the reviewed candidate; preserve submission outcome |

Keep the command surface small. The first implementation does not need all commands at once. Distinct responsibilities can share internal helpers without merging their side effects.

**Implementation sequence**

1. **Establish a trustworthy default loop.** Add project guidance, correct setup documentation, fix the double build, create `verify.sh`, add macOS CI, and make development launch incapable of implicit notarization. Acceptance: current tests pass locally/CI, a controlled failing test blocks the check, and development launch cannot enter the upload branch.
2. **Make important regressions deterministic.** Add standard suites, temporary store roots, and an injectable translation path. Cover late chunks/cancellation, partial failures, and history persistence first. Acceptance: focused tests run without personal credentials/data, and a deliberately introduced relevant defect is detected. Do not keep intentionally broken changes.
3. **Make handoff and release inspectable.** Add fixture-driven native smoke scenarios, the OS-permission checklist, candidate manifests, retained reports, and a release gate. Acceptance: results identify the candidate; source changes invalidate acceptance; interactive checks state their actual status.
4. **Reduce maintenance friction gradually.** Add formatter/resource checks and split shared files only as feature work encounters their boundaries. Extract a reusable skill after a workflow is stable enough to repeat; scripts remain the executable authority.

Suggested effort ordering is based on observed dependencies, not a calendar estimate. The native UI harness is likely the largest piece because runtime initialization and persistence need isolation first.

**Repository coverage map**

| Area | Files included | Workflow conclusion |
| --- | --- | --- |
| App | `AppModel.swift`, `PhraseLensApp.swift` | Embedded test entry exists; application initialization performs runtime work |
| Core models | `AppModels.swift`, `PronunciationGuide.swift` | Action/settings/model contracts have testable helpers; keep compatibility cases |
| Vocabulary models | `VocabularyFacets.swift`, `VocabularyTaxonomy.swift` | Good pure-policy test surface; move cases into named suites |
| Selection/OS | `AccessibilityService.swift`, `ActiveApplicationTracker.swift`, `GlobalHotKeyManager.swift`, `OCRService.swift`, `LaunchAtLoginService.swift` | Separate pure helpers from permission-dependent integration evidence |
| Storage/auth | `PersistentStores.swift`, `CredentialStore.swift`, `KeychainStore.swift`, `SettingsStore.swift`, `OpenAIOAuthService.swift` | Extend existing credential injection to storage and lifecycle tests |
| Provider/prompt | `TranslationClient.swift`, `EndpointValidator.swift`, `PromptBuilder.swift`, `ModelCatalogClient.swift`, `ModelCatalogStore.swift`, `LanguageDetector.swift`, `VocabularyTagger.swift` | Helpers are tested; transport and async ownership need deterministic tests |
| Speech | `SpeechService.swift`, `SpokenText.swift` | Parsing/formatting checks exist; playback remains a distinct integration boundary |
| Self-tests | `SelfTestRunner.swift` | Useful baseline, currently one synchronous executable-embedded suite |
| Shared UI | `Components.swift`, `DesignSystem.swift`, `MarkdownText.swift`, `ShortcutRecorder.swift` | Shared conventions exist; no fixture-driven rendering harness found |
| UI screens | `ActionsView.swift`, `FollowUpView.swift`, `LibraryViews.swift`, `RootView.swift`, `SelectionTranslationPanel.swift`, `SettingsView.swift`, `TranslatorView.swift` | Add representative native acceptance cases using isolated dependencies |
| Build/release | `Package.swift`, all five files in `scripts/`, `packaging/Info.plist`, packaging assets | Existing automation needs clearer environment and side-effect boundaries |
| Documentation/site | `README.md`, `CHANGELOG.md`, `docs/FEATURES.md`, `docs/DESIGN_SYSTEM.md`, `landing/`, `.github/workflows/pages.yml` | Product documentation and site deployment exist; development acceptance is missing |
| Repository metadata | `.gitignore`, `LICENSE`, `NOTICE`, untracked tool configuration | Preserve legal files; clarify shared versus personal/generated inputs |

**Operating loop to aim for**

Define the intended behavior and acceptance examples → inspect the relevant modules → implement a bounded change → run focused and required checks → review the diff and evidence → complete native acceptance when applicable → package/publish only under the relevant authorization.

The immediate success criterion is that a new agent can take a small task, identify the correct files, reproduce the failure or acceptance case, change the code, and hand back evidence that another person can verify without reconstructing the entire conversation.
