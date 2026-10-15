#!/bin/zsh
# Runs the UI smoke test on an iPhone Simulator and copies its screenshots to
# build/screenshots/. Pass a simulator name or UDID to pick the device.
#   ./scripts/screenshots.sh ["iPhone 18 Pro"]
set -euo pipefail

cd "${0:A:h:h}"
device="${1:-iPhone 18 Pro}"
(( $# )) && shift
if [[ "$device" == *-*-*-*-* ]]; then destination="platform=iOS Simulator,id=$device"
else destination="platform=iOS Simulator,name=$device"; fi
out="$PWD/build/screenshots"
mkdir -p "$out"

command -v xcodegen >/dev/null && xcodegen generate --quiet

# A page with one word for the Share sheet test, served from this Mac; the
# Simulator reaches it on localhost.
page="$(mktemp -d)"
print '<!doctype html><meta name="viewport" content="width=device-width"><p style="font-size:40px;margin:80px 24px">serendipity</p>' > "$page/index.html"
python3 -m http.server 8765 --bind 127.0.0.1 --directory "$page" >/dev/null 2>&1 &
server=$!
trap 'kill $server 2>/dev/null; rm -rf "$page"' EXIT

TEST_RUNNER_SCREENSHOT_DIR="$out" \
TEST_RUNNER_SHARE_PAGE_URL="http://localhost:8765/" \
xcodebuild \
  -project PhraseLens.xcodeproj \
  -scheme PhraseLens \
  -destination "$destination" \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- \
  test "$@" || status=$?

echo "Screenshots: $out"
exit ${status:-0}
