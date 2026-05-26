#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/API for Cursor.app}"
DIST_DIR="$(dirname "$APP_PATH")"
ZIP_PATH="$DIST_DIR/API for Cursor.zip"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
MACOS_DIR="$APP_PATH/Contents/MacOS"
RESOURCES_DIR="$APP_PATH/Contents/Resources"
BUNDLE_DIR="$RESOURCES_DIR/CursorAPI_CursorAPI.bundle"
TRANSPORT_PLIST="$RESOURCES_DIR/CursorAPITransportDefaults.plist"
APP_NAME="API for Cursor"

fail() {
  echo "Package verification failed: $*" >&2
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null
}

plist_has_nonempty_value() {
  local key="$1"
  local plist="$2"
  local value
  value="$(plist_value "$key" "$plist" || true)"
  [ -n "${value//[[:space:]]/}" ]
}

[ -d "$APP_PATH" ] || fail "app bundle is missing at $APP_PATH"
[ -f "$INFO_PLIST" ] || fail "Info.plist is missing"

[ "$(plist_value CFBundleDisplayName "$INFO_PLIST")" = "$APP_NAME" ] || fail "CFBundleDisplayName is not $APP_NAME"
[ "$(plist_value CFBundleName "$INFO_PLIST")" = "$APP_NAME" ] || fail "CFBundleName is not $APP_NAME"
[ "$(plist_value CFBundleExecutable "$INFO_PLIST")" = "$APP_NAME" ] || fail "CFBundleExecutable is not $APP_NAME"
[ "$(plist_value CFBundleIdentifier "$INFO_PLIST")" = "ai.standardagents.cursorapi" ] || fail "CFBundleIdentifier changed"
[ "$(plist_value CFBundleIconFile "$INFO_PLIST")" = "APIForCursor" ] || fail "CFBundleIconFile changed"

[ -x "$MACOS_DIR/$APP_NAME" ] || fail "main executable is missing or not executable"
[ -s "$RESOURCES_DIR/APIForCursor.icns" ] || fail "app icon is missing"
[ -d "$BUNDLE_DIR" ] || fail "resource bundle is missing"

for resource in \
  cursor-logo.png \
  opencode.png opencode-dark.png \
  codex.png codex-dark.png \
  vscode.png vscode-dark.png \
  cline.png cline-dark.png \
  kilo.png kilo-dark.png \
  pi.png pi-dark.png \
  continue.png continue-dark.png \
  aider.png aider-dark.png
do
  [ -s "$BUNDLE_DIR/$resource" ] || fail "resource bundle is missing $resource"
done

[ -f "$TRANSPORT_PLIST" ] || fail "bundled transport defaults are missing"
for key in cursorAPIBaseURL backendBaseURL localAgentEndpoint clientVersion
do
  plist_has_nonempty_value "$key" "$TRANSPORT_PLIST" || fail "bundled transport default $key is missing"
done

codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null

[ ! -e "$DIST_DIR/CursorAPI.app" ] || fail "legacy CursorAPI.app is still present"
[ ! -e "$DIST_DIR/CursorAPI.zip" ] || fail "legacy CursorAPI.zip is still present"
[ -s "$ZIP_PATH" ] || fail "release zip is missing"
zipinfo -1 "$ZIP_PATH" "$APP_NAME.app/Contents/Info.plist" >/dev/null || fail "release zip does not contain the app bundle"

echo "Verified $APP_PATH"
