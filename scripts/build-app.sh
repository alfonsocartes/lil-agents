#!/bin/bash
# Build AgentDeck.app — a menu-bar-less macOS agent app — from the Swift package.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="lil agents.app"
BUILD_DIR="$ROOT/dist"
APP_DIR="$BUILD_DIR/$APP"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/AgentDeck"
if [[ ! -x "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/AgentDeck"
cp "$ROOT/packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/packaging/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# Ad-hoc code signature gives the app a stable identity so macOS TCC
# (Automation / admin) grants persist across launches.
echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || \
    echo "warning: ad-hoc codesign failed (app will still run, but TCC grants may not persist)"

echo "==> Done: $APP_DIR"
echo "Run it with:  open \"$APP_DIR\"   (or: \"$APP_DIR/Contents/MacOS/AgentDeck\" for logs)"
