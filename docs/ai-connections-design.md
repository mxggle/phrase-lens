# AI connections and action routing

This document records the intended behavior approved for the connection and
action settings update. It is a design and acceptance checklist, not a claim
that live providers or every UI interaction have been verified.

## Configuration model

A saved connection has a stable ID, a user-facing name, a supported provider
protocol, endpoint and authentication settings, and its own credentials. More
than one connection may use the same provider protocol. Custom gateways use an
existing supported protocol; arbitrary request-template editing is out of scope.

Credentials stay in the existing credential store, keyed by connection identity.
They are never embedded in actions, ordinary settings, or history. OAuth refresh
updates the connection that owns the session, even if another connection is
selected in Settings during the refresh.

The global default is one explicit connection and model pair. Each action has
one of two choices:

- Follow the global default.
- Use an explicit connection and model pair.

There is no additional inheritance from a connection's preferred model. A
remembered model in the connection editor can help populate a picker but does
not change an action's explicit selection.

## Editing and execution

Selecting a connection to edit does not select the global default. Making it
the default is a separate, labeled operation. First-run setup can create and
select the initial default in a single guided flow.

Changing the global default changes only actions that follow it. Switching
actions does not change the default. Editing one action does not change another.
Switching an action to a different connection requires a model for that
connection; a model ID from the previous connection must not silently carry over.

Duplicating an action copies its model selection and shares the connection
reference. Resetting its prompt preserves its AI selection. Restoring all action
defaults may reset both if the confirmation explicitly describes that behavior.

The main UI shows the selected action's effective connection and model. Its
readiness indicator checks that effective route rather than the global default
or the connection currently open in Settings.

At request start, resolve the connection, model, generation settings, proxy, and
matching credential identity. Later edits cannot combine an old endpoint with a
new account's credentials. A missing connection, credential, or model is a
visible error; it never triggers an implicit switch to a different service.

## Follow-ups and history

An answer retains the route and prompt context that produced it. Follow-ups use
that context even after the selected action, languages, or global default change.
History stores enough non-secret metadata to restore the same behavior.

A credential refresh within the same OAuth identity should not invalidate an
otherwise usable conversation. A changed destination or account must not
silently receive an existing conversation. If the original route can no longer
be used, show a recovery action that explicitly adopts a selected connection or
reruns the original input. Historical answers remain readable.

Legacy history without reliable connection metadata must not guess an account
based solely on provider name. Continuing it requires an explicit selection or
rerun so the user knows where it will be sent.

The writing shortcut uses the Translate action's route. Background vocabulary
organization uses the global default. Dictionary lookup remains local.

## Model catalogs and connection lifecycle

Model catalogs are isolated by connection identity and relevant endpoint/auth
configuration. Different accounts at the same endpoint must not share a catalog
implicitly. Editing endpoint or credentials invalidates the relevant catalog;
renaming a connection does not alter routing. Manual model IDs and Azure
deployment names remain supported when catalog enumeration is unavailable.

Deleting a connection referenced by an action or the global default is blocked
with a list of those references, or requires explicit reassignment. History may
outlive its connection; it must report the missing connection when continued.
The UI distinguishes saved configuration from a successful live connection test.

## Migration

Migrate the existing active provider and saved provider configurations into
connections, preserving the current effective default. Copy existing app-owned
credentials to their connection identities without automatically reading the
legacy system Keychain.

Preserve existing action model choices. Active explicit model choices become
explicit routes for the corresponding migrated connection. Other remembered
choices remain retained as legacy data rather than being silently discarded.
Custom actions load separately from settings and need the same migration.

Migration must be repeatable and preserve legacy sources until the new state is
successfully saved. A failed credential or settings write must leave a visible
failure and a retryable migration, not a falsely completed migration marker.

## Acceptance checks

- Two connections of the same provider keep different keys after relaunch.
- Editing a nondefault connection leaves the global default unchanged.
- Default-following and pinned actions resolve independently.
- The outbound request contains the selected action's model and correct credential.
- Switching settings during an OAuth refresh cannot redirect the credential write.
- A result's follow-up preserves its route, target language, and original prompt.
- Missing or changed connections cannot cause silent follow-up fallback.
- Old settings, custom actions, and history decode without losing existing data.
- Prompt reset preserves routing; full reset and deletion report their effects.
- Model catalogs do not cross account boundaries.
- A broken global default does not mark a valid pinned action as unconfigured.

Use isolated stores and synthetic credentials for automated checks. Report build,
unit/integration, native UI, live provider, packaging, and publication evidence
separately.

## Verification recorded on 2026-09-27

The final `./scripts/test.sh` run passed: the warnings-as-errors Swift build,
standalone self-tests, dictionary and connection integration checks, two Python
dictionary tests, and twelve Python release tests. `git diff --check` passed.
Connection integration checks exercise independent keys for the same provider,
actual request model/auth pairing, default and pinned resolution, migration
origin and repeatability, prompt reset, history follow-up preparation, text swap
context invalidation, concurrent OAuth refresh, logout, and account replacement
while refresh is suspended. All credentials in these tests are synthetic.

An isolated debug QA app launched, but the native UI inspection service timed
out without returning an accessibility tree or screenshot. Native interaction
and visual acceptance remain unverified. Live provider authentication and API
requests were not exercised. The user's normal app was not restarted or replaced
for this implementation; the isolated QA process was closed after inspection.
