#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "${SCRIPT_DIR:h}"

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
}

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
python3 scripts/sparkle-appcast.py --dmg dist/PhraseLens.dmg
( cd dist && shasum -a 256 PhraseLens.dmg PhraseLens.zip appcast.xml > SHA256SUMS.txt )
codesign --verify --deep --strict dist/PhraseLens.app
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/PhraseLens.app/Contents/Info.plist)" = "${NEXT}"

git add packaging/Info.plist CHANGELOG.md landing/index.html landing/zh/index.html
git commit -m "chore(release): ${NEXT}"
git tag "v${NEXT}"
git push --atomic origin main "v${NEXT}"

publish_release "${NEXT}"
