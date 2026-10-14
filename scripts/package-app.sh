#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
DESTINATION="${2:-$ROOT_DIR/dist}"
[[ $# -le 2 && ( "$CONFIG" == debug || "$CONFIG" == release ) ]] || { echo "Usage: $0 [debug|release] [destination]" >&2; exit 2; }
cd "$ROOT_DIR"
mkdir -p .build
LOCK="$ROOT_DIR/.build/.app-release-lock"
mkdir "$LOCK" || { echo "Another build or interrupted release owns $LOCK; inspect it before retrying." >&2; exit 1; }
STAGE=$(mktemp -d "$ROOT_DIR/.build/app-package.XXXXXX")
trap 'rm -rf "$STAGE"; rmdir "$LOCK"' EXIT
rtk swift build -c "$CONFIG"
BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP_BUNDLE="$STAGE/SideBarAI.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"
cp Packaging/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Packaging/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
ditto "$BUILD_DIR/SideBarAI" "$APP_BUNDLE/Contents/MacOS/SideBarAI"
ditto "$BUILD_DIR/SideBarAI_SideBarAI.bundle" "$APP_BUNDLE/Contents/Resources/SideBarAI_SideBarAI.bundle"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP_BUNDLE/Contents/Resources/ThirdPartyLicenses"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$APP_BUNDLE/Contents/Resources/ThirdPartyLicenses/Sparkle-LICENSE"
for asset in claude.svg openai.svg; do
    test -f "$APP_BUNDLE/Contents/Resources/SideBarAI_SideBarAI.bundle/Contents/Resources/$asset" || test -f "$APP_BUNDLE/Contents/Resources/SideBarAI_SideBarAI.bundle/$asset"
done
codesign --force --sign - "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - --identifier com.icelemontees.SideBarAI "$APP_BUNDLE"
"$APP_BUNDLE/Contents/MacOS/SideBarAI" --update-selftest
if [[ "$CONFIG" == release ]]; then
    rtk proxy python3 scripts/release.py "$APP_BUNDLE" "$DESTINATION/SideBarAI.app"
else
    mkdir -p "$DESTINATION"
    if [[ -e "$DESTINATION/SideBarAI.app" ]]; then
        [[ ! -L "$DESTINATION/SideBarAI.app" && $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DESTINATION/SideBarAI.app/Contents/Info.plist") == com.icelemontees.SideBarAI ]] || { echo "Refusing unrelated debug app destination" >&2; exit 1; }
        rm -rf "$DESTINATION/SideBarAI.app"
    fi
    ditto "$APP_BUNDLE" "$DESTINATION/SideBarAI.app"
    echo "Local debug app: $DESTINATION/SideBarAI.app (not for distribution)"
fi
