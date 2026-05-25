#!/bin/bash
# upload.sh — Upload DMG (+ Sparkle appcast + KV metadata) to Cloudflare R2.
# Requires [r2] section in trigger.toml.
#
# Usage: upload.sh [version]

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/config.sh"

if [ -z "${TRIGGER_HAS_R2:-}" ]; then
    echo "❌ [r2] section missing from trigger.toml"
    exit 1
fi

cd "$TRIGGER_APP_ROOT"

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")}"
APP_NAME="$TRIGGER_APP_NAME"
SLUG="$TRIGGER_APP_SLUG"
TARGET="$TRIGGER_BUILD_TARGET_TRIPLE"
DIST_DIR="$TRIGGER_DIST_DIR"
DMG_FILE="${SLUG}-${VERSION}-${TARGET}.dmg"

BUCKET_PREFIX="${TRIGGER_R2_BUCKET_PREFIX:-$SLUG}"
APPCAST_FILE_NAME="${TRIGGER_R2_APPCAST_FILENAME:-${SLUG}.xml}"
# Template uses {version} and {target} placeholders.
DOWNLOAD_URL_TEMPLATE="${TRIGGER_R2_DOWNLOAD_URL_TEMPLATE:?r2.download_url_template required}"

if [ ! -f "${DIST_DIR}/${DMG_FILE}" ]; then
    echo "❌ ${DIST_DIR}/${DMG_FILE} not found — run build.sh first"
    exit 1
fi

echo "📤 Uploading ${APP_NAME} v${VERSION} to R2..."
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

echo "☁️  Uploading DMG..."
aws s3 cp \
    "${DIST_DIR}/${DMG_FILE}" \
    "s3://${S3_BUCKET_NAME}/${BUCKET_PREFIX}/${DMG_FILE}" \
    --endpoint-url "$R2_ENDPOINT"
echo "✅ DMG uploaded"
echo ""

IS_PRERELEASE=$(echo "$VERSION" | grep -qiE '(alpha|beta|rc|pre|dev)' && echo 1 || echo 0)

# Sparkle appcast
if [ -n "${TRIGGER_HAS_SPARKLE:-}" ]; then
    if [ "$IS_PRERELEASE" = "1" ]; then
        echo "⚠️  Skipping appcast update (pre-release: $VERSION)"
        echo ""
    else
        EDSIG_FILE="${DIST_DIR}/${DMG_FILE}.edsig"
        if [ ! -f "$EDSIG_FILE" ]; then
            echo "⚠️  Sparkle signature not found (${EDSIG_FILE}) — run build.sh first, skipping appcast"
            echo ""
        else
            ED_SIG=$(cat "$EDSIG_FILE")
            DMG_SIZE=$(stat -f%z "${DIST_DIR}/${DMG_FILE}")
            PUB_DATE=$(date -R)
            DOWNLOAD_URL="${DOWNLOAD_URL_TEMPLATE//\{version\}/$VERSION}"
            DOWNLOAD_URL="${DOWNLOAD_URL//\{target\}/$TARGET}"
            APPCAST_FILE=$(mktemp /tmp/appcast_XXXXXX.xml)
            cat > "$APPCAST_FILE" <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>${APP_NAME}</title>
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:minimumSystemVersion>${TRIGGER_APP_MIN_MACOS}</sparkle:minimumSystemVersion>
            <enclosure
                url="${DOWNLOAD_URL}"
                sparkle:edSignature="${ED_SIG}"
                length="${DMG_SIZE}"
                type="application/octet-stream"/>
        </item>
    </channel>
</rss>
APPCAST

            echo "☁️  Uploading ${APPCAST_FILE_NAME}..."
            aws s3 cp "$APPCAST_FILE" \
                "s3://${S3_BUCKET_NAME}/${BUCKET_PREFIX}/${APPCAST_FILE_NAME}" \
                --content-type "application/xml" \
                --endpoint-url "$R2_ENDPOINT"
            rm -f "$APPCAST_FILE"
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
fi

# KV metadata (drives Homebrew livecheck)
if [ "$IS_PRERELEASE" = "1" ]; then
    echo "⚠️  Skipping KV update (pre-release: $VERSION)"
    echo ""
elif [ -z "${CLOUDFLARE_API_TOKEN:-}" ] || [ -z "${S3_ACCOUNT_ID:-}" ] || [ -z "${CLOUDFLARE_KV_NAMESPACE_ID:-}" ]; then
    echo "⚠️  Skipping KV update (CLOUDFLARE_API_TOKEN, S3_ACCOUNT_ID, or CLOUDFLARE_KV_NAMESPACE_ID not set)"
    echo ""
else
    KV_KEY="${TRIGGER_R2_KV_KEY:-$SLUG}"
    KV_URL="https://api.cloudflare.com/client/v4/accounts/${S3_ACCOUNT_ID}/storage/kv/namespaces/${CLOUDFLARE_KV_NAMESPACE_ID}/values/${KV_KEY}"

    CURRENT_KV=$(curl -s -X GET "$KV_URL" -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" 2>/dev/null)
    CURRENT_LATEST=$(echo "$CURRENT_KV" | grep -o '"latest":"[^"]*"' | cut -d'"' -f4)

    HIGHER=$(printf '%s\n' "$CURRENT_LATEST" "$VERSION" | sort -V | tail -1)
    if [ -z "$CURRENT_LATEST" ] || { [ "$HIGHER" = "$VERSION" ] && [ "$CURRENT_LATEST" != "$VERSION" ]; }; then
        EXISTING_DOWNLOADS=$(echo "$CURRENT_KV" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(json.dumps(d.get('downloads', {})))
except Exception:
    print('{}')
")
        NEW_VALUE=$(python3 -c "
import json, sys
data = {
    'latest': '${VERSION}',
    'downloads': json.loads(sys.argv[1]),
    'extension': '.dmg',
}
print(json.dumps(data))
" "$EXISTING_DOWNLOADS")

        echo "☁️  Updating KV metadata..."
        KV_RESULT=$(curl -s -X PUT "$KV_URL" \
            -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "$NEW_VALUE")
        if echo "$KV_RESULT" | grep -q '"success":true'; then
            echo "✅ KV updated ($CURRENT_LATEST → $VERSION)"
        else
            echo "❌ KV update failed: $KV_RESULT"
            exit 1
        fi
    else
        echo "⚠️  Skipping KV update ($VERSION is not newer than current $CURRENT_LATEST)"
    fi
    echo ""
fi

echo "🔓 Setting public access..."
aws s3api put-object-acl \
    --bucket "$S3_BUCKET_NAME" \
    --key "${BUCKET_PREFIX}/${DMG_FILE}" \
    --acl public-read \
    --endpoint-url "$R2_ENDPOINT" 2>/dev/null || echo "⚠️  Could not set ACL (may be disabled on bucket)"
echo ""

if [ -n "${CLOUDFLARE_API_TOKEN:-}" ] && [ -n "${CLOUDFLARE_ZONE_ID:-}" ] && [ -n "${S3_PUBLIC_URL:-}" ]; then
    echo "🧹 Purging Cloudflare cache..."
    PURGE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/purge_cache" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"files\":[\"${S3_PUBLIC_URL}/${BUCKET_PREFIX}/${DMG_FILE}\"]}")
    echo "$PURGE" | grep -q '"success":true' && echo "✅ Cache purged" || echo "⚠️  Cache purge failed"
    echo ""
fi

DOWNLOAD_URL="${DOWNLOAD_URL_TEMPLATE//\{version\}/$VERSION}"
DOWNLOAD_URL="${DOWNLOAD_URL//\{target\}/$TARGET}"
echo "✅ Upload complete!"
echo "📦 DMG: ${DOWNLOAD_URL}"
