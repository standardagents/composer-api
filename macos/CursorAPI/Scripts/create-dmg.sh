#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/API for Cursor.app}"
DIST_DIR="$(dirname "$APP_PATH")"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO_PLIST")"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
DMG_BASENAME="${CURSOR_API_DMG_BASENAME:-API-for-Cursor-${APP_VERSION}-${APP_BUILD}}"
DMG_PATH="$DIST_DIR/$DMG_BASENAME.dmg"
LATEST_DMG_PATH="$DIST_DIR/API-for-Cursor-latest.dmg"
VOLUME_NAME="${CURSOR_API_DMG_VOLUME_NAME:-$APP_NAME}"
CODE_SIGN_IDENTITY="${CURSOR_API_CODE_SIGN_IDENTITY:-}"

fail() {
  echo "DMG creation failed: $*" >&2
  exit 1
}

[ -d "$APP_PATH" ] || fail "app bundle is missing at $APP_PATH"
[ -f "$INFO_PLIST" ] || fail "Info.plist is missing at $INFO_PLIST"
command -v hdiutil >/dev/null 2>&1 || fail "hdiutil is required"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-dmg.XXXXXX")"
TEMP_DMG="$DIST_DIR/$DMG_BASENAME.rw.dmg"
cleanup() {
  rm -rf "$STAGING_DIR" "$TEMP_DMG"
}
trap cleanup EXIT

cp -R "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH" "$LATEST_DMG_PATH" "$TEMP_DMG"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$TEMP_DMG" >/dev/null

hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null

if [ -n "$CODE_SIGN_IDENTITY" ] && [ "$CODE_SIGN_IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$CODE_SIGN_IDENTITY" "$DMG_PATH" >/dev/null
fi

hdiutil verify "$DMG_PATH" >/dev/null
cp "$DMG_PATH" "$LATEST_DMG_PATH"

echo "$DMG_PATH"
