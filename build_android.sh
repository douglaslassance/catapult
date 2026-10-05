#!/bin/bash
# build_android.sh builds a signed Android App Bundle (.aab) with Gradle for
# Google Play. It is the Android counterpart to build_ios.sh.
#
# Requires build.kind = "gradle" and build.platform = "android" in
# catapult.toml. Signing stays with the app's own Gradle config (e.g. a
# gitignored keystore.properties), so the release task must produce a bundle
# signed with the app's upload key; this script refuses an unsigned one.
#
# The version is handed to Gradle as CATAPULT_VERSION and CATAPULT_BUILD_NUMBER
# environment variables. The app's build.gradle.kts should prefer them for
# versionName and versionCode, as described in catapult.toml.example.
#
# Usage: build_android.sh [version]

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

if [ "$CATAPULT_BUILD_KIND" != "gradle" ] || [ "$CATAPULT_BUILD_PLATFORM" != "android" ]; then
    echo "❌ build_android.sh requires build.kind = 'gradle' and build.platform = 'android'" >&2
    exit 1
fi

cd "$CATAPULT_APP_ROOT"

# Same derivation as build_ios.sh: the tag names the version, and the latest
# commit's Unix timestamp is a versionCode that only ever increases, which is
# all Play asks of it. It stays under Play's 2,100,000,000 ceiling until 2036.
VERSION="${1:-}"
[ "$VERSION" = "0.0.0" ] && VERSION=""
[ -z "$VERSION" ] && VERSION="$(git describe --tags --abbrev=0 2>/dev/null || true)"
BUILD_NUMBER="$(git log -1 --format=%ct 2>/dev/null || echo 1)"
COMMIT_SHA="$(git log -1 --format=%h 2>/dev/null || echo "unknown")"

echo "🔨 Building ${CATAPULT_APP_NAME} v${VERSION:-<project default>} (versionCode ${BUILD_NUMBER}) for Google Play"
echo "   Commit: ${COMMIT_SHA}"
echo ""

if [ -n "${CATAPULT_BUILD_PREGENERATE:-}" ]; then
    echo "⚙️  Pre-generate: ${CATAPULT_BUILD_PREGENERATE}"
    eval "$CATAPULT_BUILD_PREGENERATE"
fi

if [ ! -x ./gradlew ]; then
    echo "❌ ./gradlew not found at the app repo root" >&2
    exit 1
fi

# A stale bundle from an earlier build must never be mistaken for this one.
rm -f "$CATAPULT_BUILD_BUNDLE"

CATAPULT_VERSION="$VERSION" CATAPULT_BUILD_NUMBER="$BUILD_NUMBER" \
    ./gradlew --quiet ":${CATAPULT_BUILD_MODULE}:${CATAPULT_BUILD_TASK}"

if [ ! -f "$CATAPULT_BUILD_BUNDLE" ]; then
    echo "❌ Expected bundle not found: ${CATAPULT_BUILD_BUNDLE}" >&2
    echo "   Set build.bundle in catapult.toml if the task writes elsewhere." >&2
    exit 1
fi

# Play rejects an unsigned bundle, and an unsigned one means keystore config is missing.
if ! jarsigner -verify "$CATAPULT_BUILD_BUNDLE" 2>/dev/null | grep -q "jar verified"; then
    echo "❌ ${CATAPULT_BUILD_BUNDLE} is not signed. Check the app's release signing config." >&2
    exit 1
fi

echo "✅ Built and signed ${CATAPULT_BUILD_BUNDLE}"
