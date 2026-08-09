#!/bin/zsh

PROJECT_DIR="${0:A:h:h}"

# Select the SDK that matches this Mac's Swift toolchain. Building with the
# macOS 26 SDK enables the Liquid Glass design system (gated at runtime for
# macOS 14/15 via #available). Older SDKs still compile, without the new APIs.
PREFERRED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
FALLBACK_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"

if [[ -z "${SDKROOT:-}" ]]; then
    if [[ -d "${PREFERRED_SDK}" ]]; then
        export SDKROOT="${PREFERRED_SDK}"
    elif [[ -d "${FALLBACK_SDK}" ]]; then
        export SDKROOT="${FALLBACK_SDK}"
    fi
fi
export CLANG_MODULE_CACHE_PATH="${PROJECT_DIR}/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${PROJECT_DIR}/.build/module-cache"
mkdir -p "${CLANG_MODULE_CACHE_PATH}"
