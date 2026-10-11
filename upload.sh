#!/bin/bash
# upload.sh - Upload DMG (+ Sparkle appcast) to S3-compatible storage, then record the release.
# Desktop builds (Compose or Tauri) upload every artifact their host produced (.dmg, .msi, .deb, .AppImage).
# Requires [s3] section in catapult.toml.
#
# Usage: upload.sh [version]

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

if [ -z "${CATAPULT_HAS_S3:-}" ]; then
    echo "❌ [s3] section missing from catapult.toml"
    exit 1
fi

cd "$CATAPULT_APP_ROOT"

VERSION="$(catapult_version "${1:-}" 0.0.0)"
APP_NAME="$CATAPULT_APP_NAME"
SLUG="$CATAPULT_APP_SLUG"
TARGET="$CATAPULT_BUILD_TARGET_TRIPLE"
DIST_DIR="$CATAPULT_DIST_DIR"
BASENAME="${SLUG}-${VERSION}-${TARGET}"
DMG_FILE="${BASENAME}.dmg"
ARTIFACTS=("$DMG_FILE")
RELEASE_EXTENSION=".dmg"

BUCKET_PREFIX="${CATAPULT_S3_BUCKET_PREFIX:-$SLUG}"
APPCAST_FILE_NAME="${CATAPULT_S3_APPCAST_FILENAME:-${SLUG}.xml}"
# Template uses {version} and {target} placeholders.
DOWNLOAD_URL_TEMPLATE="${CATAPULT_S3_DOWNLOAD_URL_TEMPLATE:?s3.download_url_template required}"

# A desktop build uploads whatever this host built, and its release records the artifact people download here.
if [ "$CATAPULT_BUILD_PLATFORM" = "desktop" ]; then
    case "$CATAPULT_HOST_OS" in
        windows) RELEASE_EXTENSION=".msi" ;;
        linux) RELEASE_EXTENSION=".AppImage" ;;
    esac
    if [ ! -f "${DIST_DIR}/${SLUG}-${VERSION}-${TARGET}${RELEASE_EXTENSION}" ]; then
        echo "❌ ${DIST_DIR}/${SLUG}-${VERSION}-${TARGET}${RELEASE_EXTENSION} not found. Run build.sh first."
        exit 1
    fi
    ARTIFACTS=()
    for EXT in dmg msi deb AppImage; do
        if [ -f "${DIST_DIR}/${SLUG}-${VERSION}-${TARGET}.${EXT}" ]; then
            ARTIFACTS+=("${SLUG}-${VERSION}-${TARGET}.${EXT}")
        fi
    done
fi

if [ "$CATAPULT_BUILD_PLATFORM" != "desktop" ] && [ ! -f "${DIST_DIR}/${DMG_FILE}" ]; then
    echo "❌ ${DIST_DIR}/${DMG_FILE} not found — run build.sh first"
    exit 1
fi

echo "📤 Uploading ${APP_NAME} v${VERSION} to S3..."
echo ""

missing=()
[[ -z ${S3_ACCOUNT_ID:-} ]] && missing+=("S3_ACCOUNT_ID")
[[ -z ${S3_ACCESS_KEY_ID:-} ]] && missing+=("S3_ACCESS_KEY_ID")
[[ -z ${S3_SECRET_ACCESS_KEY:-} ]] && missing+=("S3_SECRET_ACCESS_KEY")
[[ -z ${S3_BUCKET_NAME:-} ]] && missing+=("S3_BUCKET_NAME")
if (( ${#missing[@]} )); then
    echo "❌ Missing env vars: ${missing[*]}"
    exit 1
fi

if ! command -v aws &> /dev/null; then
    echo "📦 Installing AWS CLI..."
    brew install awscli
fi

aws configure set aws_access_key_id "$S3_ACCESS_KEY_ID"
aws configure set aws_secret_access_key "$S3_SECRET_ACCESS_KEY"
aws configure set region auto

R2_ENDPOINT="https://${S3_ACCOUNT_ID}.r2.cloudflarestorage.com"

for FILE in "${ARTIFACTS[@]}"; do
    case "$CATAPULT_BUILD_PLATFORM" in
        desktop) LABEL="$FILE" ;;
        *) LABEL="DMG" ;;
    esac
    echo "☁️  Uploading ${LABEL}..."
    aws s3 cp \
        "${DIST_DIR}/${FILE}" \
        "s3://${S3_BUCKET_NAME}/${BUCKET_PREFIX}/${FILE}" \
        --endpoint-url "$R2_ENDPOINT"
    echo "✅ ${LABEL} uploaded"
    echo ""
done

IS_PRERELEASE=$(echo "$VERSION" | grep -qiE '(alpha|beta|rc|pre|dev)' && echo 1 || echo 0)

# Sparkle appcast, which Compose builds never embed. Sparkle's generate_appcast
# signs the DMG and reads the version and minimum macOS from the app inside it.
if [ -n "${CATAPULT_HAS_SPARKLE:-}" ] && [ "$CATAPULT_BUILD_KIND" != "compose" ]; then
    GENERATE_APPCAST=$(find .build/artifacts -type f -name generate_appcast 2>/dev/null | head -1)
    if [ "$IS_PRERELEASE" = "1" ]; then
        echo "⚠️  Skipping appcast update (pre-release: $VERSION)"
        echo ""
    elif [ -z "$GENERATE_APPCAST" ]; then
        echo "⚠️  generate_appcast not found, run 'swift package resolve' first. Skipping appcast"
        echo ""
    else
        APPCAST_DIR=$(mktemp -d /tmp/appcast_XXXXXX)
        APPCAST_FILE="${APPCAST_DIR}/${APPCAST_FILE_NAME}"
        cp "${DIST_DIR}/${DMG_FILE}" "$APPCAST_DIR/"

        # Starting from the published feed keeps its earlier items, unless it no longer parses.
        if aws s3 cp "s3://${S3_BUCKET_NAME}/${BUCKET_PREFIX}/${APPCAST_FILE_NAME}" "$APPCAST_FILE" \
            --endpoint-url "$R2_ENDPOINT" >/dev/null 2>&1; then
            if ! "$CATAPULT_PYTHON" -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$APPCAST_FILE" 2>/dev/null; then
                echo "⚠️  The published ${APPCAST_FILE_NAME} is not valid XML; starting a new one"
                rm -f "$APPCAST_FILE"
            fi
        else
            rm -f "$APPCAST_FILE"
        fi

        SPARKLE_KEY_FILE=""
        KEY_ARGS=()
        if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
            SPARKLE_KEY_FILE=$(mktemp /tmp/sparkle_key_XXXXXX)
            echo "$SPARKLE_PRIVATE_KEY" | base64 --decode >"$SPARKLE_KEY_FILE"
            KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
        elif [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
            KEY_ARGS=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
        fi

        # generate_appcast only knows prefix + filename URLs, so a placeholder prefix is swapped for the templated URL after.
        PLACEHOLDER_URL="https://catapult.invalid/${DMG_FILE}"
        echo "✍️  Generating ${APPCAST_FILE_NAME}..."
        if ! "$GENERATE_APPCAST" "${KEY_ARGS[@]}" \
            --download-url-prefix "https://catapult.invalid/" \
            --maximum-deltas 0 \
            -o "$APPCAST_FILE" \
            "$APPCAST_DIR"; then
            [ -n "$SPARKLE_KEY_FILE" ] && rm -f "$SPARKLE_KEY_FILE"
            rm -rf "$APPCAST_DIR"
            echo "❌ generate_appcast failed"
            exit 1
        fi
        [ -n "$SPARKLE_KEY_FILE" ] && rm -f "$SPARKLE_KEY_FILE"

        DOWNLOAD_URL="${DOWNLOAD_URL_TEMPLATE//\{version\}/$VERSION}"
        DOWNLOAD_URL="${DOWNLOAD_URL//\{target\}/$TARGET}"
        "$CATAPULT_PYTHON" -c '
import sys
from xml.sax.saxutils import escape
path, placeholder, url = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    feed = f.read()
if placeholder not in feed:
    sys.exit("catapult: generate_appcast wrote no enclosure for " + placeholder)
feed = feed.replace(placeholder, escape(url, {"\"": "&quot;"}))
if "catapult.invalid" in feed:
    sys.exit("catapult: the appcast still points at catapult.invalid")
with open(path, "w", encoding="utf-8") as f:
    f.write(feed)
' "$APPCAST_FILE" "$PLACEHOLDER_URL" "$DOWNLOAD_URL"

        echo "☁️  Uploading ${APPCAST_FILE_NAME}..."
        aws s3 cp "$APPCAST_FILE" \
            "s3://${S3_BUCKET_NAME}/${BUCKET_PREFIX}/${APPCAST_FILE_NAME}" \
            --content-type "application/xml" \
            --endpoint-url "$R2_ENDPOINT"
        rm -rf "$APPCAST_DIR"
        echo "✅ ${APPCAST_FILE_NAME} updated"

        if [ -n "${CLOUDFLARE_API_TOKEN:-}" ] && [ -n "${CLOUDFLARE_ZONE_ID:-}" ] && [ -n "${S3_PUBLIC_URL:-}" ]; then
            PURGE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/purge_cache" \
                -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
                -H "Content-Type: application/json" \
                --data "{\"files\":[\"${S3_PUBLIC_URL}/${BUCKET_PREFIX}/${APPCAST_FILE_NAME}\"]}")
            echo "$PURGE" | grep -q '"success":true' && echo "✅ Appcast cache purged" || echo "⚠️  Appcast cache purge failed"
        fi
        echo ""
    fi
fi

# Tauri updater. Each host uploads the bundles it signed and writes a fragment,
# dist/${slug}-${version}-${target}.updater.json, holding its entries of the
# manifest tauri-plugin-updater reads. upload_manifest.sh merges fragments into
# ${slug}.json, here for this host alone, or once for every host when CI sets
# CATAPULT_DEFER_UPDATER_MANIFEST because the hosts build in parallel.
if [ "$CATAPULT_BUILD_KIND" = "tauri" ]; then
    if [ "$IS_PRERELEASE" = "1" ]; then
        echo "⚠️  Skipping Tauri updater (pre-release: $VERSION)"
        echo ""
    else
        # Tauri names platforms <os>-<arch> after its own OS names, and an installer suffix picks a bundle by how the app was installed.
        case "$TARGET" in
            *-apple-darwin) TAURI_OS=darwin ;;
            *-windows-*) TAURI_OS=windows ;;
            *-linux-*) TAURI_OS=linux ;;
            *) echo "❌ No Tauri updater platform for ${TARGET}"; exit 1 ;;
        esac
        TAURI_PLATFORM="${TAURI_OS}-${TARGET%%-*}"
        UPDATER_FRAGMENT="${DIST_DIR}/${BASENAME}.updater.json"
        UPDATER_ENTRIES=""
        UPDATER_UPLOADS=()
        for BUNDLE in "tar.gz:" "msi:" "AppImage:" "deb:-deb"; do
            FILE="${BASENAME}.${BUNDLE%%:*}"
            [ -f "${DIST_DIR}/${FILE}.sig" ] || continue
            # Straight to the bucket, since the API's download route serves one extension per target.
            UPDATER_ENTRIES+="${TAURI_PLATFORM}${BUNDLE#*:}"$'\t'"${S3_PUBLIC_URL}/${BUCKET_PREFIX}/${FILE}"$'\t'"$(tr -d '\r\n' < "${DIST_DIR}/${FILE}.sig")"$'\n'
            if [[ " ${ARTIFACTS[*]} " != *" ${FILE} "* ]]; then
                UPDATER_UPLOADS+=("$FILE")
            fi
        done

        if [ -z "$UPDATER_ENTRIES" ]; then
            echo "⚠️  No updater signatures in ${DIST_DIR} for ${BASENAME}"
            echo "   Tauri signing keys probably weren't set during build. Skipping."
            echo ""
        elif [ -z "${S3_PUBLIC_URL:-}" ]; then
            echo "❌ S3_PUBLIC_URL is required to publish the Tauri updater manifest"
            exit 1
        else
            for FILE in "${UPDATER_UPLOADS[@]}"; do
                echo "☁️  Uploading updater bundle ${FILE}..."
                aws s3 cp \
                    "${DIST_DIR}/${FILE}" \
                    "s3://${S3_BUCKET_NAME}/${BUCKET_PREFIX}/${FILE}" \
                    --endpoint-url "$R2_ENDPOINT"
                # Public, as the in-app updater has no R2 credentials.
                aws s3api put-object-acl \
                    --bucket "$S3_BUCKET_NAME" \
                    --key "${BUCKET_PREFIX}/${FILE}" \
                    --acl public-read \
                    --endpoint-url "$R2_ENDPOINT" 2>/dev/null || true
                echo "✅ ${FILE} uploaded"
            done

            # Entries go through stdin, which Git Bash leaves alone where it would rewrite paths and URLs in arguments.
            printf '%s' "$UPDATER_ENTRIES" | "$CATAPULT_PYTHON" -c '
import json, sys
platforms = {}
for line in sys.stdin.read().splitlines():
    key, url, signature = line.split("\t")
    platforms[key] = {"signature": signature, "url": url}
print(json.dumps({"version": sys.argv[1], "platforms": platforms}, indent=2))
' "$VERSION" > "$UPDATER_FRAGMENT"
            echo "✅ ${UPDATER_FRAGMENT##*/} written"
            echo ""

            if [ -n "${CATAPULT_DEFER_UPDATER_MANIFEST:-}" ]; then
                echo "ℹ️  Leaving ${SLUG}.json to the job that merges every host's fragment"
                echo ""
            else
                "${SCRIPT_DIR}/upload_manifest.sh" "$VERSION" "${UPDATER_FRAGMENT#"${CATAPULT_APP_ROOT}/"}"
            fi
        fi
    fi
fi

# Release record (drives Homebrew livecheck)
if [ "$IS_PRERELEASE" = "1" ]; then
    echo "⚠️  Skipping release record (pre-release: $VERSION)"
    echo ""
elif [ -z "${RELEASE_API_TOKEN:-}" ] || [ -z "${RELEASE_API_URL:-}" ]; then
    echo "⚠️  Skipping release record (RELEASE_API_TOKEN or RELEASE_API_URL not set)"
    echo ""
elif [ "$CATAPULT_BUILD_PLATFORM" = "desktop" ] && [ "$CATAPULT_HOST_OS" != "macos" ]; then
    # The API keeps the extension the first record of a version sends, so only the Mac leg records and the cask keeps its .dmg.
    echo "ℹ️  Skipping release record (the macOS build records it)"
    echo ""
else
    # The API owns the version comparison, so re-running an older release cannot
    # walk `latest` backwards no matter what this script is invoked with.
    echo "☁️  Recording release..."
    # The download route serves Windows and Linux targets through the product's per-target extension overrides.
    RELEASE_BODY=$(printf '{"version":"%s","extension":"%s"}' "$VERSION" "$RELEASE_EXTENSION")
    RELEASE_RESULT=$(curl -s -X PUT "${RELEASE_API_URL%/}/${SLUG}/release" \
        -H "Authorization: Bearer ${RELEASE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$RELEASE_BODY")

    if echo "$RELEASE_RESULT" | grep -q '"updated":true'; then
        echo "✅ Release recorded (latest is now $VERSION)"
    elif echo "$RELEASE_RESULT" | grep -q '"updated":false'; then
        echo "⚠️  Skipping release record ($VERSION is not newer than current)"
    else
        echo "❌ Release record failed: $RELEASE_RESULT"
        exit 1
    fi
    echo ""
fi

echo "🔓 Setting public access..."
for FILE in "${ARTIFACTS[@]}"; do
    aws s3api put-object-acl \
        --bucket "$S3_BUCKET_NAME" \
        --key "${BUCKET_PREFIX}/${FILE}" \
        --acl public-read \
        --endpoint-url "$R2_ENDPOINT" 2>/dev/null || echo "⚠️  Could not set ACL (may be disabled on bucket)"
done
echo ""

if [ -n "${CLOUDFLARE_API_TOKEN:-}" ] && [ -n "${CLOUDFLARE_ZONE_ID:-}" ] && [ -n "${S3_PUBLIC_URL:-}" ]; then
    echo "🧹 Purging Cloudflare cache..."
    PURGE_FILES=""
    for FILE in "${ARTIFACTS[@]}"; do
        PURGE_FILES="${PURGE_FILES:+${PURGE_FILES},}\"${S3_PUBLIC_URL}/${BUCKET_PREFIX}/${FILE}\""
    done
    PURGE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/purge_cache" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"files\":[${PURGE_FILES}]}")
    echo "$PURGE" | grep -q '"success":true' && echo "✅ Cache purged" || echo "⚠️  Cache purge failed"
    echo ""
fi

DOWNLOAD_URL="${DOWNLOAD_URL_TEMPLATE//\{version\}/$VERSION}"
DOWNLOAD_URL="${DOWNLOAD_URL//\{target\}/$TARGET}"
echo "✅ Upload complete!"
if [ "$CATAPULT_BUILD_PLATFORM" = "desktop" ]; then
    echo "📦 Download: ${DOWNLOAD_URL}"
else
    echo "📦 DMG: ${DOWNLOAD_URL}"
fi
