# Application updates

PhraseLens uses pinned Sparkle 2.10.0 to check for updates, download signed archives, install the replacement application, and relaunch. No paid Apple Developer account is needed for the Sparkle Ed25519 signing key or update protocol. Apple notarization and Developer ID distribution remain separate requirements that this setup does not satisfy.

## User experience and bootstrap

Install the first updater-enabled release manually from [GitHub Releases](https://github.com/mxggle/phrase-lens/releases/latest) and move PhraseLens.app into Applications. Older builds without Sparkle cannot discover this update themselves. Approve an unnotarized application through macOS's app-specific Open/Open Anyway flow when available; never disable Gatekeeper globally.

Sparkle asks whether to check automatically on the second launch. Users can also check manually and change the update preferences in Settings. Automatic downloading requires a separate explicit opt-in. System profiling is disabled. Update checks contact GitHub for release metadata and assets; they do not send translation text or provider credentials.

## Trust and packaging

The application's `SUPublicEDKey` pins the update-signing public key. The corresponding private key stays in the macOS login Keychain under Sparkle account `phraselens-updates`. Both `SUVerifyUpdateBeforeExtraction` and `SURequireSignedFeed` are enabled: Sparkle authenticates archives before extracting them and authenticates the feed before trusting its contents. Release notes are embedded in that signed feed.

The feed is [the latest release's appcast.xml asset](https://github.com/mxggle/phrase-lens/releases/latest/download/appcast.xml). Each enclosure points to a version-pinned GitHub release ZIP, rather than a moving latest ZIP. `CFBundleVersion` increases for each release and determines update order; `CFBundleShortVersionString` supplies the display version. The feed also preserves the packaged minimum macOS requirement.

Packaging embeds Sparkle's framework and helper applications and signs the nested code before the outer application. When the local signing identity has no Apple Team ID, packaging applies `com.apple.security.cs.disable-library-validation` to this application only so it can load the framework. This is an application entitlement, not a change to macOS security settings. Archive and feed signature verification remain required.

## Maintainer setup

Resolve the pinned Swift package and inspect the existing public key:

```sh
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account phraselens-updates -p
```

The production key already exists on the configured release Mac. `-p` reads the existing public key without creating or exporting a private key. Compare it with `SUPublicEDKey` in `packaging/Info.plist`. Do not replace that public key with an unrelated key: installed applications trust the old key.

For a new independent deployment only, Sparkle's `generate_keys --account YOUR_ACCOUNT` creates a private key in Keychain and prints the public key. Choose the account before embedding its public key and distributing the first build. Keep private keys out of source control, logs, release assets, and environment arguments. Access to the release Mac's signing Keychain is required for unattended releases; locked or unavailable Keychain access must stop the release.

Maintainers are responsible for a secure, recoverable signing-key backup. The normal release scripts never export the key. Without the original Ed25519 key and without an Apple Developer ID fallback, losing the key means users must manually install a new trusted build. Do not silently rotate the embedded key or weaken verification to recover.

## Release automation

The opted-in `.codex/release.json` adapter invokes `scripts/release.sh` after authorized changes reach main. Existing release versioning and changelog preparation also apply to updater releases.

1. Build, test, and package the app. Generate `dist/appcast.xml` using `scripts/sparkle-appcast.py` before committing or pushing the release metadata. The helper reads the existing Keychain public key and requires it to match the packaged application's key.
2. Sparkle's `generate_appcast` signs the archive and feed. The helper validates the pinned URL, build and display versions, minimum macOS, archive length, and signatures using Sparkle's `sign_update`.
3. Include `appcast.xml` in `SHA256SUMS.txt`. Create a draft release containing `PhraseLens.dmg`, `PhraseLens.zip`, `SHA256SUMS.txt`, and `appcast.xml`.
4. Download every uploaded draft asset and compare its bytes with the local asset. Only then publish the draft as latest, allowing the feed redirect to advance.

A failed upload or comparison leaves the release unpublished. `./scripts/release.sh --resume` can finish a draft at the matching release tag; it refuses to replace assets in an already published release. `./scripts/release.sh --dry-run` previews version planning without publishing. Running the normal release command commits, tags, pushes, and publishes through the opted-in workflow; implementation or local testing alone is not an instruction to run it.

Before signing, the helper validates production identity, version, build, update key, and security settings against `packaging/Info.plist`. It checks ZIP paths before extraction, verifies nested code signatures, and compares bundle hashes, symlinks, and permissions with the loose app. Release invocations also mount the DMG read-only, compare its application, and detach it. A same-version stale archive cannot pass by matching version numbers alone.

To verify ZIP and DMG artifacts without signing or accessing Keychain:

```sh
python3 scripts/sparkle-appcast.py --verify-artifacts-only --dmg dist/PhraseLens.dmg
```

To generate a feed locally without publishing:

```sh
./scripts/package-app.sh
python3 scripts/sparkle-appcast.py --dmg dist/PhraseLens.dmg
```

## Verification and limits

`./scripts/test.sh` includes focused feed validation tests. `scripts/test_updater_e2e.py` is the separate local integration harness for exercising real Sparkle update behavior with isolated test applications and a local feed; inspect its command-line help for supported options. A localhost test does not establish that the public GitHub feed exists, that a release was published, or that a browser-downloaded application passes first-launch Gatekeeper checks.

Verify the actual signed feed, archive acceptance, installation, relaunch, and rejection of tampered content separately from unit tests. Record the results from the current run rather than treating the presence of the harness as a passing result.

Ed25519 authenticates updates to an already trusted application. It does not provide Apple notarization, malware review, or a Developer ID identity. Initial installation remains manual, and macOS can still require app-specific approval or reject a downloaded build under its policies. No paid-account bootstrap, notarization, or public deployment is implied by this implementation.

References: [Sparkle setup and signing](https://sparkle-project.org/documentation/), [publishing updates](https://sparkle-project.org/documentation/publishing/), and [security settings](https://sparkle-project.org/documentation/customization/).
