#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "${SCRIPT_DIR:h}"

# Public releases must pass Gatekeeper on first launch. ALLOW_UNNOTARIZED=1
# publishes a signed but unnotarized build, which macOS blocks until approved.
require_notarized() {
    if xcrun stapler validate -q dist/PhraseLens.app && xcrun stapler validate -q dist/PhraseLens.dmg; then
        return 0
    fi
    if [[ "${ALLOW_UNNOTARIZED:-}" == "1" ]]; then
        print -u2 "WARNING: publishing an unnotarized build because ALLOW_UNNOTARIZED=1."
        return 0
    fi
    print -u2 "dist/PhraseLens.app or dist/PhraseLens.dmg has no notarization ticket."
    print -u2 "Set NOTARY_PROFILE (see docs/UPDATES.md), or ALLOW_UNNOTARIZED=1 to publish anyway."
    return 1
}

publish_release() {
    local version="$1"
    if [[ ! -f dist/PhraseLens.dmg || ! -f dist/PhraseLens.zip ]]; then
        print -u2 "Release assets are missing; package this version before retrying."
        return 1
    fi
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/PhraseLens.app/Contents/Info.plist)" != "${version}" ]]; then
        print -u2 "Packaged app version does not match the release."
        return 1
    fi
    require_notarized || return 1
    python3 scripts/sparkle-appcast.py --dmg dist/PhraseLens.dmg
    ( cd dist && shasum -a 256 PhraseLens.dmg PhraseLens.zip appcast.xml > SHA256SUMS.txt )
    if gh release view "v${version}" >/dev/null 2>&1; then
        if [[ "$(gh release view "v${version}" --json isDraft --jq .isDraft)" != "true" ]]; then
            print -u2 "Release v${version} is already public; refusing to replace signed assets."
            exit 1
        fi
        gh release upload "v${version}" dist/PhraseLens.dmg dist/PhraseLens.zip dist/SHA256SUMS.txt dist/appcast.xml --clobber
    else
        local notes_file
        notes_file="$(mktemp)"
        if ! python3 - "${version}" > "${notes_file}" <<'PYNOTES'
import re, sys
from pathlib import Path
version = re.escape(sys.argv[1])
text = Path('CHANGELOG.md').read_text()
match = re.search(rf'^## \[{version}\].*?\n(.*?)(?=^## \[)', text, re.M | re.S)
if not match:
    raise SystemExit('Release notes missing from CHANGELOG.md')
print(match.group(1).strip())
PYNOTES
        then
            rm -f "${notes_file}"
            return 1
        fi
        if ! gh release create "v${version}" dist/PhraseLens.dmg dist/PhraseLens.zip dist/SHA256SUMS.txt dist/appcast.xml --draft \
            --title "PhraseLens v${version}" --notes-file "${notes_file}"; then
            rm -f "${notes_file}"
            return 1
        fi
        rm -f "${notes_file}"
    fi
    # Download the draft assets and compare every byte before latest can advance.
    local verification_dir
    verification_dir="$(mktemp -d)"
    if ! gh release download "v${version}" --dir "${verification_dir}"; then
        rm -rf "${verification_dir}"
        return 1
    fi
    local asset
    for asset in PhraseLens.dmg PhraseLens.zip SHA256SUMS.txt appcast.xml; do
        if ! cmp -s "dist/${asset}" "${verification_dir}/${asset}"; then
            print -u2 "Uploaded asset ${asset} does not match; release remains draft."
            rm -rf "${verification_dir}"
            return 1
        fi
    done
    rm -rf "${verification_dir}"
    gh release edit "v${version}" --draft=false --latest
    gh release view "v${version}" --json url,assets --jq '{url, assets: [.assets[].name]}'
    update_homebrew_tap "${version}"
}

# Runs after the release is public so the cask never points at a draft asset.
update_homebrew_tap() {
    local version="$1" tap_dir
    tap_dir="$(mktemp -d)"
    if ! gh repo clone mxggle/homebrew-tap "${tap_dir}" -- --quiet \
        || ! python3 scripts/release.py cask dist/PhraseLens.dmg "${tap_dir}/Casks/phraselens.rb" >/dev/null; then
        print -u2 "Homebrew tap update failed; the release is live. Retry with ./scripts/release.sh --update-tap."
        rm -rf "${tap_dir}"
        return 1
    fi
    if git -C "${tap_dir}" diff --quiet; then
        rm -rf "${tap_dir}"
        return 0
    fi
    git -C "${tap_dir}" commit --quiet -am "phraselens ${version}"
    if ! git -C "${tap_dir}" push --quiet origin main; then
        print -u2 "Homebrew tap push failed; the release is live. Retry with ./scripts/release.sh --update-tap."
        rm -rf "${tap_dir}"
        return 1
    fi
    rm -rf "${tap_dir}"
}

if [[ "${1:-}" == "--update-tap" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/PhraseLens.app/Contents/Info.plist)"
    if [[ "$(gh release view "v${VERSION}" --json isDraft --jq .isDraft)" != "false" ]]; then
        print -u2 "Release v${VERSION} is not public yet; refusing to point the cask at it."
        exit 1
    fi
    update_homebrew_tap "${VERSION}"
    exit 0
fi

if [[ "${1:-}" == "--dry-run" ]]; then
    git fetch origin main --tags --quiet
    python3 scripts/release.py plan
    exit 0
fi

if [[ "$(git branch --show-current)" != "main" ]]; then
    print -u2 "Release from main after changes have been merged."
    exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
    print -u2 "Commit or set aside tracked changes before release."
    exit 1
fi
if [[ -n "$(git ls-files --others --exclude-standard | grep -Ev '^(\.claude|\.commandcode)/' || true)" ]]; then
    print -u2 "Commit or set aside untracked project files before release."
    exit 1
fi
git fetch origin main --tags --quiet
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
    print -u2 "Local main must match origin/main. Update it before releasing."
    exit 1
fi
gh auth status >/dev/null

if [[ "${1:-}" == "--resume" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' packaging/Info.plist)"
    if [[ "$(git rev-parse "v${VERSION}")" != "$(git rev-parse HEAD)" ]]; then
        print -u2 "HEAD is not the release tag v${VERSION}; refusing to resume."
        exit 1
    fi
    publish_release "${VERSION}"
    exit 0
fi

# Check notarization credentials before any version files change.
if [[ "${ALLOW_UNNOTARIZED:-}" != "1" && -z "${NOTARY_APPLE_ID:-}" ]]; then
    export NOTARY_PROFILE="${NOTARY_PROFILE:-phraselens-notary}"
    if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
        print -u2 "Notary profile '${NOTARY_PROFILE}' is missing or rejected. See docs/UPDATES.md > Notarization."
        exit 1
    fi
fi

PLAN="$(python3 scripts/release.py plan)"
NEXT="$(print -r -- "${PLAN}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("next", ""))')"
if [[ -z "${NEXT}" ]]; then
    print "No unreleased changes."
    exit 0
fi
print -r -- "${PLAN}"

python3 scripts/release.py prepare >/dev/null
./scripts/test.sh
./scripts/package-app.sh
require_notarized
python3 scripts/sparkle-appcast.py --dmg dist/PhraseLens.dmg
( cd dist && shasum -a 256 PhraseLens.dmg PhraseLens.zip appcast.xml > SHA256SUMS.txt )
codesign --verify --deep --strict dist/PhraseLens.app
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/PhraseLens.app/Contents/Info.plist)" = "${NEXT}"

git add packaging/Info.plist CHANGELOG.md landing/index.html landing/zh/index.html
git commit -m "chore(release): ${NEXT}"
git tag "v${NEXT}"
git push --atomic origin main "v${NEXT}"

publish_release "${NEXT}"
