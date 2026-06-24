#!/bin/bash
# build.sh — Build a notarized .app + .dmg for direct distribution.
# Optional Sparkle embedding/signing if [sparkle] is present in catapult.toml.
#
# Usage:   build.sh [version]
# Version: defaults to latest git tag, or 0.0.0.

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# Dispatch by build kind. Swift continues below; Tauri delegates.
if [ "$CATAPULT_BUILD_KIND" = "tauri" ]; then
    exec "${SCRIPT_DIR}/build_tauri.sh" "$@"
fi

cd "$CATAPULT_APP_ROOT"

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")}"
APP_NAME="$CATAPULT_APP_NAME"
SLUG="$CATAPULT_APP_SLUG"
TARGET="$CATAPULT_BUILD_TARGET_TRIPLE"
BUILD_DIR="$CATAPULT_BUILD_DIR"
DIST_DIR="$CATAPULT_DIST_DIR"
DMG_NAME="${SLUG}-${VERSION}-${TARGET}.dmg"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"

echo "🔨 Building ${APP_NAME} v${VERSION}"
echo ""

rm -rf "${BUILD_DIR}"
mkdir -p "${DIST_DIR}"
swift package clean

echo "📦 Resolving dependencies..."
swift package resolve
echo ""

echo "🎨 Generating AppIcon.icns..."
mkdir -p "$BUILD_DIR"
"${SCRIPT_DIR}/icon.sh"
echo ""

echo "📦 Building ${CATAPULT_BUILD_ARCH} binary..."
swift build -c release --arch "$CATAPULT_BUILD_ARCH"
echo ""

echo "📱 Creating app bundle..."
mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources"

BINARY=".build/release/${CATAPULT_BUILD_EXECUTABLE}"
if [ ! -f "$BINARY" ]; then
    echo "❌ Binary not found: $BINARY"
    exit 1
fi

cp "$BINARY" "${APP_PATH}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_PATH}/Contents/MacOS/${APP_NAME}"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${APP_PATH}/Contents/MacOS/${APP_NAME}"

cp "${BUILD_DIR}/AppIcon.icns" "${APP_PATH}/Contents/Resources/"
[ -f LICENSE ] && cp LICENSE "${APP_PATH}/Contents/Resources/"

# SPM resource bundle (Bundle.module support)
BUNDLE_PATH="${APP_PATH}/Contents/Resources/${CATAPULT_APP_RESOURCE_BUNDLE_NAME}"
if [ -d ".build/release/${CATAPULT_APP_RESOURCE_BUNDLE_NAME}" ]; then
    cp -r ".build/release/${CATAPULT_APP_RESOURCE_BUNDLE_NAME}" "${BUNDLE_PATH}"
    echo "✅ Resource bundle copied"
else
    # Some packages (no `resources:` in target) don't emit a resource bundle.
    # Skip; downstream actool / plist writes will be no-ops or fail clearly.
    BUNDLE_PATH=""
    echo "ℹ️  No SPM resource bundle in .build/release — skipping"
fi

if [ -n "$BUNDLE_PATH" ] && [ -d "$CATAPULT_BUILD_ASSETS" ]; then
    echo "🎨 Compiling asset catalog..."
    xcrun actool \
        --compile "${BUNDLE_PATH}" \
        --platform macosx \
        --minimum-deployment-target "$CATAPULT_APP_MIN_MACOS" \
        --target-device mac \
        --output-format human-readable-text \
        "$CATAPULT_BUILD_ASSETS" 2>&1 | grep -v "^$" || true
fi

# Info.plist for the app bundle
python3 "${SCRIPT_DIR}/render_plist.py" "$CATAPULT_CONFIG" \
    --kind direct --version "$VERSION" \
    --out "${APP_PATH}/Contents/Info.plist"

echo "APPL????" > "${APP_PATH}/Contents/PkgInfo"

# Resource bundle Info.plist (codesign/notarization scanner expects one)
if [ -n "$BUNDLE_PATH" ]; then
    python3 "${SCRIPT_DIR}/render_plist.py" "$CATAPULT_CONFIG" \
        --kind resource --version "$VERSION" \
        --out "${BUNDLE_PATH}/Info.plist"
fi

# Sparkle embedding (optional)
if [ -n "${CATAPULT_HAS_SPARKLE:-}" ]; then
    SPARKLE_XCFRAMEWORK=$(find .build/artifacts -name "Sparkle.xcframework" -type d 2>/dev/null | head -1)
    if [ -n "$SPARKLE_XCFRAMEWORK" ]; then
        echo "🔗 Embedding Sparkle..."
        SPARKLE_FRAMEWORK=$(find "$SPARKLE_XCFRAMEWORK" -name "Sparkle.framework" -type d | head -1)
        mkdir -p "${APP_PATH}/Contents/Frameworks"
        cp -R "$SPARKLE_FRAMEWORK" "${APP_PATH}/Contents/Frameworks/"

        XPC_SRC="${APP_PATH}/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/org.sparkle-project.InstallerLauncher.xpc"
        if [ -d "$XPC_SRC" ]; then
            mkdir -p "${APP_PATH}/Contents/XPCServices"
            cp -R "$XPC_SRC" "${APP_PATH}/Contents/XPCServices/"
        fi
        echo "✅ Sparkle embedded"
    else
        echo "⚠️  Sparkle.xcframework not found — run 'swift package resolve' first"
    fi
    echo ""
fi

# Code sign (Developer ID — nested binaries use --preserve-metadata=entitlements;
# only the top bundle gets the app's own entitlements file)
if command -v codesign &>/dev/null; then
    if [ -n "${APPLE_SIGNING_IDENTITY:-}" ]; then
        echo "🔏 Code signing with Developer ID..."
        if [ -d "${APP_PATH}/Contents/XPCServices/org.sparkle-project.InstallerLauncher.xpc" ]; then
            codesign --force --sign "$APPLE_SIGNING_IDENTITY" --options runtime --timestamp \
                --preserve-metadata=entitlements \
                "${APP_PATH}/Contents/XPCServices/org.sparkle-project.InstallerLauncher.xpc"
        fi
        if [ -d "${APP_PATH}/Contents/Frameworks/Sparkle.framework" ]; then
            SPARKLE_FW="${APP_PATH}/Contents/Frameworks/Sparkle.framework/Versions/B"
            for binary in \
                "$SPARKLE_FW/Autoupdate" \
                "$SPARKLE_FW/XPCServices/Downloader.xpc" \
                "$SPARKLE_FW/XPCServices/Installer.xpc" \
                "$SPARKLE_FW/Updater.app/Contents/MacOS/Updater" \
                "$SPARKLE_FW/Updater.app"; do
                [ -e "$binary" ] && codesign --force --sign "$APPLE_SIGNING_IDENTITY" \
                    --options runtime --timestamp --preserve-metadata=entitlements "$binary"
            done
            codesign --force --sign "$APPLE_SIGNING_IDENTITY" --options runtime --timestamp \
                --preserve-metadata=entitlements \
                "${APP_PATH}/Contents/Frameworks/Sparkle.framework"
        fi
        codesign --force --sign "$APPLE_SIGNING_IDENTITY" \
            --entitlements "$CATAPULT_BUILD_ENTITLEMENTS_DIRECT" \
            --options runtime --timestamp \
            "${APP_PATH}"
    else
        echo "🔏 Code signing with ad-hoc identity (local build)..."
        codesign --force --sign - --entitlements "$CATAPULT_BUILD_ENTITLEMENTS_DIRECT" \
            "${APP_PATH}" || echo "⚠️  Code signing skipped"
    fi
fi

echo "✅ App bundle created"
echo ""

# DMG
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

# Notarize + staple
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
        echo "❌ Failed to get submission ID"
        rm -f "$NOTARIZATION_KEY_FILE"
        exit 1
    fi
    echo "Submission ID: $SUBMISSION_ID"
    echo ""

    echo "⏳ Waiting for notarization result..."
    WAIT_OUTPUT=$(xcrun notarytool wait "$SUBMISSION_ID" \
        --key "$NOTARIZATION_KEY_FILE" \
        --key-id "$NOTARIZATION_KEY_ID" \
        --issuer "$NOTARIZATION_ISSUER_ID" 2>&1)
    echo "$WAIT_OUTPUT"

    NOTARIZATION_STATUS=$(echo "$WAIT_OUTPUT" | grep -E 'status:' | tail -1 | awk '{print $2}')

    if [ "$NOTARIZATION_STATUS" != "Accepted" ]; then
        echo "❌ Notarization failed: ${NOTARIZATION_STATUS}"
        xcrun notarytool log "$SUBMISSION_ID" \
            --key "$NOTARIZATION_KEY_FILE" \
            --key-id "$NOTARIZATION_KEY_ID" \
            --issuer "$NOTARIZATION_ISSUER_ID" 2>&1 || true
        rm -f "$NOTARIZATION_KEY_FILE"
        exit 1
    fi

    rm -f "$NOTARIZATION_KEY_FILE"
    echo "✅ Notarized"
    echo ""

    echo "📎 Stapling..."
    xcrun stapler staple "${DIST_DIR}/${DMG_NAME}"
    echo "✅ Stapled"
    echo ""
else
    echo "⚠️  Notarization skipped (credentials not set)"
    echo ""
fi

# SHA256 (after stapling, since stapling modifies the DMG)
echo "🔐 Generating checksum..."
shasum -a 256 "${DIST_DIR}/${DMG_NAME}" > "${DIST_DIR}/${DMG_NAME}.sha256"
cat "${DIST_DIR}/${DMG_NAME}.sha256"
echo ""

# Sparkle signature (optional)
if [ -n "${CATAPULT_HAS_SPARKLE:-}" ]; then
    SPARKLE_BIN=$(find .build/artifacts -name "sign_update" 2>/dev/null | head -1)
    if [ -z "$SPARKLE_BIN" ]; then
        echo "⚠️  sign_update not found — skipping Sparkle signing"
    elif [ -z "${SPARKLE_PUBLIC_KEY:-}" ]; then
        echo "⚠️  SPARKLE_PUBLIC_KEY not set, skipping Sparkle signing"
    else
        SPARKLE_TOOLS_DIR=$(dirname "$SPARKLE_BIN")
        echo "✍️  Signing DMG for Sparkle..."

        if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
            SPARKLE_KEY_FILE=$(mktemp /tmp/sparkle_key_XXXXXX)
            echo "$SPARKLE_PRIVATE_KEY" | base64 --decode > "$SPARKLE_KEY_FILE"
            ED_SIG=$("$SPARKLE_TOOLS_DIR/sign_update" "${DIST_DIR}/${DMG_NAME}" --ed-key-file "$SPARKLE_KEY_FILE" 2>/dev/null)
            rm -f "$SPARKLE_KEY_FILE"
        elif [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
            ED_SIG=$("$SPARKLE_TOOLS_DIR/sign_update" "${DIST_DIR}/${DMG_NAME}" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" 2>/dev/null)
        else
            ED_SIG=$("$SPARKLE_TOOLS_DIR/sign_update" "${DIST_DIR}/${DMG_NAME}" 2>/dev/null)
        fi

        if [ -z "$ED_SIG" ]; then
            echo "❌ Failed to sign DMG for Sparkle"
            exit 1
        fi
        echo "$ED_SIG" > "${DIST_DIR}/${DMG_NAME}.edsig"
        echo "✅ Sparkle signature saved"
    fi
    echo ""
fi

echo "✅ Build complete!"
echo ""
echo "Files created in ${DIST_DIR}/:"
ls -lh "${DIST_DIR}/${DMG_NAME}"* | awk '{print "  " $9 " (" $5 ")"}'
