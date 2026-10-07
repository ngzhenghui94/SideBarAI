#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${SIDEBARAI_CONFIGURATION:-release}"
INSTALL_DIR="${SIDEBARAI_INSTALL_DIR:-/Applications}"
DRY_RUN=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [--configuration debug|release] [--install-dir PATH] [--dry-run]

Builds SideBarAI with SwiftPM, packages it as an app bundle, and installs it.
Defaults: release configuration, /Applications destination.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration|-c)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; usage >&2; exit 2; }
            CONFIG="$2"
            shift 2
            ;;
        --install-dir)
            [[ $# -ge 2 ]] || { echo "Missing value for --install-dir" >&2; usage >&2; exit 2; }
            INSTALL_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$CONFIG" in
    debug|release) ;;
    *)
        echo "Configuration must be debug or release: $CONFIG" >&2
        exit 2
        ;;
esac

APP_NAME="SideBarAI.app"
PACKAGE_DESTINATION="$ROOT_DIR/dist"
APP_BUNDLE="$PACKAGE_DESTINATION/$APP_NAME"
INSTALL_TARGET="$INSTALL_DIR/$APP_NAME"

cd "$ROOT_DIR"
printf 'Building %s configuration...\n' "$CONFIG"
rtk swift build -c "$CONFIG"

printf 'Packaging %s...\n' "$APP_NAME"
rtk bash "$ROOT_DIR/scripts/package-app.sh" "$CONFIG" "$PACKAGE_DESTINATION"

if [[ "$DRY_RUN" == true ]]; then
    printf 'Dry run: would install %s to %s\n' "$APP_BUNDLE" "$INSTALL_TARGET"
    exit 0
fi

if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Install directory does not exist: $INSTALL_DIR" >&2
    exit 1
fi
if [[ ! -w "$INSTALL_DIR" ]]; then
    echo "Install directory is not writable: $INSTALL_DIR" >&2
    echo "Re-run with appropriate permissions, for example: sudo $0 $*" >&2
    exit 1
fi

printf 'Installing %s...\n' "$INSTALL_TARGET"
rm -rf "$INSTALL_TARGET"
/usr/bin/ditto --rsrc --extattr --acl "$APP_BUNDLE" "$INSTALL_TARGET"

test -f "$INSTALL_TARGET/Contents/Info.plist"
test -x "$INSTALL_TARGET/Contents/MacOS/SideBarAI"
for asset in claude.svg openai.svg; do
    test -f "$INSTALL_TARGET/Contents/Resources/SideBarAI_SideBarAI.bundle/Contents/Resources/$asset" || test -f "$INSTALL_TARGET/Contents/Resources/SideBarAI_SideBarAI.bundle/$asset"
done
/usr/bin/codesign --verify --strict --verbose=2 "$INSTALL_TARGET"
printf 'Installed %s\n' "$INSTALL_TARGET"
printf 'Quit and relaunch SideBarAI to run the new build.\n'
