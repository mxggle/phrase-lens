#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
source "${SCRIPT_DIR}/toolchain-env.sh"
PRODUCT_NAME="PhraseLens"
EXECUTABLE_NAME="PhraseLens"
PRODUCT_IDENTIFIER="com.harry.phraselens"
BUILD_DIR="${PROJECT_DIR}/.build"
OUTPUT_DIR="${PROJECT_DIR}/dist"
APP_PATH="${OUTPUT_DIR}/${PRODUCT_NAME}.app"
EXECUTABLE_PATH="${BUILD_DIR}/release/${EXECUTABLE_NAME}"

cd "${PROJECT_DIR}"
# The distributable favors code size; framework-heavy work still runs in the
# system frameworks, while this keeps PhraseLens's own Swift code compact.
swift build --disable-sandbox -c release -Xswiftc -Osize -Xswiftc -warnings-as-errors

EXPECTED_PATH="${PROJECT_DIR}/dist/${PRODUCT_NAME}.app"
if [[ "${APP_PATH}" != "${EXPECTED_PATH}" ]]; then
    print -u2 "Refusing to replace unexpected bundle path: ${APP_PATH}"
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"
rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources"
cp "${EXECUTABLE_PATH}" "${APP_PATH}/Contents/MacOS/${EXECUTABLE_NAME}"
# Keep SwiftPM's release binary unstripped for local crash symbolication, but
# remove local symbols from the distributable copy before it is signed.
/usr/bin/strip -x "${APP_PATH}/Contents/MacOS/${EXECUTABLE_NAME}"
cp "${PROJECT_DIR}/packaging/Info.plist" "${APP_PATH}/Contents/Info.plist"
PLIST_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_PATH}/Contents/Info.plist")"
if [[ "${PLIST_IDENTIFIER}" != "${PRODUCT_IDENTIFIER}" ]]; then
    print -u2 "Unexpected bundle identifier: ${PLIST_IDENTIFIER}"
    exit 1
fi
if [[ -f "${PROJECT_DIR}/packaging/AppIcon.icns" ]]; then
    cp "${PROJECT_DIR}/packaging/AppIcon.icns" "${APP_PATH}/Contents/Resources/AppIcon.icns"
fi

SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "${SIGNING_IDENTITY}" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/valid identities found/ { next } /\) [A-F0-9]{40} / { print $2; exit }')"
fi
if [[ -z "${SIGNING_IDENTITY}" ]]; then
    print -u2 "No stable code-signing identity is available. Refusing an ad-hoc build."
    exit 1
fi

codesign --force --options runtime --sign "${SIGNING_IDENTITY}" "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
SIGNED_IDENTIFIER="$(codesign --display --verbose=4 "${APP_PATH}" 2>&1 | sed -n 's/^Identifier=//p')"
if [[ "${SIGNED_IDENTIFIER}" != "${PRODUCT_IDENTIFIER}" ]]; then
    print -u2 "Unexpected signed identifier: ${SIGNED_IDENTIFIER}"
    exit 1
fi

ZIP_PATH="${OUTPUT_DIR}/${PRODUCT_NAME}.zip"
rm -f "${ZIP_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

DMG_ROOT="${BUILD_DIR}/dmg-root"
DMG_PATH="${OUTPUT_DIR}/${PRODUCT_NAME}.dmg"
rm -rf "${DMG_ROOT}" "${DMG_PATH}"
mkdir -p "${DMG_ROOT}"
cp -R "${APP_PATH}" "${DMG_ROOT}/"
ln -s /Applications "${DMG_ROOT}/Applications"
hdiutil create -volname "${PRODUCT_NAME}" -srcfolder "${DMG_ROOT}" -ov -format UDZO "${DMG_PATH}" >/dev/null
rm -rf "${DMG_ROOT}"

print "App: ${APP_PATH}"
print "ZIP: ${ZIP_PATH}"
print "DMG: ${DMG_PATH}"
