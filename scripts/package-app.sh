#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
DESTINATION="${2:-$ROOT_DIR/dist}"
APP_NAME="SideBarAI.app"
APP_BUNDLE="$DESTINATION/$APP_NAME"

if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
    echo "Usage: $0 [debug|release] [destination]" >&2
    exit 2
fi

BUILD_DIR="$(rtk swift build --package-path "$ROOT_DIR" -c "$CONFIG" --show-bin-path)"
PRODUCT="$BUILD_DIR/SideBarAI"
RESOURCE_BUNDLE="$BUILD_DIR/SideBarAI_SideBarAI.bundle"

if [[ ! -x "$PRODUCT" || ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "Missing SwiftPM build products. Run: rtk swift build -c $CONFIG" >&2
    exit 1
fi

SIGNING_IDENTITY="${CODESIGN_IDENTITY:--}"
# SwiftPM's Bundle.module accessor requires the resource bundle beside Contents.
# Sign the executable before copying it into the app; codesign rejects the
# required root-level resource bundle when validating the outer app bundle.
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
    --identifier "com.icelemontees.SideBarAI" \
    "$PRODUCT"
/usr/bin/codesign --verify --strict --verbose=2 "$PRODUCT"

mkdir -p "$DESTINATION"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"

cp "$ROOT_DIR/Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PRODUCT" "$APP_BUNDLE/Contents/MacOS/SideBarAI"
cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/SideBarAI_SideBarAI.bundle"
chmod +x "$APP_BUNDLE/Contents/MacOS/SideBarAI"

test -f "$APP_BUNDLE/Contents/Info.plist"
test -x "$APP_BUNDLE/Contents/MacOS/SideBarAI"
test -f "$APP_BUNDLE/SideBarAI_SideBarAI.bundle/openai.svg" || \
    test -f "$APP_BUNDLE/SideBarAI_SideBarAI.bundle/Contents/Resources/openai.svg"
printf 'Created %s\n' "$APP_BUNDLE"
