#!/bin/bash
# release.sh — Run the full release pipeline.
#
# Replaces the multi-step local sequence (build → upload → push_homebrew →
# build_appstore → verify_appstore → upload_appstore). Used both locally and
# inside the catapult CD workflow so the two paths stay identical.
#
# Usage:   release.sh [version] [--channels s3,homebrew,appstore,play] [--no-testflight]
# Version: defaults to latest git tag, or 0.0.0.
# Channels: defaults to "s3,homebrew" on macOS (App Store opt-in), "appstore"
# on iOS, and "play" on Android. An app that lists several build.platforms
# releases each of them under the same version, e.g. "appstore,play" for a
# Tauri app on iOS and Android. A Compose desktop app also defaults to
# "s3,homebrew", builds for the host it runs on, and skips homebrew off a Mac.
#
# --no-testflight uploads the iOS build but stops short of distributing it, for
# when you want the build parked in App Store Connect rather than in front of
# testers. Only meaningful with a [testflight] section in catapult.toml.
#
# Assumes signing certificates and the provisioning profile (if shipping to
# App Store) are already importable from the user's Keychain. The catapult
# CD workflow handles certificate import as a prelude step.

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSION=""
CHANNELS=""
TESTFLIGHT=1

while [ $# -gt 0 ]; do
    case "$1" in
        --channels) CHANNELS="$2"; shift 2 ;;
        --channels=*) CHANNELS="${1#*=}"; shift ;;
        --no-testflight) TESTFLIGHT=0; shift ;;
        *) VERSION="$1"; shift ;;
    esac
done

# Load config to learn the platforms, which drive the default channels and the
# per-platform routing below.
source "${SCRIPT_DIR}/config.sh"

if [ -z "$VERSION" ]; then
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)"
fi

# Default channels depend on platform: iOS only ships to App Store Connect and
# Android only to Google Play. An app on several platforms gets each one's.
if [ -z "$CHANNELS" ]; then
    for platform in $CATAPULT_BUILD_PLATFORMS; do
        case "$platform" in
            ios) CHANNELS="${CHANNELS:+${CHANNELS},}appstore" ;;
            android) CHANNELS="${CHANNELS:+${CHANNELS},}play" ;;
            *) CHANNELS="${CHANNELS:+${CHANNELS},}s3,homebrew" ;;
        esac
    done
fi

has_channel() { [[ ",$CHANNELS," == *",$1,"* ]]; }

# iOS: Xcode-driven archive + upload to App Store Connect. No DMG/Homebrew.
release_ios() {
    if ! has_channel appstore; then
        echo "ℹ️  iOS ships only via App Store Connect; nothing to do for: ${CHANNELS}"
        return
    fi
    "${SCRIPT_DIR}/build_ios.sh" "$VERSION"
    "${SCRIPT_DIR}/upload_ios.sh" "$VERSION"
    # Uploading only parks the build. Distributing it needs What to Test,
    # the beta groups, and (for external groups) Beta App Review.
    if [ "$TESTFLIGHT" = "1" ]; then
        "${SCRIPT_DIR}/testflight_ios.sh" "$VERSION"
    else
        echo "ℹ️  --no-testflight: build uploaded but not distributed."
    fi
}

# Android: Gradle bundle published to a Google Play track.
release_android() {
    if ! has_channel play; then
        echo "ℹ️  Android ships only via Google Play; nothing to do for: ${CHANNELS}"
        return
    fi
    "${SCRIPT_DIR}/build_android.sh" "$VERSION"
    "${SCRIPT_DIR}/upload_play.sh" "$VERSION"
}

release_macos() {
    if has_channel s3; then
        "${SCRIPT_DIR}/build.sh" "$VERSION"
        "${SCRIPT_DIR}/upload.sh" "$VERSION"
    fi

    if has_channel homebrew; then
        "${SCRIPT_DIR}/push_homebrew.sh" --pull-request "$VERSION"
    fi

    if has_channel appstore; then
        "${SCRIPT_DIR}/build_appstore.sh" "$VERSION"
        "${SCRIPT_DIR}/verify_appstore.sh"
        "${SCRIPT_DIR}/upload_appstore.sh" "$VERSION"
    fi
}

# Desktop (Compose): each host builds and uploads its own artifacts, and only a Mac has the DMG Homebrew wants.
release_desktop() {
    if has_channel s3; then
        "${SCRIPT_DIR}/build.sh" "$VERSION"
        "${SCRIPT_DIR}/upload.sh" "$VERSION"
    fi

    if has_channel homebrew; then
        if [ "$CATAPULT_HOST_OS" = "macos" ]; then
            "${SCRIPT_DIR}/push_homebrew.sh" --pull-request "$VERSION"
        else
            echo "ℹ️  Homebrew ships the macOS DMG; skipping it on ${CATAPULT_HOST_OS}."
        fi
    fi

    if has_channel appstore; then
        echo "ℹ️  Compose desktop apps do not ship to the App Store; ignoring appstore."
    fi
}

echo "🚀 Releasing v${VERSION} (${CATAPULT_BUILD_PLATFORMS// /, }) → channels: ${CHANNELS}"
echo ""

# One version and one build number cover every platform, so they release as a pair.
for platform in $CATAPULT_BUILD_PLATFORMS; do
    export CATAPULT_PLATFORM="$platform"
    "release_${platform}"
    echo ""
done

echo "✅ Release v${VERSION} complete"
