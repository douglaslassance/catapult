#!/bin/bash
# Loads catapult.toml from the current working directory into CATAPULT_* env vars.
# Source this from any sibling script as:
#   source "$(dirname "$0")/config.sh"
#
# Derived identity strings (signing identities, derived bundle IDs, etc.)
# are computed here, after the python loader has run.

set -e

CATAPULT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# App repo root = current working directory. All paths in catapult.toml are
# resolved relative to it.
CATAPULT_APP_ROOT="${CATAPULT_APP_ROOT:-$(pwd)}"
CATAPULT_CONFIG="${CATAPULT_CONFIG:-${CATAPULT_APP_ROOT}/catapult.toml}"

# Optional .env for local secrets. `set -a` auto-exports every assignment so
# subprocesses (notably python helpers like render_plist.py) see the values.
if [ -f "${CATAPULT_APP_ROOT}/.env" ]; then
    set -a
    source "${CATAPULT_APP_ROOT}/.env"
    set +a
fi

if [ ! -f "$CATAPULT_CONFIG" ]; then
    echo "❌ catapult: $CATAPULT_CONFIG not found" >&2
    exit 1
fi

# The OS this runs on. Compose desktop builds can only produce artifacts for it.
case "$(uname -s)" in
    Darwin) CATAPULT_HOST_OS=macos ;;
    Linux) CATAPULT_HOST_OS=linux ;;
    MINGW*|MSYS*|CYGWIN*) CATAPULT_HOST_OS=windows ;;
    *) CATAPULT_HOST_OS=unknown ;;
esac
export CATAPULT_HOST_OS

# Windows runners may only have `python`, so every script uses the interpreter resolved here.
if [ -z "${CATAPULT_PYTHON:-}" ]; then
    if python3 --version >/dev/null 2>&1; then
        CATAPULT_PYTHON=python3
    else
        CATAPULT_PYTHON=python
    fi
fi
export CATAPULT_PYTHON

# Load TOML into env
eval "$("$CATAPULT_PYTHON" "${CATAPULT_DIR}/parse_config.py" "$CATAPULT_CONFIG")"

# Required for any kind/platform. On Android, bundle_id is the applicationId.
: "${CATAPULT_APP_NAME:?app.name required in catapult.toml}"
: "${CATAPULT_APP_SLUG:?app.slug required in catapult.toml}"
: "${CATAPULT_APP_BUNDLE_ID:?app.bundle_id required in catapult.toml}"

# Build kind: "swift" (default), "tauri", "xcodeproj", "gradle", or "compose"
CATAPULT_BUILD_KIND="${CATAPULT_BUILD_KIND:-swift}"
case "$CATAPULT_BUILD_KIND" in
    swift|tauri|xcodeproj|gradle|compose) ;;
    *) echo "❌ catapult: build.kind must be 'swift', 'tauri', 'xcodeproj', 'gradle', or 'compose' (got '$CATAPULT_BUILD_KIND')" >&2; exit 1 ;;
esac

# Compose apps build on macOS, Windows and Linux alike, so their platform is "desktop".
if [ "$CATAPULT_BUILD_KIND" = "compose" ] && [ -z "${CATAPULT_BUILD_PLATFORMS:-}" ]; then
    CATAPULT_BUILD_PLATFORM="${CATAPULT_BUILD_PLATFORM:-desktop}"
fi

# Platforms: "macos" (default), "ios", or "android". `platform` names one;
# `platforms` lists several that release together under one version, such as a
# Tauri mobile app on iOS and Android. A script that serves one platform sets
# CATAPULT_PLATFORM before sourcing this file, which selects it from the list.
CATAPULT_BUILD_PLATFORMS="${CATAPULT_BUILD_PLATFORMS:-${CATAPULT_BUILD_PLATFORM:-macos}}"
for p in $CATAPULT_BUILD_PLATFORMS; do
    case "$p" in
        macos|ios|android|desktop) ;;
        *) echo "❌ catapult: build.platform must be 'macos', 'ios', 'android', or 'desktop' (got '$p')" >&2; exit 1 ;;
    esac
done
if [ -n "${CATAPULT_PLATFORM:-}" ]; then
    case " $CATAPULT_BUILD_PLATFORMS " in
        *" $CATAPULT_PLATFORM "*) CATAPULT_BUILD_PLATFORM="$CATAPULT_PLATFORM" ;;
        *) echo "❌ catapult: this app does not ship on '$CATAPULT_PLATFORM' (build.platforms: $CATAPULT_BUILD_PLATFORMS)" >&2; exit 1 ;;
    esac
else
    CATAPULT_BUILD_PLATFORM="${CATAPULT_BUILD_PLATFORMS%% *}"
fi

# iOS builds go through Xcode, either a project of the app's own or the one
# Tauri generates, and ship only via the appstore channel. Android builds go
# through Gradle, the same way, and ship only via the play channel.
if [ "$CATAPULT_BUILD_PLATFORM" = "ios" ] && [ "$CATAPULT_BUILD_KIND" != "xcodeproj" ] && [ "$CATAPULT_BUILD_KIND" != "tauri" ]; then
    echo "❌ catapult: build.platform = 'ios' requires build.kind = 'xcodeproj' or 'tauri'" >&2; exit 1
fi
if [ "$CATAPULT_BUILD_PLATFORM" = "android" ] && [ "$CATAPULT_BUILD_KIND" != "gradle" ] && [ "$CATAPULT_BUILD_KIND" != "tauri" ]; then
    echo "❌ catapult: build.platform = 'android' requires build.kind = 'gradle' or 'tauri'" >&2; exit 1
fi
if [ "$CATAPULT_BUILD_KIND" = "gradle" ] && [ "$CATAPULT_BUILD_PLATFORM" != "android" ]; then
    echo "❌ catapult: build.kind = 'gradle' requires build.platform = 'android'" >&2; exit 1
fi
if [ "$CATAPULT_BUILD_PLATFORM" = "desktop" ] && [ "$CATAPULT_BUILD_KIND" != "compose" ]; then
    echo "❌ catapult: build.platform = 'desktop' requires build.kind = 'compose'" >&2; exit 1
fi
if [ "$CATAPULT_BUILD_KIND" = "compose" ] && [ "$CATAPULT_BUILD_PLATFORM" != "desktop" ]; then
    echo "❌ catapult: build.kind = 'compose' requires build.platform = 'desktop'" >&2; exit 1
fi

# Apple signing identities are derived from these, so only Apple targets need them (a desktop build is one on a Mac).
if [ "$CATAPULT_BUILD_PLATFORM" != "android" ] && { [ "$CATAPULT_BUILD_PLATFORM" != "desktop" ] || [ "$CATAPULT_HOST_OS" = "macos" ]; }; then
    : "${CATAPULT_APP_TEAM_ID:?app.team_id required in catapult.toml}"
    : "${CATAPULT_APP_DEVELOPER:?app.developer required in catapult.toml}"
fi

# macOS SPM/Tauri required fields. The Xcode project supplies these itself for
# xcodeproj builds and Tauri mobile builds, so they're only required for the
# hand-assembled macOS kinds.
if [ "$CATAPULT_BUILD_PLATFORM" = "macos" ] && { [ "$CATAPULT_BUILD_KIND" = "swift" ] || [ "$CATAPULT_BUILD_KIND" = "tauri" ]; }; then
    : "${CATAPULT_APP_MIN_MACOS:?app.min_macos required in catapult.toml}"
    : "${CATAPULT_BUILD_ARCH:?build.arch required in catapult.toml}"
    : "${CATAPULT_BUILD_TARGET_TRIPLE:?build.target_triple required in catapult.toml}"
fi

# Swift-only required fields
if [ "$CATAPULT_BUILD_KIND" = "swift" ]; then
    : "${CATAPULT_BUILD_SWIFT_TARGET:?build.swift_target required for swift builds}"
fi

# Tauri-only fields
if [ "$CATAPULT_BUILD_KIND" = "tauri" ]; then
    CATAPULT_BUILD_PACKAGE_MANAGER="${CATAPULT_BUILD_PACKAGE_MANAGER:-npm}"
    CATAPULT_BUILD_TAURI_DIR="${CATAPULT_BUILD_TAURI_DIR:-src-tauri}"
    CATAPULT_BUILD_FRONTEND_BUILD="${CATAPULT_BUILD_FRONTEND_BUILD:-${CATAPULT_BUILD_PACKAGE_MANAGER} run build}"
    case "$CATAPULT_BUILD_PACKAGE_MANAGER" in
        npm|pnpm|bun|yarn) ;;
        *) echo "❌ catapult: build.package_manager must be npm/pnpm/bun/yarn" >&2; exit 1 ;;
    esac
    # The Gradle project `tauri android init` generates writes a universal bundle here.
    if [ "$CATAPULT_BUILD_PLATFORM" = "android" ]; then
        CATAPULT_BUILD_BUNDLE="${CATAPULT_BUILD_BUNDLE:-${CATAPULT_BUILD_TAURI_DIR}/gen/android/app/build/outputs/bundle/universalRelease/app-universal-release.aab}"
        export CATAPULT_BUILD_BUNDLE
    fi
fi

# xcodeproj fields (iOS today). Drives `xcodebuild archive` / `-exportArchive`.
if [ "$CATAPULT_BUILD_KIND" = "xcodeproj" ]; then
    : "${CATAPULT_BUILD_SCHEME:?build.scheme required for xcodeproj builds}"
    if [ -z "${CATAPULT_BUILD_PROJECT:-}" ] && [ -z "${CATAPULT_BUILD_WORKSPACE:-}" ]; then
        echo "❌ catapult: build.project or build.workspace required for xcodeproj builds" >&2; exit 1
    fi
    CATAPULT_BUILD_CONFIGURATION="${CATAPULT_BUILD_CONFIGURATION:-Release}"
fi

# gradle fields (Android). Drives `./gradlew :<module>:<task>`; the app's own
# Gradle config owns signing, so a release build must come out signed.
if [ "$CATAPULT_BUILD_KIND" = "gradle" ]; then
    CATAPULT_BUILD_MODULE="${CATAPULT_BUILD_MODULE:-app}"
    CATAPULT_BUILD_TASK="${CATAPULT_BUILD_TASK:-bundleRelease}"
    CATAPULT_BUILD_BUNDLE="${CATAPULT_BUILD_BUNDLE:-${CATAPULT_BUILD_MODULE}/build/outputs/bundle/release/${CATAPULT_BUILD_MODULE}-release.aab}"
    export CATAPULT_BUILD_MODULE CATAPULT_BUILD_TASK CATAPULT_BUILD_BUNDLE
fi

# compose fields (desktop). jpackage cannot cross-build, so the target triple names the host unless set.
if [ "$CATAPULT_BUILD_KIND" = "compose" ]; then
    if [ "$CATAPULT_HOST_OS" = "macos" ]; then
        : "${CATAPULT_APP_MIN_MACOS:?app.min_macos required in catapult.toml}"
    fi
    if [ -z "${CATAPULT_BUILD_TARGET_TRIPLE:-}" ]; then
        case "${CATAPULT_HOST_OS}/$(uname -m)" in
            macos/arm64) CATAPULT_BUILD_TARGET_TRIPLE="aarch64-apple-darwin" ;;
            macos/x86_64) CATAPULT_BUILD_TARGET_TRIPLE="x86_64-apple-darwin" ;;
            linux/x86_64) CATAPULT_BUILD_TARGET_TRIPLE="x86_64-unknown-linux-gnu" ;;
            linux/aarch64) CATAPULT_BUILD_TARGET_TRIPLE="aarch64-unknown-linux-gnu" ;;
            windows/x86_64) CATAPULT_BUILD_TARGET_TRIPLE="x86_64-pc-windows-msvc" ;;
            *) echo "❌ catapult: cannot derive build.target_triple on $(uname -s) $(uname -m); set it in catapult.toml" >&2; exit 1 ;;
        esac
    fi
    CATAPULT_BUILD_GRADLE_MODULE="${CATAPULT_BUILD_GRADLE_MODULE:-composeApp}"
    CATAPULT_BUILD_LINUX_ICON="${CATAPULT_BUILD_LINUX_ICON:-${CATAPULT_BUILD_GRADLE_MODULE}/icons/icon.png}"
    export CATAPULT_BUILD_TARGET_TRIPLE CATAPULT_BUILD_GRADLE_MODULE CATAPULT_BUILD_LINUX_ICON CATAPULT_BUILD_ICON_ASSETS
fi

# Defaults
CATAPULT_BUILD_ICON="${CATAPULT_BUILD_ICON:-Sources/App/Resources/AppIcon.png}"
CATAPULT_BUILD_ASSETS="${CATAPULT_BUILD_ASSETS:-Sources/App/Resources/Assets.xcassets}"
CATAPULT_BUILD_ENTITLEMENTS_DIRECT="${CATAPULT_BUILD_ENTITLEMENTS_DIRECT:-${CATAPULT_APP_NAME}.entitlements}"
CATAPULT_BUILD_ENTITLEMENTS_APPSTORE="${CATAPULT_BUILD_ENTITLEMENTS_APPSTORE:-${CATAPULT_APP_NAME}-appstore.entitlements}"
CATAPULT_BUILD_PROVISIONING_PROFILE="${CATAPULT_BUILD_PROVISIONING_PROFILE:-${CATAPULT_APP_NAME}.provisionprofile}"
# Executable name inside the .app — defaults to app.name. Override when the
# compiled binary name differs (e.g. trotter has APP_NAME=Trotter but the
# binary in .build/release is "trotter").
CATAPULT_BUILD_EXECUTABLE="${CATAPULT_BUILD_EXECUTABLE:-${CATAPULT_APP_NAME}}"

# Derived identities
export CATAPULT_APP_SIGNING_IDENTITY_APPSTORE="Apple Distribution: ${CATAPULT_APP_DEVELOPER} (${CATAPULT_APP_TEAM_ID})"
export CATAPULT_APP_SIGNING_IDENTITY_INSTALLER="3rd Party Mac Developer Installer: ${CATAPULT_APP_DEVELOPER} (${CATAPULT_APP_TEAM_ID})"
export CATAPULT_APP_BUNDLE_ID_RESOURCES="${CATAPULT_APP_BUNDLE_ID}.resources"

if [ "$CATAPULT_BUILD_KIND" = "swift" ]; then
    export CATAPULT_APP_RESOURCE_BUNDLE_NAME="${CATAPULT_APP_NAME}_${CATAPULT_BUILD_SWIFT_TARGET}.bundle"
fi

# Paths
export CATAPULT_DIST_DIR="${CATAPULT_APP_ROOT}/dist"
export CATAPULT_BUILD_DIR="${CATAPULT_APP_ROOT}/build"
export CATAPULT_BUILD_DIR_APPSTORE="${CATAPULT_APP_ROOT}/build-appstore"

# Provisioning profile full path
case "$CATAPULT_BUILD_PROVISIONING_PROFILE" in
    /*) ;;
    ~*) CATAPULT_BUILD_PROVISIONING_PROFILE="${CATAPULT_BUILD_PROVISIONING_PROFILE/#\~/$HOME}" ;;
    *)  CATAPULT_BUILD_PROVISIONING_PROFILE="${HOME}/Library/MobileDevice/Provisioning Profiles/${CATAPULT_BUILD_PROVISIONING_PROFILE}" ;;
esac
export CATAPULT_BUILD_PROVISIONING_PROFILE

export CATAPULT_BUILD_KIND CATAPULT_BUILD_EXECUTABLE
export CATAPULT_BUILD_PLATFORM CATAPULT_BUILD_PLATFORMS CATAPULT_BUILD_CONFIGURATION
export CATAPULT_BUILD_ICON CATAPULT_BUILD_ASSETS
export CATAPULT_BUILD_ICON_COMMAND
export CATAPULT_BUILD_ENTITLEMENTS_DIRECT CATAPULT_BUILD_ENTITLEMENTS_APPSTORE
export CATAPULT_BUILD_PACKAGE_MANAGER CATAPULT_BUILD_TAURI_DIR CATAPULT_BUILD_FRONTEND_BUILD

# Runs the app's Tauri CLI through its package manager.
catapult_tauri() {
    case "$CATAPULT_BUILD_PACKAGE_MANAGER" in
        bun)  bun run tauri "$@" ;;
        pnpm) pnpm tauri "$@" ;;
        yarn) yarn tauri "$@" ;;
        npm)  npm run tauri -- "$@" ;;
    esac
}

catapult_install_dependencies() {
    case "$CATAPULT_BUILD_PACKAGE_MANAGER" in
        bun)  bun install ;;
        pnpm) pnpm install ;;
        yarn) yarn install ;;
        npm)  npm install ;;
    esac
}

# Writes <file>.sha256, with sha256sum where shasum is missing (Git Bash).
catapult_checksum() {
    local file="$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" > "${file}.sha256"
    else
        sha256sum "$file" > "${file}.sha256"
    fi
    cat "${file}.sha256"
}

# signtool ships with the Windows SDK, which rarely puts it on PATH, so the newest x64 build is used.
catapult_find_signtool() {
    if command -v signtool >/dev/null 2>&1; then
        command -v signtool
    else
        ls "/c/Program Files (x86)/Windows Kits/10/bin/"*/x64/signtool.exe 2>/dev/null | sort -V | tail -1
    fi
}

# Authenticode signs an MSI with WINDOWS_CERTIFICATE (a base64 .pfx) and its password.
catapult_sign_msi() {
    local msi="$1" signtool pfx_dir pfx
    echo "🔏 Signing MSI with Authenticode..."
    signtool="$(catapult_find_signtool)"
    if [ -z "$signtool" ]; then
        echo "❌ signtool not found. Install the Windows SDK or put signtool on PATH."
        exit 1
    fi
    pfx_dir="$(mktemp -d)"
    pfx="${pfx_dir}/certificate.pfx"
    echo "$WINDOWS_CERTIFICATE" | base64 --decode > "$pfx"
    # Git Bash would rewrite signtool's /flags as paths, so conversion is off and the paths are converted by hand.
    if ! MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$signtool" sign /fd sha256 \
        /f "$(cygpath -w "$pfx")" /p "$WINDOWS_CERTIFICATE_PASSWORD" \
        /tr http://timestamp.digicert.com /td sha256 \
        "$(cygpath -w "$msi")"; then
        rm -rf "$pfx_dir"
        echo "❌ signtool could not sign ${msi}"
        exit 1
    fi
    rm -rf "$pfx_dir"
    echo "✅ Signed"
    echo ""
}

# Sparkle's `sign_update` prints a whole attribute pair rather than the
# signature on its own:
#
#     sparkle:edSignature="…" length="…"
#
# Only the signature belongs inside the appcast's attribute. Pasting the line
# whole is what published a feed whose enclosure carried a nested
# `sparkle:edSignature=` and a second `length`, which no Sparkle client can
# verify and no XML parser should accept. Takes either shape and returns the
# signature.
catapult_ed_signature() {
    local raw="$1"
    if [[ "$raw" == *edSignature=* ]]; then
        printf '%s' "$raw" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p'
    else
        printf '%s' "$raw"
    fi
}

