# Updater verification — 2026-09-27

Environment: macOS 26.6.2 on Apple Silicon, Sparkle 2.10.0, local self-signed
code-signing identity (no Apple Team ID). No Apple Developer Program credentials
or notarization were used.

The local harness copies the real DEBUG PhraseLens executable into isolated app
bundles, with unique bundle identifiers and data directories, separate ephemeral
Ed25519 keys, and a loopback HTTP feed. The test allowance is compiled out of
Release. Production requires HTTPS. Both feed authentication and archive
verification before extraction remain enabled in the test apps.

## Observed results

| Scenario | Result |
| --- | --- |
| Manual check from build 9001 | Sparkle offered build 9002. |
| Download, install, and relaunch | Used the actual Sparkle dialogs. The installed app changed to build 9002; a new process ran from the same installation path; nested code-signature verification passed. |
| Check again on build 9002 | Actual dialog reported that 0.0.9002 was the newest version. |
| Archive changed by one byte after signing, same length | Actual dialog rejected the improperly signed update. Installed build stayed 9001 with a valid signature. |
| Feed modified after signing | Actual dialog rejected the improperly signed feed before offering an update. |
| Settings preferences | Enabling automatic checks enabled the separate automatic download/install control. Both choices persisted in the test app's defaults. |
| Background check and download | A fresh test installation with both preferences enabled requested the feed and ZIP without invoking Check for Updates. Server returned HTTP 200 for both. |
| Automatic installation on ordinary quit | After the background download, Command-Q installed build 9002 over 9001. The replacement passed nested code-signature verification and reopened normally. |
| Universal application packaging | arm64 and x86_64 builds completed; the app and embedded Sparkle code passed nested signature verification. |
| Production artifact preflight | ZIP and read-only mounted DMG matched the signed application, including metadata, contents, permissions, and symlinks. |
| Production update signatures | Generated the local appcast using the production Keychain account. Sparkle verified the archive signature and the signed feed; version, pinned URL, size, and minimum macOS checks passed. |

## Pending checks and boundaries

- Production signing required macOS Keychain authorization. Generation and
  verification subsequently succeeded; the private key was not exported.
- Nothing here establishes a public feed deployment or a new release. Existing
  0.8.0 users need a manual install of the first updater-enabled release.
- First installation of a browser-downloaded, unnotarized app, Intel runtime
  behavior, managed Macs, administrator authorization, and preservation of
  Accessibility/Screen Recording permissions on users' Macs remain unverified.
  The isolated tests did not grant system permissions or access user credentials.

Run `./scripts/test.sh` for build and regression checks. For reproducing the
native update tests, start with `python3 scripts/test_updater_e2e.py --help`.
The completed test applications and local servers were stopped, and their
ephemeral signing keys were removed after verification.
See [UPDATES.md](UPDATES.md) for the production trust and publishing model.
