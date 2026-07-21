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
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$BIN" "$APP_DIR/Contents/MacOS/AgentDeck"
cp "$ROOT/packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/packaging/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> Embedding Sparkle.framework"
SPARKLE_FRAMEWORK="$(find .build -path '*macos-arm64_x86_64/Sparkle.framework' -type d | head -1)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    echo "error: Sparkle.framework not found under .build — did swift build fetch dependencies?" >&2
    exit 1
fi
cp -R "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/Sparkle.framework"

EXECUTABLE="$APP_DIR/Contents/MacOS/AgentDeck"
if ! otool -l "$EXECUTABLE" | grep -q LC_RPATH; then
    echo "==> LC_RPATH missing — adding @executable_path/../Frameworks"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE"
fi

# Code signature gives the app a stable identity so macOS TCC (Automation /
# admin) and Keychain "Always Allow" grants persist across launches AND
# across rebuilds. Prefer a real Developer ID certificate when one is in the
# keychain (its designated requirement is identity-based, so grants survive
# recompilation); fall back to ad-hoc (grants are then tied to the exact
# binary hash and reset on every rebuild). Override with CODESIGN_IDENTITY.
# Sign inner→outer (no --deep) so each nested bundle gets its own valid
# signature before the outer .app is sealed over it.
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
        CODESIGN_IDENTITY="Developer ID Application"
    else
        CODESIGN_IDENTITY="-"
    fi
fi
echo "==> Signing with identity: $CODESIGN_IDENTITY"
SPARKLE_DIR="$APP_DIR/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$CODESIGN_IDENTITY" "$SPARKLE_DIR/Versions/B/XPCServices/Installer.xpc" >/dev/null 2>&1 || \
    echo "warning: codesign failed for Installer.xpc"
codesign --force --sign "$CODESIGN_IDENTITY" "$SPARKLE_DIR/Versions/B/XPCServices/Downloader.xpc" >/dev/null 2>&1 || \
    echo "warning: codesign failed for Downloader.xpc"
codesign --force --sign "$CODESIGN_IDENTITY" "$SPARKLE_DIR/Versions/B/Autoupdate" >/dev/null 2>&1 || \
    echo "warning: codesign failed for Autoupdate"
codesign --force --sign "$CODESIGN_IDENTITY" "$SPARKLE_DIR/Versions/B/Updater.app" >/dev/null 2>&1 || \
    echo "warning: codesign failed for Updater.app"
codesign --force --sign "$CODESIGN_IDENTITY" "$SPARKLE_DIR" >/dev/null 2>&1 || \
    echo "warning: codesign failed for Sparkle.framework"
codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$APP_DIR" >/dev/null 2>&1 || \
    codesign --force --sign "$CODESIGN_IDENTITY" "$APP_DIR" >/dev/null 2>&1 || \
    echo "warning: codesign failed (app will still run, but TCC grants may not persist)"

echo "==> Done: $APP_DIR"
echo "Run it with:  open \"$APP_DIR\"   (or: \"$APP_DIR/Contents/MacOS/AgentDeck\" for logs)"
