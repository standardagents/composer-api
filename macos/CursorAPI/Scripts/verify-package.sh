#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/API for Cursor.app}"
DIST_DIR="$(dirname "$APP_PATH")"
ZIP_PATH="$DIST_DIR/API for Cursor.zip"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
MACOS_DIR="$APP_PATH/Contents/MacOS"
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
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
[ -d "$FRAMEWORKS_DIR/Sparkle.framework" ] || fail "Sparkle.framework is missing"
otool -L "$MACOS_DIR/$APP_NAME" | grep -q '@rpath/Sparkle.framework' || fail "main executable is not linked to Sparkle"
otool -l "$MACOS_DIR/$APP_NAME" | grep -q '@executable_path/../Frameworks' || fail "main executable cannot load bundled frameworks"
[ -s "$RESOURCES_DIR/cursor-sdk-local-agent-bridge.mjs" ] || fail "SDK bridge script is missing"
[ -d "$RESOURCES_DIR/node_modules/@cursor/sdk" ] || fail "bundled @cursor/sdk dependencies are missing"
if [ -x "$RESOURCES_DIR/node" ]; then
  BRIDGE_RUNTIME_PATH="$RESOURCES_DIR/node"
elif [ -x "$RESOURCES_DIR/bun" ]; then
  BRIDGE_RUNTIME_PATH="$RESOURCES_DIR/bun"
else
  fail "bundled bridge runtime is missing or not executable"
fi
BRIDGE_RUNTIME_PATH="$(cd "$(dirname "$BRIDGE_RUNTIME_PATH")" && pwd)/$(basename "$BRIDGE_RUNTIME_PATH")"
(
  cd "$RESOURCES_DIR"
  "$BRIDGE_RUNTIME_PATH" -e '
    Promise.all([import("node:http2"), import("@cursor/sdk")])
      .then(([http2, sdk]) => {
        if (typeof http2.connect !== "function" || typeof sdk.Agent?.create !== "function") {
          process.exit(1);
        }
      })
      .catch(() => process.exit(1));
  ' >/dev/null
) || fail "bundled bridge runtime cannot load node:http2 and @cursor/sdk"
if [ "$(basename "$BRIDGE_RUNTIME_PATH")" = "node" ] || [ "$(basename "$BRIDGE_RUNTIME_PATH")" = "bun" ]; then
  runtime_entitlements="$(codesign -d --entitlements :- "$BRIDGE_RUNTIME_PATH" 2>/dev/null || true)"
  printf "%s" "$runtime_entitlements" | grep -q "com.apple.security.cs.allow-jit" \
    || fail "bundled bridge runtime is missing JIT entitlement"
  printf "%s" "$runtime_entitlements" | grep -q "com.apple.security.cs.allow-unsigned-executable-memory" \
    || fail "bundled bridge runtime is missing executable-memory entitlement"
fi
[ -s "$RESOURCES_DIR/APIForCursor.icns" ] || fail "app icon is missing"
[ -s "$RESOURCES_DIR/APIForCursor.png" ] || fail "runtime app icon PNG is missing"
ICON_VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-icon.XXXXXX")"
trap 'rm -rf "$ICON_VERIFY_DIR"' EXIT
iconutil -c iconset "$RESOURCES_DIR/APIForCursor.icns" -o "$ICON_VERIFY_DIR/APIForCursor.iconset" >/dev/null \
  || fail "app icon cannot be expanded"
ICON_VERIFY_PNG="$ICON_VERIFY_DIR/APIForCursor.iconset/icon_512x512@2x.png"
[ -s "$ICON_VERIFY_PNG" ] || fail "app icon is missing 1024px artwork"
swift - "$ICON_VERIFY_PNG" <<'SWIFT' || fail "app icon does not contain the packaged artwork"
import AppKit
import Foundation

let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = NSImage(contentsOf: imageURL),
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
var darkBasePixels = 0
var brightLogoPixels = 0

for offset in stride(from: 0, to: pixels.count, by: 4) {
    let red = Int(pixels[offset])
    let green = Int(pixels[offset + 1])
    let blue = Int(pixels[offset + 2])
    let alpha = Int(pixels[offset + 3])

    guard alpha > 32 else { continue }
    visiblePixels += 1

    if red < 24, green < 24, blue < 24 {
        darkBasePixels += 1
    }
    if red > 220, green > 220, blue > 220 {
        brightLogoPixels += 1
    }
}

let totalPixels = width * height
guard visiblePixels > totalPixels * 11 / 20,
      visiblePixels < totalPixels * 3 / 4,
      darkBasePixels > totalPixels * 2 / 5,
      brightLogoPixels > totalPixels / 12 else {
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

[ -f "$TRANSPORT_PLIST" ] || fail "bundled SDK defaults are missing"
for key in clientVersion
do
  plist_has_nonempty_value "$key" "$TRANSPORT_PLIST" || fail "bundled SDK default $key is missing"
done
plist_has_nonempty_value SUFeedURL "$INFO_PLIST" || fail "Sparkle SUFeedURL is missing"
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
  [ "$(plist_value SUPublicEDKey "$INFO_PLIST")" = "$SPARKLE_PUBLIC_ED_KEY" ] || fail "Sparkle SUPublicEDKey does not match the release key"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null

[ ! -e "$DIST_DIR/CursorAPI.app" ] || fail "legacy CursorAPI.app is still present"
[ ! -e "$DIST_DIR/CursorAPI.zip" ] || fail "legacy CursorAPI.zip is still present"
[ -s "$ZIP_PATH" ] || fail "release zip is missing"
zipinfo -1 "$ZIP_PATH" "$APP_NAME.app/Contents/Info.plist" >/dev/null || fail "release zip does not contain the app bundle"

echo "Verified $APP_PATH"
