#!/bin/bash
# app_intents.sh — App Intents metadata for swift builds. Sourced by build.sh
# and build_appstore.sh, and a no-op unless build.app_intents is set.
#
# Siri and Shortcuts find an app's intents in
# Contents/Resources/Metadata.appintents. Xcode writes it, SwiftPM does not.

app_intents_enabled() {
    [ "${CATAPULT_BUILD_APP_INTENTS:-0}" = "1" ]
}

# Sets CATAPULT_APP_INTENTS_FLAGS to the `swift build` flags that make the
# compiler record the constant values the metadata processor reads.
app_intents_flags() {
    CATAPULT_APP_INTENTS_FLAGS=()
    app_intents_enabled || return 0
    local protocols="${CATAPULT_BUILD_DIR}/app_intents_protocols.json"
    [[ "$protocols" = /* ]] || protocols="$(pwd)/${protocols}"
    mkdir -p "$(dirname "$protocols")"
    # The protocols Xcode 27 has the compiler gather for the processor.
    cat >"$protocols" <<'JSON'
["AnyResolverProviding","AppEntity","AppEnum","AppExtension","AppIntent","AppIntentsPackage","AppShortcutProviding","AppShortcutsProvider","AppUnionValue","AppUnionValueCasesProviding","DynamicMigration_v1","DynamicOptionsProvider","EntityQuery","ExtensionPointDefining","IntentValueQuery","Resolver","StaticMigration_v1","TransientEntity","_AssistantIntentsProvider","_GenerativeFunctionExtractable","_IntentValueRepresentable"]
JSON
    # shellcheck disable=SC2034 # read by the script that sources this one
    CATAPULT_APP_INTENTS_FLAGS=(
        -Xswiftc -emit-const-values
        -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file
        -Xswiftc -Xfrontend -Xswiftc "$protocols"
    )
}

# Writes Metadata.appintents into the bundle at $1, from the build just made.
app_intents_metadata() {
    app_intents_enabled || return 0
    local app="$1"
    local objects=".build/release/${CATAPULT_BUILD_SWIFT_TARGET}.build"
    local values
    values="$(mktemp)"
    printf '%s\n' "$objects"/*.swiftconstvalues >"$values"
    xcrun appintentsmetadataprocessor \
        --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" \
        --module-name "$CATAPULT_BUILD_SWIFT_TARGET" \
        --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
        --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
        --platform-family macOS \
        --deployment-target "$CATAPULT_APP_MIN_MACOS" \
        --bundle-identifier "$CATAPULT_APP_BUNDLE_ID" \
        --output "${app}/Contents/Resources" \
        --target-triple "${CATAPULT_BUILD_ARCH}-apple-macos${CATAPULT_APP_MIN_MACOS}" \
        --binary-file "${app}/Contents/MacOS/${CATAPULT_APP_NAME}" \
        --source-file-list "${objects}/sources" \
        --swift-const-vals-list "$values" \
        --compile-time-extraction --deployment-aware-processing --no-app-shortcuts-localization
    rm -f "$values"
    if [ ! -f "${app}/Contents/Resources/Metadata.appintents/extract.actionsdata" ]; then
        echo "❌ build.app_intents is set, but no App Intents metadata was written" >&2
        exit 1
    fi
    echo "✅ App Intents metadata written"
}
