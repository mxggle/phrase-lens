#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_PATH="${PROJECT_DIR}/.build/NextAI Translator Native.app"
EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/NextAITranslatorNative"

# Accessibility consent is tied to the application's signed code identity.
# Running SwiftPM's raw executable creates a separate, disposable identity that
# cannot use the consent granted to the app bundle.
for pid in ${(f)"$(pgrep -f "${EXECUTABLE_PATH}" || true)"}; do
    [[ -n "${pid}" ]] || continue
    running_path="$(lsof -a -p "${pid}" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
    if [[ "${running_path}" == "${EXECUTABLE_PATH}" ]]; then
        kill -TERM "${pid}"
    fi
done

"${SCRIPT_DIR}/package-app.sh"
open "${APP_PATH}"
