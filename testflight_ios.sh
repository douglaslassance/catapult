#!/bin/bash
# testflight_ios.sh — Make an uploaded iOS build available to TestFlight testers.
#
# Uploading a build is not the same as distributing it. This waits for App Store
# Connect to finish processing, writes "What to Test", attaches the beta groups
# from catapult.toml, and submits the build for Beta App Review when any of
# those groups is external.
#
# Requires a [testflight] section in catapult.toml:
#
#   [testflight]
#   groups = ["Friends"]        # beta group names, exactly as named in ASC
#   submit_for_review = true    # default true; external groups need it
#   timeout = 1200              # seconds to wait for processing; default 1200
#
# "What to Test" is generated from the commit subjects between the previous tag
# and this release, which assumes the repo writes imperative one-line subjects.
#
# Safe to re-run: every step is idempotent, so if processing outruns the timeout
# you can run this again once the build is ready.
#
# Existing "What to Test" text is never overwritten (so a re-run won't clobber
# something you typed in App Store Connect); pass --force-notes to replace it.
#
# Usage: testflight_ios.sh [version] [--build-number N] [--notes-file FILE]
#                          [--dry-run] [--force-notes]

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSION=""
BUILD_NUMBER=""
NOTES_FILE=""
EXTRA=()

while [ $# -gt 0 ]; do
    case "$1" in
        --build-number) BUILD_NUMBER="$2"; shift 2 ;;
        --build-number=*) BUILD_NUMBER="${1#*=}"; shift ;;
        --notes-file) NOTES_FILE="$2"; shift 2 ;;
        --notes-file=*) NOTES_FILE="${1#*=}"; shift ;;
        --dry-run) EXTRA+=(--dry-run); shift ;;
        --force-notes) EXTRA+=(--force-notes); shift ;;
        *) VERSION="$1"; shift ;;
    esac
done

source "${SCRIPT_DIR}/config.sh"

if [ "$CATAPULT_BUILD_PLATFORM" != "ios" ]; then
    echo "❌ testflight_ios.sh requires build.platform = 'ios'" >&2
    exit 1
fi
if [ -z "${CATAPULT_HAS_TESTFLIGHT:-}" ]; then
    echo "ℹ️  No [testflight] section in catapult.toml; skipping TestFlight setup."
    exit 0
fi

cd "$CATAPULT_APP_ROOT"

# Mirror build_ios.sh so we look up the build it actually uploaded.
[ "$VERSION" = "0.0.0" ] && VERSION=""
[ -z "$VERSION" ] && VERSION="$(git describe --tags --abbrev=0 2>/dev/null || true)"
[ -z "$BUILD_NUMBER" ] && BUILD_NUMBER="$(git log -1 --format=%ct 2>/dev/null || echo 1)"

# "What to Test" from the commits in this release. Prefer the range between the
# previous tag and this one; fall back to recent history for an untagged build.
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

    # The version-bump commit is bookkeeping, not something to test.
    grep -v -i -E '^- (Bump|Update) version' "$NOTES_FILE" > "${NOTES_FILE}.filtered" || true
    mv "${NOTES_FILE}.filtered" "$NOTES_FILE"
fi

echo "✈️  Configuring TestFlight for ${CATAPULT_APP_NAME} v${VERSION:-<project default>} (build ${BUILD_NUMBER})"
echo ""
echo "What to Test:"
sed 's/^/   /' "$NOTES_FILE"
echo ""

python3 "${SCRIPT_DIR}/testflight_ios.py" \
    --config "$CATAPULT_CONFIG" \
    --version "$VERSION" \
    --build-number "$BUILD_NUMBER" \
    --notes-file "$NOTES_FILE" \
    --timeout "${CATAPULT_TESTFLIGHT_TIMEOUT:-1200}" \
    ${EXTRA[@]+"${EXTRA[@]}"}
