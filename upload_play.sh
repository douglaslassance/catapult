#!/bin/bash
# upload_play.sh publishes the bundle from build_android.sh to a Google Play
# track. It is the Android counterpart to upload_ios.sh plus testflight_ios.sh:
# on the internal track, testers get the build as soon as this finishes.
#
# Requires a [play] section in catapult.toml:
#
#   [play]
#   track    = "internal"     # default; or "alpha", "beta", "production"
#   status   = "completed"    # default; "draft" leaves it for Play Console
#   language = "en-US"        # default; language of the release notes
#
# and PLAY_SERVICE_ACCOUNT_JSON in the app's .env (see env.example).
#
# Release notes come from the commit subjects between the previous tag and this
# release, trimmed to whole lines within Play's 500 character limit.
#
# Safe to re-run: a versionCode Play already has is not uploaded again.
#
# Usage: upload_play.sh [version] [--notes-file FILE] [--dry-run]
#
# --dry-run checks the service account and its access to the app, then stops.

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSION=""
NOTES_FILE=""
EXTRA=()

while [ $# -gt 0 ]; do
    case "$1" in
        --notes-file) NOTES_FILE="$2"; shift 2 ;;
        --notes-file=*) NOTES_FILE="${1#*=}"; shift ;;
        --dry-run) EXTRA+=(--dry-run); shift ;;
        *) VERSION="$1"; shift ;;
    esac
done

CATAPULT_PLATFORM=android
source "${SCRIPT_DIR}/config.sh"

if [ -z "${CATAPULT_HAS_PLAY:-}" ]; then
    echo "❌ [play] section missing from catapult.toml" >&2
    exit 1
fi

cd "$CATAPULT_APP_ROOT"

# Mirror build_android.sh so the release names the build it actually made.
[ "$VERSION" = "0.0.0" ] && VERSION=""
[ -z "$VERSION" ] && VERSION="$(git describe --tags --abbrev=0 2>/dev/null || true)"
BUILD_NUMBER="$(git log -1 --format=%ct 2>/dev/null || echo 1)"

if [ -z "$NOTES_FILE" ]; then
    NOTES_FILE="$(mktemp -t catapult-notes)"
    trap 'rm -f "$NOTES_FILE"' EXIT

    RANGE=""
    if [ -n "$VERSION" ] && git rev-parse -q --verify "refs/tags/${VERSION}" >/dev/null; then
        PREV_TAG="$(git describe --tags --abbrev=0 "${VERSION}^" 2>/dev/null || true)"
        [ -n "$PREV_TAG" ] && RANGE="${PREV_TAG}..${VERSION}"
    fi

    if [ -n "$RANGE" ]; then
        git log "$RANGE" --no-merges --format='- %s' > "$NOTES_FILE"
    else
        git log -20 --no-merges --format='- %s' > "$NOTES_FILE"
    fi

    grep -v -i -E '^- (Bump|Update) version' "$NOTES_FILE" > "${NOTES_FILE}.filtered" || true
    mv "${NOTES_FILE}.filtered" "$NOTES_FILE"
fi

TRACK="${CATAPULT_PLAY_TRACK:-internal}"
echo "🤖 Publishing ${CATAPULT_APP_NAME} v${VERSION:-<project default>} (versionCode ${BUILD_NUMBER}) to the ${TRACK} track"
echo ""

"$CATAPULT_PYTHON" "${SCRIPT_DIR}/upload_play.py" \
    --package "$CATAPULT_APP_BUNDLE_ID" \
    --bundle "$CATAPULT_BUILD_BUNDLE" \
    --track "$TRACK" \
    --status "${CATAPULT_PLAY_STATUS:-completed}" \
    --language "${CATAPULT_PLAY_LANGUAGE:-en-US}" \
    --version-code "$BUILD_NUMBER" \
    --release-name "${VERSION:+${VERSION} }(${BUILD_NUMBER})" \
    --notes-file "$NOTES_FILE" \
    ${EXTRA[@]+"${EXTRA[@]}"}
