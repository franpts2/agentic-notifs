#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_DIR=${AGENTIC_NOTIFS_APP_DIR:-"$HOME/Applications/Agentic Notifs.app"}
BIN_DIR="$HOME/.local/bin"
APP_PARENT=$(dirname -- "$APP_DIR")

swift build --package-path "$ROOT" -c release

mkdir -p "$APP_PARENT" "$BIN_DIR"
STAGING_DIR=$(mktemp -d "$APP_PARENT/.agentic-notifs-install.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT HUP INT TERM
STAGED_APP="$STAGING_DIR/Agentic Notifs.app"
STAGED_CLI="$STAGING_DIR/agentic-notify"

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$ROOT/.build/release/AgenticNotifs" "$STAGED_APP/Contents/MacOS/AgenticNotifs"
cp "$ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/.build/release/agentic-notify" "$STAGED_CLI"
chmod +x "$STAGED_APP/Contents/MacOS/AgenticNotifs" "$STAGED_CLI"

/usr/bin/codesign --force --sign - "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"

PREVIOUS_APP="$STAGING_DIR/Previous.app"
if [ -e "$APP_DIR" ]; then
    /usr/bin/pkill -x AgenticNotifs 2>/dev/null || true
    mv "$APP_DIR" "$PREVIOUS_APP"
fi
if ! mv "$STAGED_APP" "$APP_DIR"; then
    if [ -e "$PREVIOUS_APP" ]; then
        mv "$PREVIOUS_APP" "$APP_DIR"
    fi
    exit 1
fi
rm -rf "$PREVIOUS_APP"
mv "$STAGED_CLI" "$BIN_DIR/agentic-notify"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$APP_DIR"

"$BIN_DIR/agentic-notify" install-adapters \
    --opencode-plugin "$ROOT/Adapters/opencode.js" \
    --home "$HOME"

if [ "${AGENTIC_NOTIFS_NO_LAUNCH:-0}" != "1" ]; then
    /usr/bin/open "$APP_DIR"
fi

printf '%s\n' "Installed Agentic Notifs in $APP_DIR"
printf '%s\n' "Installed agentic-notify in $BIN_DIR"
printf '%s\n' "Allow notifications when macOS asks, then restart active agent sessions."
