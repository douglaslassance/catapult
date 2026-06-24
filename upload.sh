#!/bin/bash
# upload.sh — Upload DMG (+ Sparkle appcast + KV metadata) to S3-compatible storage.
# Requires [s3] section in catapult.toml.
#
# Usage: upload.sh [version]

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'
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

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")}"
APP_NAME="$CATAPULT_APP_NAME"
SLUG="$CATAPULT_APP_SLUG"
TARGET="$CATAPULT_BUILD_TARGET_TRIPLE"
DIST_DIR="$CATAPULT_DIST_DIR"
DMG_FILE="${SLUG}-${VERSION}-${TARGET}.dmg"

BUCKET_PREFIX="${CATAPULT_S3_BUCKET_PREFIX:-$SLUG}"
APPCAST_FILE_NAME="${CATAPULT_S3_APPCAST_FILENAME:-${SLUG}.xml}"
# Template uses {version} and {target} placeholders.
DOWNLOAD_URL_TEMPLATE="${CATAPULT_S3_DOWNLOAD_URL_TEMPLATE:?s3.download_url_template required}"

if [ ! -f "${DIST_DIR}/${DMG_FILE}" ]; then
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

echo "☁️  Uploading DMG..."
aws s3 cp \
    "${DIST_DIR}/${DMG_FILE}" \
    "s3://${S3_BUCKET_NAME}/${BUCKET_PREFIX}/${DMG_FILE}" \
    --endpoint-url "$R2_ENDPOINT"
echo "✅ DMG uploaded"
echo ""

IS_PRERELEASE=$(echo "$VERSION" | grep -qiE '(alpha|beta|rc|pre|dev)' && echo 1 || echo 0)

# Sparkle appcast
if [ -n "${CATAPULT_HAS_SPARKLE:-}" ]; then
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
            <sparkle:minimumSystemVersion>${CATAPULT_APP_MIN_MACOS}</sparkle:minimumSystemVersion>
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

# Tauri updater manifest — analogous to the Sparkle appcast above but for
# Tauri apps. Generates s3://${bucket}/${prefix}/${slug}.json in the format
# the `tauri-plugin-updater` plugin expects, and uploads the matching
# ${slug}-${version}-${target}.tar.gz bundle next to it. Read-modify-write
# so a second-target build for the same version adds an entry rather than
# wiping the first.
if [ "$CATAPULT_BUILD_KIND" = "tauri" ]; then
    if [ "$IS_PRERELEASE" = "1" ]; then
        echo "⚠️  Skipping Tauri manifest update (pre-release: $VERSION)"
        echo ""
    else
        UPDATER_TAR="${SLUG}-${VERSION}-${TARGET}.tar.gz"
        UPDATER_SIG_FILE="${DIST_DIR}/${UPDATER_TAR}.sig"
        TAURI_MANIFEST_NAME="${SLUG}.json"
        if [ ! -f "${DIST_DIR}/${UPDATER_TAR}" ] || [ ! -f "${UPDATER_SIG_FILE}" ]; then
            echo "⚠️  Updater artifacts not found in ${DIST_DIR} (${UPDATER_TAR}{,.sig})"
            echo "   — Tauri signing keys probably weren't set during build. Skipping."
            echo ""
        else
            echo "☁️  Uploading updater bundle..."
            aws s3 cp \
                "${DIST_DIR}/${UPDATER_TAR}" \
                "s3://${S3_BUCKET_NAME}/${BUCKET_PREFIX}/${UPDATER_TAR}" \
                --endpoint-url "$R2_ENDPOINT"
            echo "✅ ${UPDATER_TAR} uploaded"

            SIG_CONTENT=$(cat "$UPDATER_SIG_FILE")
            PUB_DATE_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            # Updater bundle URL goes straight to S3, not through the API
            # download route. The /download route assumes a single extension
            # per app (DMG for humans); the in-app updater needs the .tar.gz
            # and the two would collide on the same target key. Trade-off:
            # auto-update downloads aren't counted in /{app}/stats. If we
            # want them counted, add a separate /{app}/updater/{version}/{target}
            # endpoint to api.douglaslassance.me.
            DL_URL="${S3_PUBLIC_URL:-https://s3.douglaslassance.me}/${BUCKET_PREFIX}/${UPDATER_TAR}"
            # Tauri keys platforms by `darwin-aarch64` / `darwin-x86_64` rather
            # than the Rust triples we use everywhere else; translate so the
            # client's auto-detected platform string matches.
            case "$TARGET" in
                aarch64-apple-darwin) TAURI_TARGET="darwin-aarch64" ;;
                x86_64-apple-darwin)  TAURI_TARGET="darwin-x86_64" ;;
                *) TAURI_TARGET="$TARGET" ;;
            esac

            EXISTING=$(aws s3 cp \
                "s3://${S3_BUCKET_NAME}/${BUCKET_PREFIX}/${TAURI_MANIFEST_NAME}" - \
                --endpoint-url "$R2_ENDPOINT" 2>/dev/null || true)

            MANIFEST_FILE=$(mktemp /tmp/tauri_manifest_XXXXXX.json)
            python3 - "$VERSION" "$PUB_DATE_ISO" "$TAURI_TARGET" "$SIG_CONTENT" "$DL_URL" "$EXISTING" > "$MANIFEST_FILE" <<'PYEOF'
import json, sys
version, pub_date, target, sig, url, existing = sys.argv[1:7]
try:
    manifest = json.loads(existing) if existing else {}
except Exception:
    manifest = {}
# A new version invalidates the previous platforms map — never serve a
# mixed-version manifest. Same version → merge in the new target.
if manifest.get('version') != version:
    manifest = {'version': version, 'platforms': {}}
manifest['pub_date'] = pub_date
manifest.setdefault('notes', '')
manifest.setdefault('platforms', {})
manifest['platforms'][target] = {'signature': sig, 'url': url}
print(json.dumps(manifest, indent=2))
PYEOF

            echo "☁️  Uploading ${TAURI_MANIFEST_NAME}..."
            aws s3 cp "$MANIFEST_FILE" \
                "s3://${S3_BUCKET_NAME}/${BUCKET_PREFIX}/${TAURI_MANIFEST_NAME}" \
                --content-type "application/json" \
                --endpoint-url "$R2_ENDPOINT"
            rm -f "$MANIFEST_FILE"
            echo "✅ ${TAURI_MANIFEST_NAME} updated"

            # Public ACL on both — the in-app updater has no R2 creds.
            aws s3api put-object-acl \
                --bucket "$S3_BUCKET_NAME" \
                --key "${BUCKET_PREFIX}/${UPDATER_TAR}" \
                --acl public-read \
                --endpoint-url "$R2_ENDPOINT" 2>/dev/null || true
            aws s3api put-object-acl \
                --bucket "$S3_BUCKET_NAME" \
                --key "${BUCKET_PREFIX}/${TAURI_MANIFEST_NAME}" \
                --acl public-read \
                --endpoint-url "$R2_ENDPOINT" 2>/dev/null || true

            if [ -n "${CLOUDFLARE_API_TOKEN:-}" ] && [ -n "${CLOUDFLARE_ZONE_ID:-}" ] && [ -n "${S3_PUBLIC_URL:-}" ]; then
                PURGE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/purge_cache" \
                    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
                    -H "Content-Type: application/json" \
                    --data "{\"files\":[\"${S3_PUBLIC_URL}/${BUCKET_PREFIX}/${TAURI_MANIFEST_NAME}\"]}")
                echo "$PURGE" | grep -q '"success":true' && echo "✅ Manifest cache purged" || echo "⚠️  Manifest cache purge failed"
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
    KV_KEY="${CATAPULT_S3_KV_KEY:-$SLUG}"
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
