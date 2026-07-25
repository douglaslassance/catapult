#!/bin/bash
# upload_ios.sh — Upload the exported iOS .ipa to App Store Connect (TestFlight).
#
# Auth uses the App Store Connect API key — the same NOTARIZATION_KEY /
# NOTARIZATION_KEY_ID / NOTARIZATION_ISSUER_ID that catapult uses for macOS
# notarization and upload. One key works across all your apps.
#
# Usage: upload_ios.sh [version]

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

cd "$CATAPULT_APP_ROOT"

EXPORT_DIR="${CATAPULT_BUILD_DIR}/export"
IPA="$(ls "$EXPORT_DIR"/*.ipa 2>/dev/null | head -1)"
if [ -z "$IPA" ]; then
    echo "❌ No .ipa found in ${EXPORT_DIR}. Run build_ios.sh first." >&2
    exit 1
fi

missing=()
[ -z "${NOTARIZATION_KEY_ID:-}" ] && missing+=("NOTARIZATION_KEY_ID")
[ -z "${NOTARIZATION_ISSUER_ID:-}" ] && missing+=("NOTARIZATION_ISSUER_ID")
if (( ${#missing[@]} )); then
    echo "❌ Missing env vars: ${missing[*]}" >&2
    echo "   (Or drag ${IPA} into Transporter manually.)" >&2
    exit 1
fi

# Install the API key where altool looks for it, if provided as base64.
KEYDIR="${HOME}/.appstoreconnect/private_keys"
KEYFILE="${KEYDIR}/AuthKey_${NOTARIZATION_KEY_ID}.p8"
if [ -n "${NOTARIZATION_KEY:-}" ]; then
    mkdir -p "$KEYDIR"
    echo "$NOTARIZATION_KEY" | base64 --decode > "$KEYFILE"
fi

echo "🚀 Uploading ${CATAPULT_APP_NAME} to App Store Connect (TestFlight)…"
echo ""

xcrun altool --upload-app \
    -t ios \
    -f "$IPA" \
    --apiKey "$NOTARIZATION_KEY_ID" \
    --apiIssuer "$NOTARIZATION_ISSUER_ID" \
    --show-progress

echo ""
echo "✅ Uploaded. It appears in TestFlight after processing (usually 5–15 min)."
echo "   Assign testers at https://appstoreconnect.apple.com."
