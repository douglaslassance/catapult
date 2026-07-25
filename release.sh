#!/bin/bash
# release.sh — Run the full release pipeline.
#
# Replaces the multi-step local sequence (build → upload → push_homebrew →
# build_appstore → verify_appstore → upload_appstore). Used both locally and
# inside the catapult CD workflow so the two paths stay identical.
#
# Usage:   release.sh [version] [--channels s3,homebrew,appstore]
# Version: defaults to latest git tag, or 0.0.0.
# Channels: defaults to "s3,homebrew" (App Store opt-in).
#
# Assumes signing certificates and the provisioning profile (if shipping to
# App Store) are already importable from the user's Keychain. The catapult
# CD workflow handles certificate import as a prelude step.

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSION=""
CHANNELS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --channels) CHANNELS="$2"; shift 2 ;;
        --channels=*) CHANNELS="${1#*=}"; shift ;;
        *) VERSION="$1"; shift ;;
    esac
done

# Load config to learn the platform, which drives the default channels and the
# iOS-vs-macOS routing below.
source "${SCRIPT_DIR}/config.sh"

if [ -z "$VERSION" ]; then
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)"
fi

# Default channels depend on platform: iOS only ships to App Store Connect.
if [ -z "$CHANNELS" ]; then
    if [ "$CATAPULT_BUILD_PLATFORM" = "ios" ]; then
        CHANNELS="appstore"
    else
        CHANNELS="s3,homebrew"
    fi
fi

has_channel() { [[ ",$CHANNELS," == *",$1,"* ]]; }

echo "🚀 Releasing v${VERSION} → channels: ${CHANNELS}"
echo ""

# iOS: Xcode-driven archive + upload to App Store Connect. No DMG/Homebrew.
if [ "$CATAPULT_BUILD_PLATFORM" = "ios" ]; then
    if has_channel s3 || has_channel homebrew; then
        echo "ℹ️  iOS apps ship only via App Store Connect; ignoring s3/homebrew."
    fi
    if has_channel appstore; then
        "${SCRIPT_DIR}/build_ios.sh" "$VERSION"
        "${SCRIPT_DIR}/upload_ios.sh" "$VERSION"
    fi
    echo ""
    echo "✅ Release v${VERSION} complete"
    exit 0
fi

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

echo ""
echo "✅ Release v${VERSION} complete"
