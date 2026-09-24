#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/toolchain-env.sh"
cd "${SCRIPT_DIR:h}"

swift build --disable-sandbox -Xswiftc -warnings-as-errors
.build/debug/PhraseLens --self-test
.build/debug/PhraseLens --dictionary-self-test
python3 -m unittest discover -s scripts/dictionary -p 'test_*.py'
