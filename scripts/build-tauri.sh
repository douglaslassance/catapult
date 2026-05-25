#!/bin/bash
# build-tauri.sh — Build a notarized .app + .dmg for a Tauri (Rust+webview) app.
#
# Pipeline:
#   1. Frontend build (configured via [build] package_manager + frontend_build)
#   2. `tauri build` → produces .app in src-tauri/target/release/bundle/macos/
#   3. Re-sign the .app with $APPLE_SIGNING_IDENTITY (Tauri doesn't sign by default)
#   4. Wrap in a DMG via hdiutil → dist/${slug}-${version}-${target}.dmg
#   5. Notarize + staple
#   6. SHA256
#
# Sparkle is intentionally not supported here — Tauri ships its own updater
# plugin. Use [r2] + push-homebrew.sh downstream just like for Swift apps.
#
# Usage: build-tauri.sh [version]

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/config.sh"

if [ "$CATAPULT_BUILD_KIND" != "tauri" ]; then
    echo "❌ build-tauri.sh requires [build] kind = \"tauri\" in catapult.toml"
    exit 1
fi

cd "$CATAPULT_APP_ROOT"

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")}"
APP_NAME="$CATAPULT_APP_NAME"
SLUG="$CATAPULT_APP_SLUG"
TARGET="$CATAPULT_BUILD_TARGET_TRIPLE"
BUILD_DIR="$CATAPULT_BUILD_DIR"
DIST_DIR="$CATAPULT_DIST_DIR"
DMG_NAME="${SLUG}-${VERSION}-${TARGET}.dmg"
TAURI_DIR="$CATAPULT_BUILD_TAURI_DIR"

echo "🔨 Building ${APP_NAME} v${VERSION} (Tauri)"
echo ""

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "${DIST_DIR}"

# 1. Frontend build (skip if package_manager script handles it via tauri's beforeBuildCommand)
echo "📦 Installing dependencies..."
case "$CATAPULT_BUILD_PACKAGE_MANAGER" in
    bun)  bun install ;;
    pnpm) pnpm install ;;
    yarn) yarn install ;;
    npm)  npm install ;;
esac
echo ""

# 2. Tauri build — runs cargo build --release + bundles the .app
echo "📦 Running tauri build..."
case "$CATAPULT_BUILD_PACKAGE_MANAGER" in
    bun)  bun run tauri build ;;
    pnpm) pnpm tauri build ;;
    yarn) yarn tauri build ;;
    npm)  npm run tauri build ;;
esac
echo ""

# 3. Locate the .app Tauri produced. The directory name is the productName
# from tauri.conf.json — which the app owner sets to $CATAPULT_APP_NAME.
TAURI_APP_SRC="${TAURI_DIR}/target/release/bundle/macos/${APP_NAME}.app"
if [ ! -d "$TAURI_APP_SRC" ]; then
    echo "❌ Tauri did not produce ${TAURI_APP_SRC}"
    echo "   Check that productName in ${TAURI_DIR}/tauri.conf.json matches '${APP_NAME}'"
    ls "${TAURI_DIR}/target/release/bundle/macos/" 2>/dev/null || true
    exit 1
fi

APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
ditto "$TAURI_APP_SRC" "$APP_PATH"
echo "✅ Copied .app to ${APP_PATH}"
echo ""

# 4. Re-sign with Developer ID (Tauri's default signing is incomplete / not used)
if [ -n "${APPLE_SIGNING_IDENTITY:-}" ]; then
    echo "🔏 Code signing with Developer ID..."
    # Sign nested frameworks/dylibs inside-out
    find "${APP_PATH}/Contents/Frameworks" -type d \( -name "*.framework" -o -name "*.dylib" \) 2>/dev/null | \
        sort -r | while read -r f; do
            codesign --force --sign "$APPLE_SIGNING_IDENTITY" --options runtime --timestamp \
                --preserve-metadata=entitlements "$f"
        done
    codesign --force --sign "$APPLE_SIGNING_IDENTITY" \
        --entitlements "$CATAPULT_BUILD_ENTITLEMENTS_DIRECT" \
        --options runtime --timestamp \
        "${APP_PATH}"
    echo "✅ Signed"
else
    echo "🔏 Ad-hoc signing (local build)..."
    codesign --force --sign - --entitlements "$CATAPULT_BUILD_ENTITLEMENTS_DIRECT" \
        "${APP_PATH}" || echo "⚠️  Code signing skipped"
fi
echo ""

# 5. DMG
echo "💿 Creating DMG..."
rm -f "${DIST_DIR}/${DMG_NAME}"
VOLNAME="${CATAPULT_DMG_VOLUME_NAME:-$APP_NAME}"
DMG_MOUNT="/tmp/${SLUG}-dmg-$$"
DMG_TEMP="/tmp/${SLUG}-temp-$$.dmg"
mkdir -p "$DMG_MOUNT"
hdiutil create -size 300m -fs HFS+ -volname "$VOLNAME" "$DMG_TEMP" -quiet
hdiutil attach "$DMG_TEMP" -nobrowse -noverify -noautoopen -mountpoint "$DMG_MOUNT" -quiet
ditto "${APP_PATH}" "${DMG_MOUNT}/${APP_NAME}.app"
ln -sf /Applications "${DMG_MOUNT}/Applications"
hdiutil detach "$DMG_MOUNT" -quiet
hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "${DIST_DIR}/${DMG_NAME}" -quiet
rm -f "$DMG_TEMP"
rmdir "$DMG_MOUNT"
echo "✅ DMG created"
echo ""

if [ -n "${APPLE_SIGNING_IDENTITY:-}" ]; then
    echo "🔏 Signing DMG..."
    codesign --force --sign "$APPLE_SIGNING_IDENTITY" "${DIST_DIR}/${DMG_NAME}"
    echo ""
fi

# 6. Notarize + staple
if [ -n "${NOTARIZATION_KEY_ID:-}" ] && [ -n "${NOTARIZATION_ISSUER_ID:-}" ] && [ -n "${NOTARIZATION_KEY:-}" ]; then
    echo "📝 Submitting for notarization..."
    NOTARIZATION_KEY_FILE=$(mktemp /tmp/notarization_XXXXXX)
    echo "$NOTARIZATION_KEY" | base64 --decode > "$NOTARIZATION_KEY_FILE"

    SUBMIT_OUTPUT=$(xcrun notarytool submit "${DIST_DIR}/${DMG_NAME}" \
        --key "$NOTARIZATION_KEY_FILE" \
        --key-id "$NOTARIZATION_KEY_ID" \
        --issuer "$NOTARIZATION_ISSUER_ID" 2>&1)
    echo "$SUBMIT_OUTPUT"

    SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" | grep -E '^\s*id:' | head -1 | awk '{print $2}')
    if [ -z "$SUBMISSION_ID" ]; then
        rm -f "$NOTARIZATION_KEY_FILE"
        echo "❌ Failed to get submission ID"
        exit 1
    fi

    WAIT_OUTPUT=$(xcrun notarytool wait "$SUBMISSION_ID" \
        --key "$NOTARIZATION_KEY_FILE" \
        --key-id "$NOTARIZATION_KEY_ID" \
        --issuer "$NOTARIZATION_ISSUER_ID" 2>&1)
    echo "$WAIT_OUTPUT"

    NOTARIZATION_STATUS=$(echo "$WAIT_OUTPUT" | grep -E 'status:' | tail -1 | awk '{print $2}')
    if [ "$NOTARIZATION_STATUS" != "Accepted" ]; then
        xcrun notarytool log "$SUBMISSION_ID" \
            --key "$NOTARIZATION_KEY_FILE" \
            --key-id "$NOTARIZATION_KEY_ID" \
            --issuer "$NOTARIZATION_ISSUER_ID" 2>&1 || true
        rm -f "$NOTARIZATION_KEY_FILE"
        exit 1
    fi
    rm -f "$NOTARIZATION_KEY_FILE"
    echo "✅ Notarized"

    xcrun stapler staple "${DIST_DIR}/${DMG_NAME}"
    echo "✅ Stapled"
    echo ""
else
    echo "⚠️  Notarization skipped (credentials not set)"
    echo ""
fi

# 7. SHA256
shasum -a 256 "${DIST_DIR}/${DMG_NAME}" > "${DIST_DIR}/${DMG_NAME}.sha256"
cat "${DIST_DIR}/${DMG_NAME}.sha256"
echo ""

echo "✅ Build complete!"
ls -lh "${DIST_DIR}/${DMG_NAME}"* | awk '{print "  " $9 " (" $5 ")"}'
