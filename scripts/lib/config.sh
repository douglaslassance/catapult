#!/bin/bash
# Loads trigger.toml from the current working directory into TRIGGER_* env vars.
# Source this from any script in scripts/ as:
#   source "$(dirname "$0")/lib/config.sh"
#
# Derived identity strings (signing identities, derived bundle IDs, etc.)
# are computed here, after the python loader has run.

set -e

TRIGGER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIGGER_REPO_DIR="$(cd "${TRIGGER_LIB_DIR}/../.." && pwd)"
TRIGGER_SCRIPTS_DIR="${TRIGGER_REPO_DIR}/scripts"
TRIGGER_TEMPLATES_DIR="${TRIGGER_REPO_DIR}/templates"

# App repo root = current working directory. All paths in trigger.toml are
# resolved relative to it.
TRIGGER_APP_ROOT="${TRIGGER_APP_ROOT:-$(pwd)}"
TRIGGER_CONFIG="${TRIGGER_CONFIG:-${TRIGGER_APP_ROOT}/trigger.toml}"

# Optional .env (matches peel's convention)
[ -f "${TRIGGER_APP_ROOT}/.env" ] && source "${TRIGGER_APP_ROOT}/.env"

if [ ! -f "$TRIGGER_CONFIG" ]; then
    echo "❌ trigger: $TRIGGER_CONFIG not found" >&2
    exit 1
fi

# Load TOML into env
eval "$(python3 "${TRIGGER_LIB_DIR}/parse_config.py" "$TRIGGER_CONFIG")"

# Required for any kind
: "${TRIGGER_APP_NAME:?app.name required in trigger.toml}"
: "${TRIGGER_APP_SLUG:?app.slug required in trigger.toml}"
: "${TRIGGER_APP_BUNDLE_ID:?app.bundle_id required in trigger.toml}"
: "${TRIGGER_APP_TEAM_ID:?app.team_id required in trigger.toml}"
: "${TRIGGER_APP_DEVELOPER:?app.developer required in trigger.toml}"
: "${TRIGGER_APP_MIN_MACOS:?app.min_macos required in trigger.toml}"
: "${TRIGGER_BUILD_ARCH:?build.arch required in trigger.toml}"
: "${TRIGGER_BUILD_TARGET_TRIPLE:?build.target_triple required in trigger.toml}"

# Build kind: "swift" (default) or "tauri"
TRIGGER_BUILD_KIND="${TRIGGER_BUILD_KIND:-swift}"
case "$TRIGGER_BUILD_KIND" in
    swift|tauri) ;;
    *) echo "❌ trigger: build.kind must be 'swift' or 'tauri' (got '$TRIGGER_BUILD_KIND')" >&2; exit 1 ;;
esac

# Swift-only required fields
if [ "$TRIGGER_BUILD_KIND" = "swift" ]; then
    : "${TRIGGER_BUILD_SWIFT_TARGET:?build.swift_target required for swift builds}"
fi

# Tauri-only fields
if [ "$TRIGGER_BUILD_KIND" = "tauri" ]; then
    TRIGGER_BUILD_PACKAGE_MANAGER="${TRIGGER_BUILD_PACKAGE_MANAGER:-npm}"
    TRIGGER_BUILD_TAURI_DIR="${TRIGGER_BUILD_TAURI_DIR:-src-tauri}"
    TRIGGER_BUILD_FRONTEND_BUILD="${TRIGGER_BUILD_FRONTEND_BUILD:-${TRIGGER_BUILD_PACKAGE_MANAGER} run build}"
    case "$TRIGGER_BUILD_PACKAGE_MANAGER" in
        npm|pnpm|bun|yarn) ;;
        *) echo "❌ trigger: build.package_manager must be npm/pnpm/bun/yarn" >&2; exit 1 ;;
    esac
fi

# Defaults
TRIGGER_BUILD_ICON="${TRIGGER_BUILD_ICON:-Sources/App/Resources/AppIcon.png}"
TRIGGER_BUILD_ASSETS="${TRIGGER_BUILD_ASSETS:-Sources/App/Resources/Assets.xcassets}"
TRIGGER_BUILD_ENTITLEMENTS_DIRECT="${TRIGGER_BUILD_ENTITLEMENTS_DIRECT:-${TRIGGER_APP_NAME}.entitlements}"
TRIGGER_BUILD_ENTITLEMENTS_APPSTORE="${TRIGGER_BUILD_ENTITLEMENTS_APPSTORE:-${TRIGGER_APP_NAME}-appstore.entitlements}"
TRIGGER_BUILD_PROVISIONING_PROFILE="${TRIGGER_BUILD_PROVISIONING_PROFILE:-${TRIGGER_APP_NAME}.provisionprofile}"
# Executable name inside the .app — defaults to app.name. Override when the
# compiled binary name differs (e.g. trotter has APP_NAME=Trotter but the
# binary in .build/release is "trotter").
TRIGGER_BUILD_EXECUTABLE="${TRIGGER_BUILD_EXECUTABLE:-${TRIGGER_APP_NAME}}"

# Derived identities
export TRIGGER_APP_SIGNING_IDENTITY_APPSTORE="Apple Distribution: ${TRIGGER_APP_DEVELOPER} (${TRIGGER_APP_TEAM_ID})"
export TRIGGER_APP_SIGNING_IDENTITY_INSTALLER="3rd Party Mac Developer Installer: ${TRIGGER_APP_DEVELOPER} (${TRIGGER_APP_TEAM_ID})"
export TRIGGER_APP_BUNDLE_ID_RESOURCES="${TRIGGER_APP_BUNDLE_ID}.resources"

if [ "$TRIGGER_BUILD_KIND" = "swift" ]; then
    export TRIGGER_APP_RESOURCE_BUNDLE_NAME="${TRIGGER_APP_NAME}_${TRIGGER_BUILD_SWIFT_TARGET}.bundle"
fi

# Paths
export TRIGGER_DIST_DIR="${TRIGGER_APP_ROOT}/dist"
export TRIGGER_BUILD_DIR="${TRIGGER_APP_ROOT}/build"
export TRIGGER_BUILD_DIR_APPSTORE="${TRIGGER_APP_ROOT}/build-appstore"

# Provisioning profile full path
case "$TRIGGER_BUILD_PROVISIONING_PROFILE" in
    /*) ;;
    ~*) TRIGGER_BUILD_PROVISIONING_PROFILE="${TRIGGER_BUILD_PROVISIONING_PROFILE/#\~/$HOME}" ;;
    *)  TRIGGER_BUILD_PROVISIONING_PROFILE="${HOME}/Library/MobileDevice/Provisioning Profiles/${TRIGGER_BUILD_PROVISIONING_PROFILE}" ;;
esac
export TRIGGER_BUILD_PROVISIONING_PROFILE

export TRIGGER_BUILD_KIND TRIGGER_BUILD_EXECUTABLE
export TRIGGER_BUILD_ICON TRIGGER_BUILD_ASSETS
export TRIGGER_BUILD_ENTITLEMENTS_DIRECT TRIGGER_BUILD_ENTITLEMENTS_APPSTORE
export TRIGGER_BUILD_PACKAGE_MANAGER TRIGGER_BUILD_TAURI_DIR TRIGGER_BUILD_FRONTEND_BUILD
