#!/bin/bash
# upload_manifest.sh publishes the Tauri updater manifest, ${slug}.json, next to
# the bundles in S3-compatible storage. It merges the fragments upload.sh writes
# (dist/${slug}-${version}-${target}.updater.json) into the manifest already
# there: platforms of the same version are kept, so hosts can publish one after
# another, and a new version starts over so no manifest mixes versions.
# upload.sh runs it for its own host. CI runs it once for every host's fragment.
#
# Usage: upload_manifest.sh <version> <fragment.json>...

if [[ "$1" == "-h" || "$1" == "--help" || $# -lt 1 ]]; then
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
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

VERSION="$1"
shift
FRAGMENTS=("$@")
SLUG="$CATAPULT_APP_SLUG"
BUCKET_PREFIX="${CATAPULT_S3_BUCKET_PREFIX:-$SLUG}"
MANIFEST_NAME="${SLUG}.json"

if echo "$VERSION" | grep -qiE '(alpha|beta|rc|pre|dev)'; then
    echo "⚠️  Skipping ${MANIFEST_NAME} (pre-release: $VERSION)"
    exit 0
fi
if (( ${#FRAGMENTS[@]} == 0 )); then
    echo "ℹ️  No updater fragments for ${VERSION}; ${MANIFEST_NAME} left as is"
    exit 0
fi

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
MANIFEST_KEY="${BUCKET_PREFIX}/${MANIFEST_NAME}"
MANIFEST_FILE="${CATAPULT_DIST_DIR}/${MANIFEST_NAME}"
mkdir -p "$CATAPULT_DIST_DIR"

echo "🧩 Merging ${#FRAGMENTS[@]} updater fragment(s) into ${MANIFEST_NAME}..."
aws s3 cp "s3://${S3_BUCKET_NAME}/${MANIFEST_KEY}" - --endpoint-url "$R2_ENDPOINT" 2>/dev/null | \
    "$CATAPULT_PYTHON" -c '
import json, sys
version, pub_date, *fragments = sys.argv[1:]
try:
    manifest = json.loads(sys.stdin.read() or "{}")
except ValueError:
    manifest = {}
if manifest.get("version") != version:
    manifest = {"version": version, "platforms": {}}
manifest["pub_date"] = pub_date
manifest.setdefault("notes", "")
manifest.setdefault("platforms", {})
for path in fragments:
    with open(path) as f:
        fragment = json.load(f)
    if fragment.get("version") != version:
        sys.exit("catapult: %s is for version %s, not %s" % (path, fragment.get("version"), version))
    manifest["platforms"].update(fragment["platforms"])
print(json.dumps(manifest, indent=2))
' "$VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${FRAGMENTS[@]}" > "$MANIFEST_FILE"
"$CATAPULT_PYTHON" -c 'import json, sys; print("   " + ", ".join(sorted(json.load(sys.stdin)["platforms"])))' < "$MANIFEST_FILE"

echo "☁️  Uploading ${MANIFEST_NAME}..."
aws s3 cp "$MANIFEST_FILE" \
    "s3://${S3_BUCKET_NAME}/${MANIFEST_KEY}" \
    --content-type "application/json" \
    --endpoint-url "$R2_ENDPOINT"
# Public, as the in-app updater has no R2 credentials.
aws s3api put-object-acl \
    --bucket "$S3_BUCKET_NAME" \
    --key "$MANIFEST_KEY" \
    --acl public-read \
    --endpoint-url "$R2_ENDPOINT" 2>/dev/null || true
echo "✅ ${MANIFEST_NAME} updated"

if [ -n "${CLOUDFLARE_API_TOKEN:-}" ] && [ -n "${CLOUDFLARE_ZONE_ID:-}" ] && [ -n "${S3_PUBLIC_URL:-}" ]; then
    PURGE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/purge_cache" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"files\":[\"${S3_PUBLIC_URL}/${MANIFEST_KEY}\"]}")
    echo "$PURGE" | grep -q '"success":true' && echo "✅ Manifest cache purged" || echo "⚠️  Manifest cache purge failed"
fi
echo ""
