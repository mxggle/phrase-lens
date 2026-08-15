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
for logo in AppLogo.png AppLogo-tight.png; do
    if [[ -f "${PROJECT_DIR}/packaging/${logo}" ]]; then
        cp "${PROJECT_DIR}/packaging/${logo}" "${APP_PATH}/Contents/Resources/${logo}"
    fi
done

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

# Notarization (optional, opt-in).
#
# A signed but un-notarized build is still refused by Gatekeeper the first time
# it is opened from a download ("Apple cannot check it for malicious software"),
# so a release build should be notarized and stapled. Credentials come from the
# environment, in the same style as CODE_SIGN_IDENTITY above:
#
#   NOTARY_PROFILE    Name of a keychain profile stored once with
#                     `xcrun notarytool store-credentials <name>`. Preferred.
#   -- or all three of --
#   NOTARY_APPLE_ID   Apple ID of the Developer Program account.
#   NOTARY_TEAM_ID    The 10-character Developer Team ID.
#   NOTARY_PASSWORD   An app-specific password for that Apple ID, created at
#                     appleid.apple.com > Sign-In and Security.
#
# With none of them set the step is skipped with a warning and every artifact is
# still produced, so a local packaging run needs no Apple credentials at all.
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-}"
NOTARY_ARGS=()
if [[ -n "${NOTARY_PROFILE}" ]]; then
    NOTARY_ARGS=(--keychain-profile "${NOTARY_PROFILE}")
elif [[ -n "${NOTARY_APPLE_ID}" && -n "${NOTARY_TEAM_ID}" && -n "${NOTARY_PASSWORD}" ]]; then
    NOTARY_ARGS=(--apple-id "${NOTARY_APPLE_ID}" --team-id "${NOTARY_TEAM_ID}" --password "${NOTARY_PASSWORD}")
elif [[ -n "${NOTARY_APPLE_ID}${NOTARY_TEAM_ID}${NOTARY_PASSWORD}" ]]; then
    print -u2 "Incomplete notarization credentials. Set NOTARY_APPLE_ID, NOTARY_TEAM_ID and NOTARY_PASSWORD together, or use NOTARY_PROFILE."
    exit 1
fi

NOTARIZED=0
if (( ${#NOTARY_ARGS} == 0 )); then
    print -u2 "WARNING: no notarization credentials found (NOTARY_PROFILE, or NOTARY_APPLE_ID + NOTARY_TEAM_ID + NOTARY_PASSWORD)."
    print -u2 "WARNING: skipping notarization. The artifacts are signed, but Gatekeeper will block them on first launch after a download."
elif ! xcrun --find notarytool >/dev/null 2>&1; then
    print -u2 "WARNING: xcrun notarytool is unavailable; full Xcode command line tools are required. Skipping notarization."
else
    print "Submitting ${ZIP_PATH:t} to the Apple notary service. This usually takes a few minutes."
    if ! xcrun notarytool submit "${ZIP_PATH}" "${NOTARY_ARGS[@]}" --wait; then
        print -u2 "Notarization of ${ZIP_PATH:t} failed. Run 'xcrun notarytool log <submission-id>' for the details."
        exit 1
    fi
    # notarytool's exit status has been unreliable across releases, so the
    # staple is the real check: it only succeeds once Apple has a ticket for
    # this exact bundle. Validate it afterwards, and assess the result the way
    # Gatekeeper will.
    if ! xcrun stapler staple "${APP_PATH}"; then
        print -u2 "Could not staple the notarization ticket to ${APP_PATH:t}."
        exit 1
    fi
    if ! xcrun stapler validate "${APP_PATH}"; then
        print -u2 "Stapled ticket failed validation for ${APP_PATH:t}."
        exit 1
    fi
    if ! spctl --assess --type execute --verbose=4 "${APP_PATH}"; then
        print -u2 "Gatekeeper still rejects ${APP_PATH:t} after notarization."
        exit 1
    fi
    # The archive above predates the staple, so rebuild it around the stapled
    # bundle; otherwise the downloaded copy has no ticket to read offline.
    rm -f "${ZIP_PATH}"
    ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"
    NOTARIZED=1
fi

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
