#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/toolchain-env.sh"
cd "${SCRIPT_DIR:h}"

swift build --disable-sandbox -Xswiftc -warnings-as-errors
BIN_PATH="$(swift build --show-bin-path)"
# Newer SwiftPM (swiftbuild) no longer adds the bin dir to the rpath, so point
# dyld at it to find Sparkle.framework when running the debug binary directly.
DYLD_FRAMEWORK_PATH="${BIN_PATH}" "${BIN_PATH}/PhraseLens" --self-test
python3 -m unittest discover -s scripts -p 'test_release.py'
