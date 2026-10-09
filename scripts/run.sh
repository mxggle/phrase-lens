#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_PATH="${PROJECT_DIR}/dist/PhraseLens.app"
EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/PhraseLens"
INSTALLED_EXECUTABLE="/Applications/PhraseLens.app/Contents/MacOS/PhraseLens"

if [[ "${1:-}" == "--watch" && $# == 1 ]]; then
    exec python3 "${SCRIPT_DIR}/watch-app.py"
fi
if (( $# != 0 )); then
    print -u2 "Usage: ${0:t} [--watch]"
    exit 2
fi

# Compile before stopping the running app. A source error leaves it usable.
source "${SCRIPT_DIR}/toolchain-env.sh"
cd "${PROJECT_DIR}"
swift build --disable-sandbox -Xswiftc -warnings-as-errors

# Accessibility consent is tied to the application's signed code identity.
# Running SwiftPM's raw executable creates a separate, disposable identity that
# cannot use the consent granted to the app bundle.
stopped_pids=()
for pid in ${(f)"$(pgrep -f '/PhraseLens.app/Contents/MacOS/PhraseLens' || true)"}; do
    [[ -n "${pid}" ]] || continue
    running_path="$(lsof -a -p "${pid}" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
    if [[ "${running_path}" == "${EXECUTABLE_PATH}" || "${running_path}" == "${INSTALLED_EXECUTABLE}" ]]; then
        kill -TERM "${pid}"
        stopped_pids+=("${pid}")
    fi
done
for pid in "${stopped_pids[@]}"; do
    for attempt in {1..50}; do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "${pid}" 2>/dev/null; then
        print -u2 "PhraseLens process ${pid} did not exit; refusing to replace the app bundle."
        exit 1
    fi
done

"${SCRIPT_DIR}/package-app.sh" --local --skip-build
open "${APP_PATH}"
