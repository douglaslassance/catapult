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

# Optional .env for local secrets
[ -f "${CATAPULT_APP_ROOT}/.env" ] && source "${CATAPULT_APP_ROOT}/.env"

if [ ! -f "$CATAPULT_CONFIG" ]; then
    echo "❌ catapult: $CATAPULT_CONFIG not found" >&2
    exit 1
fi

# Load TOML into env
eval "$(python3 "${CATAPULT_DIR}/parse_config.py" "$CATAPULT_CONFIG")"

# Required for any kind
: "${CATAPULT_APP_NAME:?app.name required in catapult.toml}"
: "${CATAPULT_APP_SLUG:?app.slug required in catapult.toml}"
: "${CATAPULT_APP_BUNDLE_ID:?app.bundle_id required in catapult.toml}"
: "${CATAPULT_APP_TEAM_ID:?app.team_id required in catapult.toml}"
: "${CATAPULT_APP_DEVELOPER:?app.developer required in catapult.toml}"
: "${CATAPULT_APP_MIN_MACOS:?app.min_macos required in catapult.toml}"
: "${CATAPULT_BUILD_ARCH:?build.arch required in catapult.toml}"
: "${CATAPULT_BUILD_TARGET_TRIPLE:?build.target_triple required in catapult.toml}"

# Build kind: "swift" (default) or "tauri"
CATAPULT_BUILD_KIND="${CATAPULT_BUILD_KIND:-swift}"
case "$CATAPULT_BUILD_KIND" in
    swift|tauri) ;;
    *) echo "❌ catapult: build.kind must be 'swift' or 'tauri' (got '$CATAPULT_BUILD_KIND')" >&2; exit 1 ;;
esac

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
export CATAPULT_BUILD_ICON CATAPULT_BUILD_ASSETS
export CATAPULT_BUILD_ICON_COMMAND
export CATAPULT_BUILD_ENTITLEMENTS_DIRECT CATAPULT_BUILD_ENTITLEMENTS_APPSTORE
export CATAPULT_BUILD_PACKAGE_MANAGER CATAPULT_BUILD_TAURI_DIR CATAPULT_BUILD_FRONTEND_BUILD
