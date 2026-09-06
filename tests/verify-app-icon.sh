#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/lil agents.app"

"$ROOT/scripts/build-app.sh" debug >/dev/null

ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")"
[[ "$ICON_NAME" == "AppIcon.icns" ]]
[[ -s "$APP/Contents/Resources/$ICON_NAME" ]]
