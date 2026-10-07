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

CODESIGN_FLAGS=(--force --sign "$SIGNING_IDENTITY" --identifier "com.icelemontees.SideBarAI")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    # Notarization requires the hardened runtime and a secure timestamp.
    CODESIGN_FLAGS+=(--options runtime --timestamp)
fi
/usr/bin/codesign "${CODESIGN_FLAGS[@]}" "$APP_BUNDLE"
/usr/bin/codesign --verify --strict --verbose=2 "$APP_BUNDLE"
printf 'Created %s\n' "$APP_BUNDLE"

# Optional: NOTARY_PROFILE names credentials saved with `xcrun notarytool store-credentials`.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    if [[ "$SIGNING_IDENTITY" == "-" ]]; then
        echo "Notarization needs a Developer ID identity; set CODESIGN_IDENTITY." >&2
        exit 1
    fi
    VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")"
    RELEASE_ZIP="$DESTINATION/SideBarAI-$VERSION.zip"
    SUBMISSION_ZIP="$(mktemp -d)/SideBarAI.zip"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$SUBMISSION_ZIP"

    printf 'Submitting %s for notarization...\n' "$APP_NAME"
    RESULT="$(xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
    STATUS="$(/usr/bin/plutil -extract status raw -o - - <<<"$RESULT")"
    if [[ "$STATUS" != "Accepted" ]]; then
        SUBMISSION_ID="$(/usr/bin/plutil -extract id raw -o - - <<<"$RESULT")"
        echo "Notarization $STATUS. Log:" >&2
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        exit 1
    fi

    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$APP_BUNDLE"

    rm -f "$RELEASE_ZIP"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$RELEASE_ZIP"
    printf 'Notarized %s\nRelease archive %s\n' "$APP_BUNDLE" "$RELEASE_ZIP"
fi
