#!/bin/bash
# release.sh — build, sign, notarize, and package "lil agents.app" for a tagged release.
#
# Usage:
#   scripts/release.sh [version]
#
#   version   Release version, e.g. "0.2.0" (no leading "v"). Optional — if
#             omitted, derived from $GITHUB_REF_NAME (e.g. tag "v0.2.0" -> "0.2.0").
#
# Required environment variables:
#   APPLE_DEVELOPER_ID     "Developer ID Application: Your Name (TEAMID)" — the
#                           signing identity string as it appears in the keychain.
#   APPLE_ID                Apple ID email used for notarization.
#   APPLE_TEAM_ID            10-character Apple Developer Team ID.
#   APPLE_APP_PASSWORD       App-specific password for notarytool (NOT your Apple ID password).
#   SPARKLE_PRIVATE_KEY      Sparkle EdDSA private key (base64 string, as produced by
#                             generate_keys) used to sign the update archive.
#
# In CI, the signing identity above is expected to already be present in the
# keychain that `security list-keychains` will search (the workflow imports
# the .p12 into a temporary keychain before calling this script). This script
# does not import certificates itself.
#
# Outputs (written to dist/ at the repo root):
#   dist/lil-agents-<version>.zip              Sparkle update archive (stapled app, zipped)
#   dist/lil-agents-<version>.dmg               Human first-download disk image (stapled)
#   dist/appcast-fragment.txt                   sparkle:edSignature + length for the appcast <enclosure>
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Resolve version + paths
# ---------------------------------------------------------------------------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RAW_VERSION="${1:-${GITHUB_REF_NAME:-}}"
if [[ -z "$RAW_VERSION" ]]; then
    echo "error: no version given (pass as arg or set GITHUB_REF_NAME)" >&2
    exit 1
fi
# Strip a leading "v" if present (tag "v0.2.0" -> "0.2.0").
VERSION="${RAW_VERSION#v}"

: "${APPLE_DEVELOPER_ID:?error: APPLE_DEVELOPER_ID is not set}"
: "${APPLE_ID:?error: APPLE_ID is not set}"
: "${APPLE_TEAM_ID:?error: APPLE_TEAM_ID is not set}"
: "${APPLE_APP_PASSWORD:?error: APPLE_APP_PASSWORD is not set}"
: "${SPARKLE_PRIVATE_KEY:?error: SPARKLE_PRIVATE_KEY is not set}"

APP="dist/lil agents.app"
DIST="$ROOT/dist"
SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"

ZIP_NAME="lil-agents-${VERSION}.zip"
DMG_NAME="lil-agents-${VERSION}.dmg"

echo "==> Releasing lil agents ${VERSION} (raw ref: ${RAW_VERSION})"

# ---------------------------------------------------------------------------
# 1. Build the app (debug ad-hoc-signed bundle assembled by build-app.sh)
# ---------------------------------------------------------------------------
echo "==> Building app via scripts/build-app.sh"
scripts/build-app.sh release

if [[ ! -d "$APP" ]]; then
    echo "error: expected app bundle not found at $APP" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Stamp version info into Info.plist
#
# CFBundleVersion must strictly increase across releases and must equal the
# sparkle:version used in the appcast. We use the total commit count as a
# simple, monotonically-increasing build number; CFBundleShortVersionString
# is the human-facing semantic version from the tag.
# ---------------------------------------------------------------------------
BUILD_NUMBER="$(git rev-list --count HEAD)"
echo "==> Stamping CFBundleShortVersionString=${VERSION} CFBundleVersion=${BUILD_NUMBER}"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "$APP/Contents/Info.plist"

# ---------------------------------------------------------------------------
# 3. Re-sign with Developer ID (inner -> outer, never --deep)
#
# The app is non-sandboxed and needs no entitlements file. Installer.xpc
# gets none either. Downloader.xpc must keep its own entitlements, which is
# why it's the only nested item signed with --preserve-metadata=entitlements.
# ---------------------------------------------------------------------------
echo "==> Re-signing with Developer ID: ${APPLE_DEVELOPER_ID}"

FW="$APP/Contents/Frameworks/Sparkle.framework"
FW_VERSION="$FW/Versions/B"

codesign -f -s "$APPLE_DEVELOPER_ID" -o runtime --timestamp \
    "$FW_VERSION/XPCServices/Installer.xpc"
codesign -f -s "$APPLE_DEVELOPER_ID" -o runtime --timestamp --preserve-metadata=entitlements \
    "$FW_VERSION/XPCServices/Downloader.xpc"
codesign -f -s "$APPLE_DEVELOPER_ID" -o runtime --timestamp \
    "$FW_VERSION/Autoupdate"
codesign -f -s "$APPLE_DEVELOPER_ID" -o runtime --timestamp \
    "$FW_VERSION/Updater.app"
codesign -f -s "$APPLE_DEVELOPER_ID" -o runtime --timestamp \
    "$FW"
codesign -f -s "$APPLE_DEVELOPER_ID" -o runtime --timestamp \
    "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

# ---------------------------------------------------------------------------
# 4. Notarize + staple the .app
# ---------------------------------------------------------------------------
echo "==> Notarizing"
NOTARIZE_ZIP="$DIST/notarize.zip"
rm -f "$NOTARIZE_ZIP"
ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"

xcrun notarytool submit "$NOTARIZE_ZIP" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait

rm -f "$NOTARIZE_ZIP"

echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# ---------------------------------------------------------------------------
# 5. Build the distributed archives from the stapled app
# ---------------------------------------------------------------------------
echo "==> Building Sparkle update archive: $ZIP_NAME"
rm -f "$DIST/$ZIP_NAME"
ditto -c -k --keepParent "$APP" "$DIST/$ZIP_NAME"

echo "==> Building DMG: $DMG_NAME"
DMG_STAGING="$(mktemp -d)"
trap 'rm -rf "$DMG_STAGING"' EXIT

ditto "$APP" "$DMG_STAGING/lil agents.app"
ln -s /Applications "$DMG_STAGING/Applications"

rm -f "$DIST/$DMG_NAME"
hdiutil create -volname "lil agents" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DIST/$DMG_NAME"

echo "==> Notarizing DMG"
xcrun notarytool submit "$DIST/$DMG_NAME" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait

xcrun stapler staple "$DIST/$DMG_NAME"
xcrun stapler validate "$DIST/$DMG_NAME"

# ---------------------------------------------------------------------------
# 6. Sign the Sparkle update archive and emit the appcast fragment
# ---------------------------------------------------------------------------
echo "==> Signing update archive with Sparkle EdDSA key"
# Sparkle 2.9+ removed the `-s <key>` argument ("no longer supported"); the key
# must be supplied via a file with --ed-key-file. Write it to a private temp
# file and remove it on exit.
SPARKLE_KEY_FILE="$(mktemp)"
trap 'rm -f "$SPARKLE_KEY_FILE"' EXIT
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$SPARKLE_KEY_FILE"
SIGN_OUTPUT="$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY_FILE" "$DIST/$ZIP_NAME")"
rm -f "$SPARKLE_KEY_FILE"; trap - EXIT
echo "$SIGN_OUTPUT"

# sign_update prints: sparkle:edSignature="..." length="..."
ED_SIGNATURE="$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | sed -E 's/sparkle:edSignature="([^"]*)"/\1/')"
LENGTH="$(echo "$SIGN_OUTPUT" | grep -o 'length="[^"]*"' | sed -E 's/length="([^"]*)"/\1/')"

if [[ -z "$ED_SIGNATURE" || -z "$LENGTH" ]]; then
    echo "error: could not parse sign_update output" >&2
    exit 1
fi

FRAGMENT="$DIST/appcast-fragment.txt"
{
    echo "VERSION=${VERSION}"
    echo "BUILD_NUMBER=${BUILD_NUMBER}"
    echo "ZIP_NAME=${ZIP_NAME}"
    echo "DMG_NAME=${DMG_NAME}"
    echo "ED_SIGNATURE=${ED_SIGNATURE}"
    echo "LENGTH=${LENGTH}"
} > "$FRAGMENT"

echo "==> Done. Artifacts:"
echo "    $DIST/$ZIP_NAME"
echo "    $DIST/$DMG_NAME"
echo "    $FRAGMENT"
