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
CHANNELS="s3,homebrew"

while [ $# -gt 0 ]; do
    case "$1" in
        --channels) CHANNELS="$2"; shift 2 ;;
        --channels=*) CHANNELS="${1#*=}"; shift ;;
        *) VERSION="$1"; shift ;;
    esac
done

if [ -z "$VERSION" ]; then
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)"
fi

has_channel() { [[ ",$CHANNELS," == *",$1,"* ]]; }

echo "🚀 Releasing v${VERSION} → channels: ${CHANNELS}"
echo ""

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
