#!/bin/bash
# Generate AppIcon.icns from a single PNG.
# Inputs:  $TRIGGER_BUILD_ICON (source PNG), $TRIGGER_BUILD_DIR (output dir)
# Output:  $TRIGGER_BUILD_DIR/AppIcon.icns

set -e

: "${TRIGGER_BUILD_ICON:?}"
: "${TRIGGER_BUILD_DIR:?}"

if [ ! -f "$TRIGGER_BUILD_ICON" ]; then
    echo "❌ Icon source not found: $TRIGGER_BUILD_ICON"
    exit 1
fi

ICONSET="$TRIGGER_BUILD_DIR/icon.iconset"
mkdir -p "$ICONSET"

sips -z 16 16     "$TRIGGER_BUILD_ICON" --out "$ICONSET/icon_16x16.png"
sips -z 32 32     "$TRIGGER_BUILD_ICON" --out "$ICONSET/icon_16x16@2x.png"
sips -z 32 32     "$TRIGGER_BUILD_ICON" --out "$ICONSET/icon_32x32.png"
sips -z 64 64     "$TRIGGER_BUILD_ICON" --out "$ICONSET/icon_32x32@2x.png"
sips -z 128 128   "$TRIGGER_BUILD_ICON" --out "$ICONSET/icon_128x128.png"
sips -z 256 256   "$TRIGGER_BUILD_ICON" --out "$ICONSET/icon_128x128@2x.png"
sips -z 256 256   "$TRIGGER_BUILD_ICON" --out "$ICONSET/icon_256x256.png"
sips -z 512 512   "$TRIGGER_BUILD_ICON" --out "$ICONSET/icon_256x256@2x.png"
sips -z 512 512   "$TRIGGER_BUILD_ICON" --out "$ICONSET/icon_512x512.png"
sips -z 1024 1024 "$TRIGGER_BUILD_ICON" --out "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$TRIGGER_BUILD_DIR/AppIcon.icns"
echo "✅ AppIcon.icns generated"
