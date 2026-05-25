#!/bin/bash
# upload-appstore.sh — Upload .pkg to App Store Connect.
# Usage: upload-appstore.sh [version]

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/config.sh"

cd "$TRIGGER_APP_ROOT"

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")}"
SLUG="$TRIGGER_APP_SLUG"
DIST_DIR="$TRIGGER_DIST_DIR"
PKG_NAME="${SLUG}-${VERSION}.pkg"

if [ ! -f "${DIST_DIR}/${PKG_NAME}" ]; then
    echo "❌ Package not found: ${DIST_DIR}/${PKG_NAME}"
    echo "Run build-appstore.sh ${VERSION} first"
    exit 1
fi

missing=()
[[ -z ${NOTARIZATION_KEY_ID:-} ]] && missing+=("NOTARIZATION_KEY_ID")
[[ -z ${NOTARIZATION_ISSUER_ID:-} ]] && missing+=("NOTARIZATION_ISSUER_ID")
[[ -z ${NOTARIZATION_KEY:-} ]] && missing+=("NOTARIZATION_KEY")
if (( ${#missing[@]} )); then
    echo "❌ Missing env vars: ${missing[*]}"
    echo "   (Or drag ${DIST_DIR}/${PKG_NAME} into Transporter manually.)"
    exit 1
fi

echo "🚀 Uploading ${TRIGGER_APP_NAME} v${VERSION} to App Store Connect..."
echo ""

PRIVATE_KEYS_DIR="$HOME/.appstoreconnect/private_keys"
mkdir -p "$PRIVATE_KEYS_DIR"
NOTARIZATION_KEY_FILE="${PRIVATE_KEYS_DIR}/AuthKey_${NOTARIZATION_KEY_ID}.p8"
echo "$NOTARIZATION_KEY" | base64 --decode > "$NOTARIZATION_KEY_FILE"

xcrun altool --upload-app \
    -f "${DIST_DIR}/${PKG_NAME}" \
    -t macos \
    --apiKey "$NOTARIZATION_KEY_ID" \
    --apiIssuer "$NOTARIZATION_ISSUER_ID" \
    --show-progress 2>&1

rm -f "$NOTARIZATION_KEY_FILE"

echo ""
echo "✅ Uploaded to App Store Connect!"
echo "   Visit https://appstoreconnect.apple.com to submit for review."
