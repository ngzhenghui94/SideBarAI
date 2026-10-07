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

mkdir -p "$DESTINATION"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$ROOT_DIR/Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Packaging/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$PRODUCT" "$APP_BUNDLE/Contents/MacOS/SideBarAI"
cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/SideBarAI_SideBarAI.bundle"
chmod +x "$APP_BUNDLE/Contents/MacOS/SideBarAI"

test -f "$APP_BUNDLE/Contents/Info.plist"
test -x "$APP_BUNDLE/Contents/MacOS/SideBarAI"
test -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
for asset in claude.svg openai.svg; do
    test -f "$APP_BUNDLE/Contents/Resources/SideBarAI_SideBarAI.bundle/Contents/Resources/$asset" || test -f "$APP_BUNDLE/Contents/Resources/SideBarAI_SideBarAI.bundle/$asset"
done

/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --identifier "com.icelemontees.SideBarAI" "$APP_BUNDLE"
/usr/bin/codesign --verify --strict --verbose=2 "$APP_BUNDLE"
printf 'Created %s\n' "$APP_BUNDLE"
