#!/bin/bash
# build_tauri.sh builds a Tauri (Rust and webview) desktop app for the OS it
# runs on, since Tauri bundles only for its host.
#
#   macOS    .dmg wrapped around the .app, Developer ID signed, notarized and stapled
#   Windows  .msi, Authenticode signed when WINDOWS_CERTIFICATE is set
#   Linux    .deb and .AppImage
#
# Each lands in dist/ as ${slug}-${version}-${target}.<ext> next to its .sha256.
# With bundle.createUpdaterArtifacts and TAURI_SIGNING_PRIVATE_KEY, the updater
# bundles land there too with their .sig (a .tar.gz on macOS, the installers
# themselves elsewhere). Windows and Linux need build.platform = "desktop".
# Sparkle is not supported, since Tauri ships its own updater plugin.
#
# Usage: build_tauri.sh [version]

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

if [ "$CATAPULT_BUILD_KIND" != "tauri" ]; then
    echo "❌ build_tauri.sh requires [build] kind = \"tauri\" in catapult.toml"
    exit 1
fi
case "$CATAPULT_BUILD_PLATFORM" in
    desktop) ;;
    macos)
        if [ "$CATAPULT_HOST_OS" != "macos" ]; then
            echo "❌ A macOS Tauri app builds on a Mac. Set build.platform = \"desktop\" to build on Windows and Linux too."
            exit 1
        fi
        ;;
    *)
        echo "❌ build_tauri.sh builds Tauri desktop apps."
        echo "   Tauri iOS and Android apps build with build_ios.sh and build_android.sh."
        exit 1
        ;;
esac

cd "$CATAPULT_APP_ROOT"

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")}"
APP_NAME="$CATAPULT_APP_NAME"
SLUG="$CATAPULT_APP_SLUG"
TARGET="$CATAPULT_BUILD_TARGET_TRIPLE"
BUILD_DIR="$CATAPULT_BUILD_DIR"
DIST_DIR="$CATAPULT_DIST_DIR"
TAURI_DIR="$CATAPULT_BUILD_TAURI_DIR"
BASENAME="${SLUG}-${VERSION}-${TARGET}"
BUNDLE_DIR="${TAURI_DIR}/target/release/bundle"

# Tauri stamps the bundle from tauri.conf.json, so the release version overrides it.
tauri_build() {
    echo "📦 Running tauri build (${1})..."
    catapult_tauri build --bundles "$1" --config "{\"version\":\"${VERSION}\"}"
    echo ""
}

# Prints the one file a bundle folder holds with the given extension, or fails.
bundle_file() {
    local file
    file="$(ls "${BUNDLE_DIR}/${1}"/*"${2}" 2>/dev/null | head -1)"
    if [ -z "$file" ]; then
        echo "❌ tauri build produced no ${2} in ${BUNDLE_DIR}/${1}" >&2
        exit 1
    fi
    echo "$file"
}

# Copies an updater signature next to its renamed bundle, warning when signing was expected but did not happen.
copy_updater_signature() {
    local src="$1" dest="$2"
    if [ -f "${src}.sig" ]; then
        cp "${src}.sig" "${DIST_DIR}/${dest}.sig"
        echo "✅ Updater signature produced (${dest}.sig)"
    elif [ -n "${TAURI_SIGNING_PRIVATE_KEY:-}" ]; then
        echo "⚠️  TAURI_SIGNING_PRIVATE_KEY set but ${src} has no .sig. Check that"
        echo "   bundle.createUpdaterArtifacts is true in ${TAURI_DIR}/tauri.conf.json"
    fi
}

# Signs a file for the updater with the key `tauri build` uses, a path or the key itself, relative to the app root.
sign_for_updater() {
    if [ -f "$TAURI_SIGNING_PRIVATE_KEY" ]; then
        (
            key_path="$TAURI_SIGNING_PRIVATE_KEY"
            unset TAURI_SIGNING_PRIVATE_KEY
            catapult_tauri signer sign --private-key-path "$key_path" "$1"
        )
    else
        catapult_tauri signer sign "$1"
    fi
}

notarize() {
    local dmg="$1" key_file submit_output submission_id wait_output status
    if [ -z "${NOTARIZATION_KEY_ID:-}" ] || [ -z "${NOTARIZATION_ISSUER_ID:-}" ] || [ -z "${NOTARIZATION_KEY:-}" ]; then
        echo "⚠️  Notarization skipped (credentials not set)"
        echo ""
        return
    fi

    echo "📝 Submitting for notarization..."
    key_file=$(mktemp /tmp/notarization_XXXXXX)
    echo "$NOTARIZATION_KEY" | base64 --decode > "$key_file"

    submit_output=$(xcrun notarytool submit "$dmg" \
        --key "$key_file" \
        --key-id "$NOTARIZATION_KEY_ID" \
        --issuer "$NOTARIZATION_ISSUER_ID" 2>&1)
    echo "$submit_output"

    submission_id=$(echo "$submit_output" | grep -E '^\s*id:' | head -1 | awk '{print $2}')
    if [ -z "$submission_id" ]; then
        rm -f "$key_file"
        echo "❌ Failed to get submission ID"
        exit 1
    fi

    wait_output=$(xcrun notarytool wait "$submission_id" \
        --key "$key_file" \
        --key-id "$NOTARIZATION_KEY_ID" \
        --issuer "$NOTARIZATION_ISSUER_ID" 2>&1)
    echo "$wait_output"

    status=$(echo "$wait_output" | grep -E 'status:' | tail -1 | awk '{print $2}')
    if [ "$status" != "Accepted" ]; then
        xcrun notarytool log "$submission_id" \
            --key "$key_file" \
            --key-id "$NOTARIZATION_KEY_ID" \
            --issuer "$NOTARIZATION_ISSUER_ID" 2>&1 || true
        rm -f "$key_file"
        exit 1
    fi
    rm -f "$key_file"
    echo "✅ Notarized"

    xcrun stapler staple "$dmg"
    echo "✅ Stapled"
    echo ""
}

build_macos() {
    local dmg="${BASENAME}.dmg" app_src app_path volname dmg_mount dmg_temp updater_src
    # catapult wraps the .app in its own DMG, so Tauri's DMG would only cost time.
    tauri_build app

    # The bundle is named after productName in tauri.conf.json, which the app owner sets to app.name.
    app_src="${BUNDLE_DIR}/macos/${APP_NAME}.app"
    if [ ! -d "$app_src" ]; then
        echo "❌ Tauri did not produce ${app_src}"
        echo "   Check that productName in ${TAURI_DIR}/tauri.conf.json matches '${APP_NAME}'"
        ls "${BUNDLE_DIR}/macos/" 2>/dev/null || true
        exit 1
    fi

    app_path="${BUILD_DIR}/${APP_NAME}.app"
    ditto "$app_src" "$app_path"
    echo "✅ Copied .app to ${app_path}"
    echo ""

    # Tauri's own signing is incomplete, so the bundle is signed again inside out with Developer ID.
    if [ -n "${APPLE_SIGNING_IDENTITY:-}" ]; then
        echo "🔏 Code signing with Developer ID..."
        find "${app_path}/Contents/Frameworks" -type d \( -name "*.framework" -o -name "*.dylib" \) 2>/dev/null | \
            sort -r | while read -r f; do
                codesign --force --sign "$APPLE_SIGNING_IDENTITY" --options runtime --timestamp \
                    --preserve-metadata=entitlements "$f"
            done
        codesign --force --sign "$APPLE_SIGNING_IDENTITY" \
            --entitlements "$CATAPULT_BUILD_ENTITLEMENTS_DIRECT" \
            --options runtime --timestamp \
            "${app_path}"
        echo "✅ Signed"
    else
        echo "🔏 Ad-hoc signing (local build)..."
        codesign --force --sign - --entitlements "$CATAPULT_BUILD_ENTITLEMENTS_DIRECT" \
            "${app_path}" || echo "⚠️  Code signing skipped"
    fi
    echo ""

    echo "💿 Creating DMG..."
    rm -f "${DIST_DIR}/${dmg}"
    volname="${CATAPULT_DMG_VOLUME_NAME:-$APP_NAME}"
    dmg_mount="/tmp/${SLUG}-dmg-$$"
    dmg_temp="/tmp/${SLUG}-temp-$$.dmg"
    mkdir -p "$dmg_mount"
    hdiutil create -size 300m -fs HFS+ -volname "$volname" "$dmg_temp" -quiet
    hdiutil attach "$dmg_temp" -nobrowse -noverify -noautoopen -mountpoint "$dmg_mount" -quiet
    ditto "${app_path}" "${dmg_mount}/${APP_NAME}.app"
    ln -sf /Applications "${dmg_mount}/Applications"
    hdiutil detach "$dmg_mount" -quiet
    hdiutil convert "$dmg_temp" -format UDZO -imagekey zlib-level=9 -o "${DIST_DIR}/${dmg}" -quiet
    rm -f "$dmg_temp"
    rmdir "$dmg_mount"
    echo "✅ DMG created"
    echo ""

    if [ -n "${APPLE_SIGNING_IDENTITY:-}" ]; then
        echo "🔏 Signing DMG..."
        codesign --force --sign "$APPLE_SIGNING_IDENTITY" "${DIST_DIR}/${dmg}"
        echo ""
    fi

    # The in-app updater on macOS downloads a .tar.gz of the .app rather than the DMG.
    updater_src="${BUNDLE_DIR}/macos/${APP_NAME}.app.tar.gz"
    if [ -f "$updater_src" ]; then
        cp "$updater_src" "${DIST_DIR}/${BASENAME}.tar.gz"
    fi
    copy_updater_signature "$updater_src" "${BASENAME}.tar.gz"
    echo ""

    notarize "${DIST_DIR}/${dmg}"

    # After stapling, which modifies the DMG.
    catapult_checksum "${DIST_DIR}/${dmg}"
    echo ""
}

build_windows() {
    local msi="${BASENAME}.msi" msi_src
    rm -rf "${BUNDLE_DIR}/msi"
    tauri_build msi

    msi_src="$(bundle_file msi .msi)"
    cp "$msi_src" "${DIST_DIR}/${msi}"
    echo "✅ Copied MSI to ${DIST_DIR}/${msi}"
    echo ""

    if [ -n "${WINDOWS_CERTIFICATE:-}" ] && [ -n "${WINDOWS_CERTIFICATE_PASSWORD:-}" ]; then
        catapult_sign_msi "${DIST_DIR}/${msi}"
        # Authenticode rewrote the MSI, so the signature Tauri made for the updater no longer matches it.
        if [ -f "${msi_src}.sig" ]; then
            echo "🔏 Signing the signed MSI for the updater..."
            sign_for_updater "${DIST_DIR#"${CATAPULT_APP_ROOT}/"}/${msi}"
            echo ""
        fi
    else
        echo "⚠️  Authenticode signing skipped (WINDOWS_CERTIFICATE not set)"
        echo ""
        copy_updater_signature "$msi_src" "$msi"
    fi

    catapult_checksum "${DIST_DIR}/${msi}"
    echo ""
}

build_linux() {
    local deb="${BASENAME}.deb" appimage="${BASENAME}.AppImage" deb_src appimage_src
    rm -rf "${BUNDLE_DIR}/deb" "${BUNDLE_DIR}/appimage"
    # CI has no FUSE, so the AppImage tools Tauri downloads unpack themselves instead of mounting.
    export APPIMAGE_EXTRACT_AND_RUN=1
    tauri_build deb,appimage

    deb_src="$(bundle_file deb .deb)"
    appimage_src="$(bundle_file appimage .AppImage)"
    cp "$deb_src" "${DIST_DIR}/${deb}"
    cp "$appimage_src" "${DIST_DIR}/${appimage}"
    echo "✅ Copied DEB and AppImage to ${DIST_DIR}"
    copy_updater_signature "$deb_src" "$deb"
    copy_updater_signature "$appimage_src" "$appimage"
    echo ""

    catapult_checksum "${DIST_DIR}/${deb}"
    catapult_checksum "${DIST_DIR}/${appimage}"
    echo ""
}

echo "🔨 Building ${APP_NAME} v${VERSION} (Tauri, ${TARGET})"
echo ""

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "${DIST_DIR}"
rm -f "${DIST_DIR}/${BASENAME}".*

echo "📦 Installing dependencies..."
catapult_install_dependencies
echo ""

case "$CATAPULT_HOST_OS" in
    macos) build_macos ;;
    windows) build_windows ;;
    linux) build_linux ;;
    *) echo "❌ Tauri desktop builds run on macOS, Windows or Linux (got $(uname -s))"; exit 1 ;;
esac

echo "✅ Build complete!"
ls -lh "${DIST_DIR}/${BASENAME}".* | awk '{print "  " $9 " (" $5 ")"}'
