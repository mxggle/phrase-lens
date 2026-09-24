#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "${SCRIPT_DIR:h}"

publish_release() {
    local version="$1"
    if [[ ! -f dist/PhraseLens.dmg || ! -f dist/PhraseLens.zip || ! -f dist/SHA256SUMS.txt ]]; then
        print -u2 "Release assets are missing from dist/. Package this version before retrying."
        exit 1
    fi
    if gh release view "v${version}" >/dev/null 2>&1; then
        gh release upload "v${version}" dist/PhraseLens.dmg dist/PhraseLens.zip dist/SHA256SUMS.txt --clobber
    else
        gh release create "v${version}" dist/PhraseLens.dmg dist/PhraseLens.zip dist/SHA256SUMS.txt \
            --title "PhraseLens v${version}" --notes-file <(python3 - "${version}" <<'PY'
import re, sys
from pathlib import Path
version = re.escape(sys.argv[1])
text = Path('CHANGELOG.md').read_text()
match = re.search(rf'^## \[{version}\].*?\n(.*?)(?=^## \[)', text, re.M | re.S)
if not match:
    raise SystemExit('Release notes missing from CHANGELOG.md')
print(match.group(1).strip())
PY
)
    fi
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
( cd dist && shasum -a 256 PhraseLens.dmg PhraseLens.zip > SHA256SUMS.txt )
codesign --verify --deep --strict dist/PhraseLens.app
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/PhraseLens.app/Contents/Info.plist)" = "${NEXT}"

git add packaging/Info.plist CHANGELOG.md landing/index.html landing/zh/index.html
git commit -m "chore(release): ${NEXT}"
git tag "v${NEXT}"
git push --atomic origin main "v${NEXT}"

publish_release "${NEXT}"
