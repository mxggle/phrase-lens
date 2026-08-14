#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/toolchain-env.sh"
cd "${SCRIPT_DIR:h}"

swift build --disable-sandbox -Xswiftc -warnings-as-errors
swift run --disable-sandbox PhraseLens --self-test
