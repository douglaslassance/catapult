#!/bin/bash
# build_compose.sh builds a Compose Multiplatform desktop app (JVM, Gradle,
# jpackage) for the OS it runs on, since jpackage cannot cross-build.
#
#   macOS    .dmg, signed inside out, notarized and stapled
#   Windows  .msi, Authenticode signed when WINDOWS_CERTIFICATE is set
#   Linux    .deb and .AppImage
#
# Each lands in dist/ as ${slug}-${version}-${target}.<ext> next to its .sha256.
# Gradle gets the version as -Papp.version, and the macOS Info.plist is stamped
# with it again since jpackage refuses a zero major version.
#
# Usage: build_compose.sh [version]

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATAPULT_PLATFORM=desktop
source "${SCRIPT_DIR}/config.sh"

if [ "$CATAPULT_BUILD_KIND" != "compose" ]; then
    echo "❌ build_compose.sh requires [build] kind = \"compose\" in catapult.toml"
    exit 1
fi

cd "$CATAPULT_APP_ROOT"

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")}"
APP_NAME="$CATAPULT_APP_NAME"
SLUG="$CATAPULT_APP_SLUG"
TARGET="$CATAPULT_BUILD_TARGET_TRIPLE"
BUILD_DIR="$CATAPULT_BUILD_DIR"
DIST_DIR="$CATAPULT_DIST_DIR"
MODULE="$CATAPULT_BUILD_GRADLE_MODULE"
BINARIES="${MODULE}/build/compose/binaries/main"
BASENAME="${SLUG}-${VERSION}-${TARGET}"

# Runs Compose tasks on the app module with the release version.
gradle_tasks() {
    local tasks=() task
    for task in "$@"; do
        tasks+=(":${MODULE}:${task}")
    done
    echo "📦 Running Gradle ${tasks[*]}..."
    ./gradlew --quiet "-Papp.version=${VERSION}" "${tasks[@]}"
    echo ""
}

# Writes dist/<file>.sha256, with sha256sum where shasum is missing (Git Bash).
checksum() {
    local file="${DIST_DIR}/$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" > "${file}.sha256"
    else
        sha256sum "$file" > "${file}.sha256"
    fi
    cat "${file}.sha256"
}

# Hardened runtime and a secure timestamp on every signature, as notarization requires.
sign() {
    codesign --force --sign "$APPLE_SIGNING_IDENTITY" --options runtime --timestamp "$@"
}

# Prints the Mach-O files under a directory, dropping the extra line `file` prints per universal slice.
macho_files() {
    find "$1" -type f -exec file --mime-type {} + | grep -v ' (for architecture ' | sed -n 's|: *application/x-mach-binary$||p'
}

# Notarization looks inside jars too, so each native in one is extracted, signed and zipped back in.
sign_jar_natives() {
    local jar="$1" tmp native
    tmp="$(mktemp -d)"
    unzip -q -o "$jar" -x '*.class' -d "$tmp"
    while IFS= read -r native; do
        sign "$native"
        (cd "$tmp" && zip -q -X "$jar" "${native#"$tmp"/}")
        echo "   ${jar##*/}: ${native#"$tmp"/}"
    done < <(macho_files "$tmp")
    rm -rf "$tmp"
}

# Signs inside out: jar natives, loose Mach-O files, the bundled runtime, then the app.
sign_app() {
    local app="$1" file
    # Finder or quarantine attributes on any file make codesign refuse the bundle.
    xattr -cr "$app"

    echo "🔏 Signing natives inside jars..."
    while IFS= read -r file; do
        sign_jar_natives "$file"
    done < <(find "${app}/Contents/app" -type f -name '*.jar')

    echo "🔏 Signing Mach-O files..."
    while IFS= read -r file; do
        if file -b "$file" | head -1 | grep -q 'executable'; then
            sign --entitlements "$CATAPULT_BUILD_ENTITLEMENTS_DIRECT" "$file"
        else
            sign "$file"
        fi
    done < <(macho_files "${app}/Contents")

    if [ -d "${app}/Contents/runtime" ]; then
        echo "🔏 Signing the bundled runtime..."
        sign "${app}/Contents/runtime"
    fi

    echo "🔏 Signing the app..."
    sign --entitlements "$CATAPULT_BUILD_ENTITLEMENTS_DIRECT" "$app"
    codesign --verify --deep --strict "$app"
}

make_dmg() {
    local dmg="$1" volname mount temp size_mb
    echo "💿 Creating DMG..."
    rm -f "$dmg"
    volname="${CATAPULT_DMG_VOLUME_NAME:-$APP_NAME}"
    mount="/tmp/${SLUG}-dmg-$$"
    temp="/tmp/${SLUG}-temp-$$.dmg"
    # A bundled JVM runs to hundreds of MB, so the image is sized from the app plus HFS+ headroom.
    size_mb=$(( $(du -sm "$APP_PATH" | cut -f1) * 6 / 5 + 50 ))
    mkdir -p "$mount"
    hdiutil create -size "${size_mb}m" -fs HFS+ -volname "$volname" "$temp" -quiet
    hdiutil attach "$temp" -nobrowse -noverify -noautoopen -mountpoint "$mount" -quiet
    ditto "$APP_PATH" "${mount}/${APP_NAME}.app"
    ln -sf /Applications "${mount}/Applications"
    hdiutil detach "$mount" -quiet
    hdiutil convert "$temp" -format UDZO -imagekey zlib-level=9 -o "$dmg" -quiet
    rm -f "$temp"
    rmdir "$mount"
    echo "✅ DMG created"
    echo ""
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
        echo "❌ Failed to get submission ID"
        rm -f "$key_file"
        exit 1
    fi
    echo "Submission ID: $submission_id"
    echo ""

    echo "⏳ Waiting for notarization result..."
    wait_output=$(xcrun notarytool wait "$submission_id" \
        --key "$key_file" \
        --key-id "$NOTARIZATION_KEY_ID" \
        --issuer "$NOTARIZATION_ISSUER_ID" 2>&1)
    echo "$wait_output"

    status=$(echo "$wait_output" | grep -E 'status:' | tail -1 | awk '{print $2}')
    if [ "$status" != "Accepted" ]; then
        echo "❌ Notarization failed: ${status}"
        xcrun notarytool log "$submission_id" \
            --key "$key_file" \
            --key-id "$NOTARIZATION_KEY_ID" \
            --issuer "$NOTARIZATION_ISSUER_ID" 2>&1 || true
        rm -f "$key_file"
        exit 1
    fi

    rm -f "$key_file"
    echo "✅ Notarized"
    echo ""

    echo "📎 Stapling..."
    xcrun stapler staple "$dmg"
    echo "✅ Stapled"
    echo ""
}

build_macos() {
    local app_src dmg="${BASENAME}.dmg" icon_name
    rm -rf "${BINARIES}/app"
    gradle_tasks createDistributable

    app_src="${BINARIES}/app/${APP_NAME}.app"
    if [ ! -d "$app_src" ]; then
        echo "❌ Gradle did not produce ${app_src}"
        echo "   Check that nativeDistributions.packageName matches '${APP_NAME}'"
        exit 1
    fi
    APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
    ditto "$app_src" "$APP_PATH"
    echo "✅ Copied .app to ${APP_PATH}"
    echo ""

    # jpackage wrote a placeholder version when the major is zero, so the real one goes on with catapult.toml's keys.
    "$CATAPULT_PYTHON" "${SCRIPT_DIR}/render_plist.py" "$CATAPULT_CONFIG" \
        --kind direct --version "$VERSION" \
        --base "${APP_PATH}/Contents/Info.plist" \
        --out "${APP_PATH}/Contents/Info.plist"

    if [ -n "${CATAPULT_BUILD_ICON_ASSETS:-}" ]; then
        if [ ! -f "$CATAPULT_BUILD_ICON_ASSETS" ]; then
            echo "❌ build.icon_assets not found: ${CATAPULT_BUILD_ICON_ASSETS}"
            exit 1
        fi
        cp "$CATAPULT_BUILD_ICON_ASSETS" "${APP_PATH}/Contents/Resources/Assets.car"
    fi

    # CFBundleIconName looks inside Assets.car, and without one macOS silently falls back to the static .icns.
    icon_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" \
        "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)
    if [ -n "$icon_name" ] && [ ! -f "${APP_PATH}/Contents/Resources/Assets.car" ]; then
        echo "❌ Info.plist declares CFBundleIconName=${icon_name}, but the bundle has no Assets.car." >&2
        echo "   Set [build] icon_assets, or drop CFBundleIconName from [plist.extras]." >&2
        exit 1
    fi

    if [ -n "${APPLE_SIGNING_IDENTITY:-}" ]; then
        echo "🔏 Code signing with Developer ID..."
        sign_app "$APP_PATH"
        echo "✅ Signed"
    else
        echo "🔏 Ad-hoc signing (local build)..."
        # Deep, so the bundled runtime is signed too whether or not jpackage signed it.
        codesign --force --deep --sign - --entitlements "$CATAPULT_BUILD_ENTITLEMENTS_DIRECT" \
            "${APP_PATH}" || echo "⚠️  Code signing skipped"
    fi
    echo ""

    make_dmg "${DIST_DIR}/${dmg}"

    if [ -n "${APPLE_SIGNING_IDENTITY:-}" ]; then
        echo "🔏 Signing DMG..."
        codesign --force --sign "$APPLE_SIGNING_IDENTITY" "${DIST_DIR}/${dmg}"
        echo ""
    fi

    notarize "${DIST_DIR}/${dmg}"

    # After stapling, which modifies the DMG.
    echo "🔐 Generating checksum..."
    checksum "$dmg"
    echo ""
}

# signtool ships with the Windows SDK, which rarely puts it on PATH, so the newest x64 build is used.
find_signtool() {
    if command -v signtool >/dev/null 2>&1; then
        command -v signtool
    else
        ls "/c/Program Files (x86)/Windows Kits/10/bin/"*/x64/signtool.exe 2>/dev/null | sort -V | tail -1
    fi
}

sign_msi() {
    local msi="$1" signtool pfx_dir pfx
    echo "🔏 Signing MSI with Authenticode..."
    signtool="$(find_signtool)"
    if [ -z "$signtool" ]; then
        echo "❌ signtool not found. Install the Windows SDK or put signtool on PATH."
        exit 1
    fi
    pfx_dir="$(mktemp -d)"
    pfx="${pfx_dir}/certificate.pfx"
    echo "$WINDOWS_CERTIFICATE" | base64 --decode > "$pfx"
    # Git Bash would rewrite signtool's /flags as paths, so conversion is off and the paths are converted by hand.
    if ! MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$signtool" sign /fd sha256 \
        /f "$(cygpath -w "$pfx")" /p "$WINDOWS_CERTIFICATE_PASSWORD" \
        /tr http://timestamp.digicert.com /td sha256 \
        "$(cygpath -w "$msi")"; then
        rm -rf "$pfx_dir"
        echo "❌ signtool could not sign ${msi}"
        exit 1
    fi
    rm -rf "$pfx_dir"
    echo "✅ Signed"
    echo ""
}

build_windows() {
    local msi_src msi="${BASENAME}.msi"
    rm -rf "${BINARIES}/msi"
    gradle_tasks packageMsi

    msi_src="$(ls "${BINARIES}"/msi/*.msi 2>/dev/null | head -1)"
    if [ -z "$msi_src" ]; then
        echo "❌ Gradle produced no .msi in ${BINARIES}/msi"
        exit 1
    fi
    cp "$msi_src" "${DIST_DIR}/${msi}"
    echo "✅ Copied MSI to ${DIST_DIR}/${msi}"
    echo ""

    if [ -n "${WINDOWS_CERTIFICATE:-}" ] && [ -n "${WINDOWS_CERTIFICATE_PASSWORD:-}" ]; then
        sign_msi "${DIST_DIR}/${msi}"
    else
        echo "⚠️  Authenticode signing skipped (WINDOWS_CERTIFICATE not set)"
        echo ""
    fi

    echo "🔐 Generating checksum..."
    checksum "$msi"
    echo ""
}

# Cached between builds. CI has no FUSE, so the tool unpacks itself instead of mounting.
run_appimagetool() {
    local arch="${TARGET%%-*}" dir tool
    dir="${XDG_CACHE_HOME:-${HOME}/.cache}/catapult"
    tool="${dir}/appimagetool-${arch}.AppImage"
    if [ ! -x "$tool" ]; then
        echo "📥 Downloading appimagetool..."
        mkdir -p "$dir"
        curl -fsSL -o "${tool}.part" \
            "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${arch}.AppImage"
        chmod +x "${tool}.part"
        mv "${tool}.part" "$tool"
    fi
    ARCH="$arch" VERSION="$VERSION" APPIMAGE_EXTRACT_AND_RUN=1 "$tool" "$@"
}

build_linux() {
    local deb_src deb="${BASENAME}.deb" image appdir appimage="${BASENAME}.AppImage"
    rm -rf "${BINARIES}/deb" "${BINARIES}/app"
    gradle_tasks packageDeb createDistributable

    deb_src="$(ls "${BINARIES}"/deb/*.deb 2>/dev/null | head -1)"
    if [ -z "$deb_src" ]; then
        echo "❌ Gradle produced no .deb in ${BINARIES}/deb"
        exit 1
    fi
    cp "$deb_src" "${DIST_DIR}/${deb}"
    echo "✅ Copied DEB to ${DIST_DIR}/${deb}"
    echo ""

    image="${BINARIES}/app/${APP_NAME}"
    if [ ! -x "${image}/bin/${APP_NAME}" ]; then
        echo "❌ Gradle did not produce ${image}/bin/${APP_NAME}"
        echo "   Check that nativeDistributions.packageName matches '${APP_NAME}'"
        exit 1
    fi
    if [ ! -f "$CATAPULT_BUILD_LINUX_ICON" ]; then
        echo "❌ Linux icon not found: ${CATAPULT_BUILD_LINUX_ICON}"
        echo "   Set [build] linux_icon = \"path/to/icon.png\""
        exit 1
    fi

    echo "📦 Assembling AppDir..."
    appdir="${BUILD_DIR}/${APP_NAME}.AppDir"
    mkdir -p "$appdir"
    cp -a "${image}/." "$appdir/"
    cat > "${appdir}/AppRun" <<APPRUN
#!/bin/sh
HERE="\$(dirname "\$(readlink -f "\$0")")"
exec "\$HERE/bin/${APP_NAME}" "\$@"
APPRUN
    chmod +x "${appdir}/AppRun"
    cat > "${appdir}/${SLUG}.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=${APP_NAME}
Comment=${CATAPULT_APP_DESCRIPTION:-}
Exec=${APP_NAME}
Icon=${SLUG}
Categories=Development;
Terminal=false
DESKTOP
    cp "$CATAPULT_BUILD_LINUX_ICON" "${appdir}/${SLUG}.png"
    ln -sf "${SLUG}.png" "${appdir}/.DirIcon"
    echo "✅ AppDir ready"
    echo ""

    echo "📦 Building AppImage..."
    rm -f "${DIST_DIR}/${appimage}"
    run_appimagetool "$appdir" "${DIST_DIR}/${appimage}"
    echo "✅ AppImage created"
    echo ""

    echo "🔐 Generating checksums..."
    checksum "$deb"
    checksum "$appimage"
    echo ""
}

echo "🔨 Building ${APP_NAME} v${VERSION} (Compose, ${TARGET})"
echo ""

if [ ! -x ./gradlew ]; then
    echo "❌ ./gradlew not found at the app repo root"
    exit 1
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "${DIST_DIR}"

case "$CATAPULT_HOST_OS" in
    macos) build_macos ;;
    windows) build_windows ;;
    linux) build_linux ;;
    *) echo "❌ Compose desktop builds run on macOS, Windows or Linux (got $(uname -s))"; exit 1 ;;
esac

echo "✅ Build complete!"
ls -lh "${DIST_DIR}/${BASENAME}".* | awk '{print "  " $9 " (" $5 ")"}'
