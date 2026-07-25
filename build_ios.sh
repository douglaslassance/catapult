#!/bin/bash
# build_ios.sh — Archive an iOS Xcode project and export a signed .ipa for
# App Store Connect (TestFlight). This is the iOS counterpart to
# build_appstore.sh; where the macOS path hand-assembles a .app from SPM
# output, iOS lets xcodebuild do the archiving, signing, and packaging.
#
# Requires build.kind = "xcodeproj", build.platform = "ios", and an [appstore]
# section in catapult.toml.
#
# Usage: build_ios.sh [version]

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

if [ "$CATAPULT_BUILD_KIND" != "xcodeproj" ] || [ "$CATAPULT_BUILD_PLATFORM" != "ios" ]; then
    echo "❌ build_ios.sh requires build.kind = 'xcodeproj' and build.platform = 'ios'" >&2
    exit 1
fi
if [ -z "${CATAPULT_HAS_APPSTORE:-}" ]; then
    echo "❌ [appstore] section missing from catapult.toml" >&2
    exit 1
fi

cd "$CATAPULT_APP_ROOT"

# Marketing version: explicit arg or latest git tag. release.sh passes "0.0.0"
# when there's no tag — treat that as "unset" and let the Xcode project's own
# MARKETING_VERSION stand rather than downgrading the app to 0.0.0.
VERSION="${1:-}"
[ "$VERSION" = "0.0.0" ] && VERSION=""
[ -z "$VERSION" ] && VERSION="$(git describe --tags --abbrev=0 2>/dev/null || true)"
# Monotonic build number. App Store Connect requires each upload for a given
# marketing version to have a unique, increasing CFBundleVersion; the latest
# commit's Unix timestamp gives us exactly that without any state to track, and
# matches how the macOS path (build_appstore.sh) derives it.
BUILD_NUMBER="$(git log -1 --format=%ct 2>/dev/null || echo 1)"
COMMIT_SHA="$(git log -1 --format=%h 2>/dev/null || echo "unknown")"

APP_NAME="$CATAPULT_APP_NAME"
BUILD_DIR="$CATAPULT_BUILD_DIR"
ARCHIVE="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"

echo "🔨 Archiving ${APP_NAME} v${VERSION:-<project default>} (build ${BUILD_NUMBER}) for iOS App Store"
echo "   Commit: ${COMMIT_SHA}"
echo ""

# Optional pre-build hook, e.g. `xcodegen generate` when the .xcodeproj is
# generated from a manifest and gitignored.
if [ -n "${CATAPULT_BUILD_PREGENERATE:-}" ]; then
    echo "⚙️  Pre-generate: ${CATAPULT_BUILD_PREGENERATE}"
    eval "$CATAPULT_BUILD_PREGENERATE"
    echo ""
fi

rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR"

# Project vs workspace selector.
if [ -n "${CATAPULT_BUILD_WORKSPACE:-}" ]; then
    PROJECT_ARGS=(-workspace "$CATAPULT_BUILD_WORKSPACE")
else
    PROJECT_ARGS=(-project "$CATAPULT_BUILD_PROJECT")
fi

# Signing. Locally, xcodebuild uses the developer's signed-in Xcode account
# (an Admin on the team) via -allowProvisioningUpdates to create the App Store
# distribution certificate and profile. In CI there's no account, so fall back
# to App Store Connect API-key cloud signing — note the key must have signing
# access; a purely upload-scoped key fails with "Cloud signing permission error".
AUTH_ARGS=()
if [ -n "${CI:-}" ] && [ -n "${NOTARIZATION_KEY_ID:-}" ] && [ -n "${NOTARIZATION_ISSUER_ID:-}" ]; then
    KEYDIR="${HOME}/.appstoreconnect/private_keys"
    KEYFILE="${KEYDIR}/AuthKey_${NOTARIZATION_KEY_ID}.p8"
    if [ -n "${NOTARIZATION_KEY:-}" ]; then
        mkdir -p "$KEYDIR"
        echo "$NOTARIZATION_KEY" | base64 --decode > "$KEYFILE"
    fi
    if [ -f "$KEYFILE" ]; then
        AUTH_ARGS=(-authenticationKeyPath "$KEYFILE"
                   -authenticationKeyID "$NOTARIZATION_KEY_ID"
                   -authenticationKeyIssuerID "$NOTARIZATION_ISSUER_ID")
    fi
fi

# Version overrides: always stamp the build number; only override the marketing
# version when one was resolved (otherwise keep the project's own value).
VERSION_ARGS=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
[ -n "$VERSION" ] && VERSION_ARGS+=(MARKETING_VERSION="$VERSION")

echo "📦 Archiving…"
xcodebuild archive \
    "${PROJECT_ARGS[@]}" \
    -scheme "$CATAPULT_BUILD_SCHEME" \
    -configuration "$CATAPULT_BUILD_CONFIGURATION" \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    "${AUTH_ARGS[@]}" \
    "${VERSION_ARGS[@]}"
echo ""

# ExportOptions for App Store Connect distribution. `destination = export`
# leaves a local .ipa; upload_ios.sh sends it. manageAppVersionAndBuildNumber
# is false so Xcode keeps the version/build we archived with.
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>${CATAPULT_APP_TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
PLIST

echo "📤 Exporting .ipa…"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    "${AUTH_ARGS[@]}"
echo ""

IPA="$(ls "$EXPORT_DIR"/*.ipa 2>/dev/null | head -1)"
[ -n "$IPA" ] || { echo "❌ No .ipa produced in ${EXPORT_DIR}" >&2; exit 1; }
echo "📦 IPA: ${IPA}"
