# Application updates

PhraseLens uses pinned Sparkle 2.10.0 to check for updates, download signed archives, install the replacement application, and relaunch. No paid Apple Developer account is needed for the Sparkle Ed25519 signing key or update protocol. Apple notarization is separate and needs a Developer ID; see [Notarization](#notarization).

## User experience and bootstrap

Install the first updater-enabled release manually from [GitHub Releases](https://github.com/mxggle/phrase-lens/releases/latest) and move PhraseLens.app into Applications. Older builds without Sparkle cannot discover this update themselves. Until releases are notarized, approve the application through macOS's app-specific Open/Open Anyway flow; never disable Gatekeeper globally.

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

## Notarization

Notarization lets a downloaded PhraseLens open without the Open Anyway step. It needs a paid Apple Developer Program membership. Once per Mac:

1. Enroll at [developer.apple.com/programs](https://developer.apple.com/programs/) and note the 10-character Team ID.
2. Create a **Developer ID Application** certificate in Xcode > Settings > Accounts > Manage Certificates, or at developer.apple.com > Certificates. `security find-identity -v -p codesigning` must list it.
3. Create an app-specific password at [account.apple.com](https://account.apple.com) > Sign-In and Security.
4. Store the credentials in the login Keychain. notarytool prompts for the password:

   ```bash
   xcrun notarytool store-credentials phraselens-notary --apple-id <apple-id> --team-id <team-id>
   ```

`package-app.sh` prefers a Developer ID identity over any other signing identity, signs every component with a secure timestamp, notarizes and staples both the app and the DMG, and checks both with Gatekeeper. Self-signed local builds keep working without a timestamp and skip notarization.

`release.sh` checks the `phraselens-notary` profile before it changes any version files. It refuses to publish an app or DMG without a stapled ticket unless `ALLOW_UNNOTARIZED=1` is set. Use `NOTARY_PROFILE` to choose a different profile.

Switching from the self-signed identity to Developer ID changes the app's designated requirement. Existing users must grant Accessibility and Screen Recording again after that update; mention this in its release notes. Sparkle accepts the update because the Ed25519 key does not change. Rotate only one of the update key and the signing identity in a single release.

After the first notarized release, remove the `caveats` block from `Casks/phraselens.rb` in [mxggle/homebrew-tap](https://github.com/mxggle/homebrew-tap) and the "Opening it the first time" section from the README.

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

Ed25519 authenticates updates to an already trusted application. It does not provide Apple notarization, malware review, or a Developer ID identity. Initial installation remains manual, and macOS can still require app-specific approval or reject a downloaded build under its policies. A notarized release removes the first-launch approval; see [Notarization](#notarization).

References: [Sparkle setup and signing](https://sparkle-project.org/documentation/), [publishing updates](https://sparkle-project.org/documentation/publishing/), and [security settings](https://sparkle-project.org/documentation/customization/).
