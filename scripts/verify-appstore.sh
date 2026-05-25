#!/bin/bash
# verify-appstore.sh — Sanity-check the Mac App Store build before upload.

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: verify-appstore.sh"
    exit 0
fi

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/config.sh"

cd "$CATAPULT_APP_ROOT"

APP_NAME="$CATAPULT_APP_NAME"
TEAM_ID="$CATAPULT_APP_TEAM_ID"
APP_PATH="${CATAPULT_BUILD_DIR_APPSTORE}/${APP_NAME}.app"
BINARY="${APP_PATH}/Contents/MacOS/${APP_NAME}"
EXPECTED_SIGNING_ID="$CATAPULT_APP_SIGNING_IDENTITY_APPSTORE"

PASS=0
FAIL=0

pass() { echo "✅ $1"; PASS=$((PASS+1)); }
fail() { echo "❌ $1"; FAIL=$((FAIL+1)); }
info() { echo "ℹ️  $1"; }

echo "🔍 Verifying ${APP_PATH}"
echo ""

if [ ! -d "$APP_PATH" ]; then
    fail "App bundle not found at ${APP_PATH}. Run build-appstore.sh first."
    exit 1
fi
pass "App bundle exists"

if [ ! -x "$BINARY" ]; then
    fail "Binary missing or not executable: ${BINARY}"
else
    pass "Binary present and executable"
fi

if otool -L "$BINARY" 2>/dev/null | grep -qi sparkle; then
    fail "Binary links against Sparkle — App Store build will crash on launch"
    otool -L "$BINARY" | grep -i sparkle | sed 's/^/    /'
else
    pass "Binary does not link against Sparkle"
fi

RPATH_DEPS=$(otool -L "$BINARY" 2>/dev/null | awk '/@rpath/ {print $1}')
if [ -n "$RPATH_DEPS" ]; then
    MISSING=""
    while IFS= read -r dep; do
        framework=$(echo "$dep" | sed -E 's|@rpath/([^/]+\.framework).*|\1|')
        if [ ! -d "${APP_PATH}/Contents/Frameworks/${framework}" ]; then
            MISSING="${MISSING}    ${dep}\n"
        fi
    done <<< "$RPATH_DEPS"
    if [ -n "$MISSING" ]; then
        fail "Binary references @rpath frameworks that aren't embedded:"
        printf "%b" "$MISSING"
    else
        pass "All @rpath dependencies are embedded in Contents/Frameworks"
    fi
else
    pass "No @rpath dependencies (binary is self-contained)"
fi

if [ ! -f "${APP_PATH}/Contents/embedded.provisionprofile" ]; then
    fail "embedded.provisionprofile missing"
else
    pass "embedded.provisionprofile present"
fi

if codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null 2>&1; then
    pass "Code signature is valid"
else
    fail "Code signature verification failed"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | sed 's/^/    /'
fi

SIGN_AUTH=$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 | grep "^Authority=" | head -1 | sed 's/^Authority=//')
if [ "$SIGN_AUTH" = "$EXPECTED_SIGNING_ID" ]; then
    pass "Signed with: ${SIGN_AUTH}"
else
    fail "Unexpected signing identity"
    info "  expected: ${EXPECTED_SIGNING_ID}"
    info "  actual:   ${SIGN_AUTH:-<none>}"
fi

ENTITLEMENTS=$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null)
if echo "$ENTITLEMENTS" | grep -q "com.apple.security.app-sandbox"; then
    if echo "$ENTITLEMENTS" | grep -A1 "com.apple.security.app-sandbox" | grep -q "<true/>"; then
        pass "App sandbox entitlement is enabled"
    else
        fail "com.apple.security.app-sandbox is present but not <true/>"
    fi
else
    fail "Missing com.apple.security.app-sandbox entitlement (App Store requires it)"
fi

TEAM_IN_ENT=$(echo "$ENTITLEMENTS" | grep -A1 "com.apple.developer.team-identifier" | grep "<string>" | sed -E 's|.*<string>(.*)</string>.*|\1|' | head -1)
if [ -n "$TEAM_IN_ENT" ] && [ "$TEAM_IN_ENT" != "$TEAM_ID" ]; then
    fail "Team ID mismatch in entitlements: ${TEAM_IN_ENT} (expected ${TEAM_ID})"
else
    pass "Team identifier OK"
fi

PLIST="${APP_PATH}/Contents/Info.plist"
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion; do
    if /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1; then
        pass "Info.plist has $key"
    else
        fail "Info.plist missing $key"
    fi
done

if /usr/libexec/PlistBuddy -c "Print" "$PLIST" 2>/dev/null | grep -qi "^ *SU[A-Z]"; then
    fail "Info.plist still contains Sparkle (SU*) keys — strip them for App Store"
else
    pass "Info.plist contains no Sparkle keys"
fi

ARCHS=$(lipo -archs "$BINARY" 2>/dev/null)
info "Binary architectures: ${ARCHS}"

echo ""
info "Running launch smoke test (3s)..."
"$BINARY" >/dev/null 2>&1 &
SMOKE_PID=$!
sleep 3
if kill -0 "$SMOKE_PID" 2>/dev/null; then
    kill "$SMOKE_PID" 2>/dev/null
    wait "$SMOKE_PID" 2>/dev/null
    pass "Binary launched without immediate dyld failure"
else
    wait "$SMOKE_PID" 2>/dev/null
    EXIT=$?
    fail "Binary exited within 3s (exit code ${EXIT}) — likely a dyld or startup error"
fi

echo ""
echo "─────────────────────────────────"
echo "Passed: ${PASS}    Failed: ${FAIL}"
echo "─────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "🎉 App Store build looks good. Safe to upload."
