#!/bin/zsh
# Regenerates the Xcode project and builds the app and its Action extension
# for the iOS Simulator. No Apple team or signing identity is needed.
set -euo pipefail

cd "${0:A:h:h}"

if command -v xcodegen >/dev/null; then
  xcodegen generate --quiet
elif [[ ! -d PhraseLens.xcodeproj ]]; then
  echo "xcodegen is required to create the project: brew install xcodegen" >&2
  exit 1
fi

xcodebuild \
  -project PhraseLens.xcodeproj \
  -scheme PhraseLens \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- \
  build "$@"

echo "Built: build/DerivedData/Build/Products/Debug-iphonesimulator/PhraseLens.app"
