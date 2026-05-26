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
[ -x "$RESOURCES_DIR/node" ] || fail "bundled Node runtime is missing or not executable"
[ -s "$RESOURCES_DIR/cursor-sdk-opencode-bridge.mjs" ] || fail "SDK bridge script is missing"
[ -s "$RESOURCES_DIR/APIForCursor.icns" ] || fail "app icon is missing"
[ -s "$RESOURCES_DIR/APIForCursor.png" ] || fail "runtime app icon PNG is missing"
swift - "$RESOURCES_DIR/APIForCursor.icns" <<'SWIFT' || fail "app icon does not contain the packaged artwork"
import AppKit
import Foundation

let iconURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = NSImage(contentsOf: iconURL),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    exit(1)
}

let width = cgImage.width
let height = cgImage.height
guard width >= 1024, height >= 1024 else {
    exit(1)
}

var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    exit(1)
}

context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

var visiblePixels = 0
var bridgeGreenPixels = 0
var brightBridgePixels = 0

for offset in stride(from: 0, to: pixels.count, by: 4) {
    let red = Int(pixels[offset])
    let green = Int(pixels[offset + 1])
    let blue = Int(pixels[offset + 2])
    let alpha = Int(pixels[offset + 3])

    guard alpha > 32 else { continue }
    visiblePixels += 1

    if green > 140, red > 90, blue < 130 {
        bridgeGreenPixels += 1
    }
    if red > 220, green > 220, blue > 220 {
        brightBridgePixels += 1
    }
}

let totalPixels = width * height
guard visiblePixels > totalPixels * 7 / 10,
      bridgeGreenPixels > totalPixels / 120,
      brightBridgePixels > totalPixels / 120 else {
    exit(1)
}
SWIFT
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
  aider.png aider-dark.png \
  roo.png roo-dark.png
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
