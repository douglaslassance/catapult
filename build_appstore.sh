#!/bin/bash
# build_appstore.sh — Build a signed .pkg for Mac App Store submission.
# Requires [appstore] section in catapult.toml.
#
# Usage: build_appstore.sh [version]

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

if [ -z "${CATAPULT_HAS_APPSTORE:-}" ]; then
    echo "❌ [appstore] section missing from catapult.toml"
    exit 1
fi

cd "$CATAPULT_APP_ROOT"

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")}"
BUILD_NUMBER="$(git log -1 --format=%ct 2>/dev/null || echo "$VERSION")"
COMMIT_SHA="$(git log -1 --format=%h 2>/dev/null || echo "unknown")"

APP_NAME="$CATAPULT_APP_NAME"
SLUG="$CATAPULT_APP_SLUG"
BUILD_DIR="$CATAPULT_BUILD_DIR_APPSTORE"
DIST_DIR="$CATAPULT_DIST_DIR"
PKG_NAME="${SLUG}-${VERSION}.pkg"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
BUNDLE_PATH="${APP_PATH}/Contents/Resources/${CATAPULT_APP_RESOURCE_BUNDLE_NAME}"

echo "🔨 Building ${APP_NAME} v${VERSION} (${BUILD_NUMBER}) for Mac App Store"
echo "   Commit: ${COMMIT_SHA}"
echo ""

# Clean (codesign artifacts can be read-only)
if [ -e "${BUILD_DIR}" ]; then
    chmod -R u+w "${BUILD_DIR}" 2>/dev/null || true
    rm -rf "${BUILD_DIR}" 2>/dev/null || { echo "❌ Could not clean ${BUILD_DIR} (try: sudo rm -rf ${BUILD_DIR})"; exit 1; }
fi
mkdir -p "${DIST_DIR}"

# Preserve Package.resolved (APPSTORE_BUILD=1 may drop deps and dirty the tree)
PACKAGE_RESOLVED_BACKUP=""
if [ -f Package.resolved ]; then
    PACKAGE_RESOLVED_BACKUP=$(mktemp /tmp/Package.resolved.XXXXXX)
    cp Package.resolved "$PACKAGE_RESOLVED_BACKUP"
    trap 'if [ -n "$PACKAGE_RESOLVED_BACKUP" ] && [ -f "$PACKAGE_RESOLVED_BACKUP" ]; then cp "$PACKAGE_RESOLVED_BACKUP" Package.resolved; rm -f "$PACKAGE_RESOLVED_BACKUP"; fi' EXIT
fi

export APPSTORE_BUILD=1

swift package clean

echo "📦 Resolving dependencies..."
swift package resolve
echo ""

echo "🎨 Generating AppIcon.icns..."
mkdir -p "$CATAPULT_BUILD_DIR"
"${SCRIPT_DIR}/icon.sh"
echo ""

echo "📦 Building ${CATAPULT_BUILD_ARCH} binary (App Store)..."
swift build -c release --arch "$CATAPULT_BUILD_ARCH" -Xswiftc -DAPPSTORE_BUILD
echo ""

echo "📱 Creating app bundle..."
mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources"

BINARY=".build/release/${CATAPULT_BUILD_EXECUTABLE}"
[ -f "$BINARY" ] || { echo "❌ Binary not found: $BINARY"; exit 1; }

cp "$BINARY" "${APP_PATH}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_PATH}/Contents/MacOS/${APP_NAME}"

cp "${CATAPULT_BUILD_DIR}/AppIcon.icns" "${APP_PATH}/Contents/Resources/"
[ -f LICENSE ] && cp LICENSE "${APP_PATH}/Contents/Resources/"

HAS_BUNDLE=0
if [ -d ".build/release/${CATAPULT_APP_RESOURCE_BUNDLE_NAME}" ]; then
    cp -r ".build/release/${CATAPULT_APP_RESOURCE_BUNDLE_NAME}" "${BUNDLE_PATH}"
    HAS_BUNDLE=1
fi

if [ "$HAS_BUNDLE" = "1" ] && [ -d "$CATAPULT_BUILD_ASSETS" ]; then
    echo "🎨 Compiling asset catalog..."
    xcrun actool \
        --compile "${BUNDLE_PATH}" \
        --platform macosx \
        --minimum-deployment-target "$CATAPULT_APP_MIN_MACOS" \
        --target-device mac \
        --output-format human-readable-text \
        "$CATAPULT_BUILD_ASSETS" 2>&1 | grep -v "^$" || true
fi

python3 "${SCRIPT_DIR}/render_plist.py" "$CATAPULT_CONFIG" \
    --kind appstore --version "$VERSION" --build-number "$BUILD_NUMBER" \
    --out "${APP_PATH}/Contents/Info.plist"

echo "APPL????" > "${APP_PATH}/Contents/PkgInfo"

if [ "$HAS_BUNDLE" = "1" ]; then
    python3 "${SCRIPT_DIR}/render_plist.py" "$CATAPULT_CONFIG" \
        --kind resource --version "$VERSION" \
        --out "${BUNDLE_PATH}/Info.plist"
fi

echo "📋 Embedding provisioning profile..."
if [ ! -f "$CATAPULT_BUILD_PROVISIONING_PROFILE" ]; then
    echo "❌ Provisioning profile not found: $CATAPULT_BUILD_PROVISIONING_PROFILE"
    exit 1
fi
cp "$CATAPULT_BUILD_PROVISIONING_PROFILE" "${APP_PATH}/Contents/embedded.provisionprofile"
echo ""

echo "🧹 Stripping quarantine attributes..."
xattr -cr "${APP_PATH}"
echo ""

echo "🔏 Signing app for App Store..."
codesign --force --sign "$CATAPULT_APP_SIGNING_IDENTITY_APPSTORE" \
    --entitlements "$CATAPULT_BUILD_ENTITLEMENTS_APPSTORE" \
    --options runtime \
    "${APP_PATH}"
echo ""

echo "📦 Creating installer package..."
rm -f "${DIST_DIR}/${PKG_NAME}"
if security find-identity -v | grep -q "3rd Party Mac Developer Installer"; then
    productbuild \
        --component "${APP_PATH}" /Applications \
        --sign "$CATAPULT_APP_SIGNING_IDENTITY_INSTALLER" \
        "${DIST_DIR}/${PKG_NAME}"
else
    echo "❌ Mac Installer Distribution certificate not found"
    echo "   Generate one at: developer.apple.com/account/resources/certificates/add"
    exit 1
fi

echo ""
echo "📦 Package: ${DIST_DIR}/${PKG_NAME}"
echo ""

# Post-build verification
echo "🔍 Running post-build verification..."
echo ""
"${SCRIPT_DIR}/verify_appstore.sh"
