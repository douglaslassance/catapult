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

# Dispatch by build kind. Swift continues below; Tauri and Compose delegate.
if [ "$CATAPULT_BUILD_KIND" = "tauri" ]; then
    exec "${SCRIPT_DIR}/build_tauri.sh" "$@"
fi
if [ "$CATAPULT_BUILD_KIND" = "compose" ]; then
    exec "${SCRIPT_DIR}/build_compose.sh" "$@"
fi

cd "$CATAPULT_APP_ROOT"

VERSION="$(catapult_version "${1:-}" 0.0.0)"
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
# The compiled asset catalogue, where an adaptive icon keeps its light, dark
# and tinted appearances. Absent for apps whose icon is only an .icns; the
# check after the Info.plist is written is what says whether it was needed.
[ -f "${BUILD_DIR}/Assets.car" ] && cp "${BUILD_DIR}/Assets.car" "${APP_PATH}/Contents/Resources/"
[ -f LICENSE ] && cp LICENSE "${APP_PATH}/Contents/Resources/"
[ -d Licenses ] && cp -R Licenses "${APP_PATH}/Contents/Resources/"

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
"$CATAPULT_PYTHON" "${SCRIPT_DIR}/render_plist.py" "$CATAPULT_CONFIG" \
    --kind direct --version "$VERSION" \
    --out "${APP_PATH}/Contents/Info.plist"

# `CFBundleIconName` names an entry inside a compiled asset catalogue rather
# than a file. Declared without one in the bundle, macOS finds nothing, falls
# back to `CFBundleIconFile`, and the app ships with a static icon that never
# follows light and dark. That failed silently for months here: the plist said
# one thing, the bundle held another, and nothing on the way out disagreed.
ICON_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" \
    "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)
if [ -n "$ICON_NAME" ] && [ ! -f "${APP_PATH}/Contents/Resources/Assets.car" ]; then
    echo "❌ Info.plist declares CFBundleIconName=${ICON_NAME}, but the bundle" >&2
    echo "   has no Contents/Resources/Assets.car to find it in." >&2
    echo "   Build the asset catalogue to ${BUILD_DIR}/Assets.car, or drop" >&2
    echo "   CFBundleIconName from [plist.extras] if the icon is only an .icns." >&2
    exit 1
fi

echo "APPL????" > "${APP_PATH}/Contents/PkgInfo"

# Resource bundle Info.plist (codesign/notarization scanner expects one)
if [ -n "$BUNDLE_PATH" ]; then
    "$CATAPULT_PYTHON" "${SCRIPT_DIR}/render_plist.py" "$CATAPULT_CONFIG" \
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

        # MIT and bsdiff's BSD licence both require the notice in binary copies.
        SPARKLE_LICENSE="$(dirname "$SPARKLE_XCFRAMEWORK")/LICENSE"
        if [ -f "$SPARKLE_LICENSE" ]; then
            mkdir -p "${APP_PATH}/Contents/Resources/Licenses"
            cp "$SPARKLE_LICENSE" "${APP_PATH}/Contents/Resources/Licenses/Sparkle.txt"
        else
            echo "❌ Sparkle LICENSE not found next to $SPARKLE_XCFRAMEWORK"
            exit 1
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

catapult_make_dmg "$APP_PATH" "${DIST_DIR}/${DMG_NAME}"
catapult_notarize "${DIST_DIR}/${DMG_NAME}"

# After stapling, which modifies the DMG.
echo "🔐 Generating checksum..."
catapult_checksum "${DIST_DIR}/${DMG_NAME}"
echo ""

echo "✅ Build complete!"
echo ""
echo "Files created in ${DIST_DIR}/:"
ls -lh "${DIST_DIR}/${DMG_NAME}"* | awk '{print "  " $9 " (" $5 ")"}'
