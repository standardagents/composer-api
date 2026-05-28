#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY_DIR="$(cd "$ROOT_DIR/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_NAME="API for Cursor"
EXECUTABLE_NAME="$APP_NAME"
APP_VERSION="${CURSOR_API_APP_VERSION:-0.1.0}"
APP_BUILD="${CURSOR_API_APP_BUILD:-1}"
APP_COPYRIGHT="${CURSOR_API_COPYRIGHT:-Copyright 2026 Standard Agents}"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
LEGACY_APP_DIR="$ROOT_DIR/dist/CursorAPI.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$RESOURCES_DIR/APIForCursor.iconset"
APP_ICON_SOURCE="$ROOT_DIR/Sources/CursorAPI/Resources/APIForCursor.png"
BRIDGE_SCRIPT_SOURCE="$REPOSITORY_DIR/scripts/cursor-sdk-local-agent-bridge.mjs"
REQUIRE_BUNDLED_TRANSPORT="${CURSOR_API_REQUIRE_BUNDLED_TRANSPORT:-0}"
RELEASE_BUILD=0
CODE_SIGN_IDENTITY="${CURSOR_API_CODE_SIGN_IDENTITY:--}"
APPCAST_URL="${CURSOR_API_APPCAST_URL:-https://api-for-composer.standardagents.ai/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
BRIDGE_RUNTIME_SOURCE="${CURSOR_API_BRIDGE_RUNTIME_BINARY:-${CURSOR_API_BUN_BINARY:-${CURSOR_API_NODE_BINARY:-}}}"
BRIDGE_RUNTIME_NAME="${CURSOR_API_BRIDGE_RUNTIME_NAME:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release)
      REQUIRE_BUNDLED_TRANSPORT=1
      RELEASE_BUILD=1
      ;;
    --development)
      REQUIRE_BUNDLED_TRANSPORT=0
      ;;
    -h|--help)
      cat <<USAGE
Usage: $0 [--development|--release]

  --development  Build a local development app. Missing bundled SDK defaults
                 are allowed and the app will show SDK Bridge Missing. This is the
                 default.
  --release      Refuse to package unless complete bundled SDK bridge
                 defaults are available from local environment files or the
                 current environment.

Environment:
  CURSOR_API_BRIDGE_RUNTIME_BINARY  Node or Bun runtime to bundle. Defaults to
                                    Node when available, then Bun.
  CURSOR_API_BRIDGE_RUNTIME_NAME    Runtime resource name when the binary name
                                    is ambiguous: bun or node.
  CURSOR_API_CODE_SIGN_IDENTITY     Signing identity. Defaults to ad-hoc (-).
  CURSOR_API_APPCAST_URL            Sparkle appcast URL.
  SPARKLE_PUBLIC_ED_KEY             Sparkle EdDSA public key for release builds.
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 64
      ;;
  esac
  shift
done
export CURSOR_API_REQUIRE_BUNDLED_TRANSPORT="$REQUIRE_BUNDLED_TRANSPORT"
if [ "$RELEASE_BUILD" = "1" ] && [ -z "$SPARKLE_PUBLIC_ED_KEY" ]; then
  echo "SPARKLE_PUBLIC_ED_KEY is required for release packages so Sparkle can verify updates." >&2
  exit 1
fi

swift build --package-path "$ROOT_DIR" -c release
rm -rf "$APP_DIR" "$LEGACY_APP_DIR"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/CursorAPI" "$MACOS_DIR/$EXECUTABLE_NAME"
SPARKLE_FRAMEWORK_SOURCE="$BUILD_DIR/Sparkle.framework"
[ -d "$SPARKLE_FRAMEWORK_SOURCE" ] || { echo "Missing Sparkle.framework at $SPARKLE_FRAMEWORK_SOURCE" >&2; exit 1; }
cp -R "$SPARKLE_FRAMEWORK_SOURCE" "$FRAMEWORKS_DIR/"
if ! otool -l "$MACOS_DIR/$EXECUTABLE_NAME" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$EXECUTABLE_NAME"
fi
if [ -d "$BUILD_DIR/CursorAPI_CursorAPI.bundle" ]; then
  cp -R "$BUILD_DIR/CursorAPI_CursorAPI.bundle" "$RESOURCES_DIR/"
fi
[ -s "$APP_ICON_SOURCE" ] || { echo "Missing app icon source at $APP_ICON_SOURCE" >&2; exit 1; }
cp "$APP_ICON_SOURCE" "$RESOURCES_DIR/APIForCursor.png"
[ -s "$BRIDGE_SCRIPT_SOURCE" ] || { echo "Missing SDK bridge script at $BRIDGE_SCRIPT_SOURCE" >&2; exit 1; }
cp "$BRIDGE_SCRIPT_SOURCE" "$RESOURCES_DIR/cursor-sdk-local-agent-bridge.mjs"
if [ -z "$BRIDGE_RUNTIME_SOURCE" ] && command -v node >/dev/null 2>&1; then
  BRIDGE_RUNTIME_SOURCE="$(node -p 'process.execPath' 2>/dev/null || true)"
  BRIDGE_RUNTIME_NAME="node"
fi
if [ -z "$BRIDGE_RUNTIME_SOURCE" ] && command -v bun >/dev/null 2>&1; then
  BRIDGE_RUNTIME_SOURCE="$(command -v bun)"
  BRIDGE_RUNTIME_NAME="bun"
fi
[ -n "$BRIDGE_RUNTIME_SOURCE" ] || { echo "Missing bridge runtime; install Bun or Node, or set CURSOR_API_BRIDGE_RUNTIME_BINARY before packaging." >&2; exit 1; }
[ -x "$BRIDGE_RUNTIME_SOURCE" ] || { echo "Bridge runtime is not executable at $BRIDGE_RUNTIME_SOURCE" >&2; exit 1; }
if [ -z "$BRIDGE_RUNTIME_NAME" ]; then
  case "$(basename "$BRIDGE_RUNTIME_SOURCE")" in
    bun|bun-*) BRIDGE_RUNTIME_NAME="bun" ;;
    node|node-*) BRIDGE_RUNTIME_NAME="node" ;;
    *)
      echo "Could not infer bridge runtime name from $BRIDGE_RUNTIME_SOURCE; set CURSOR_API_BRIDGE_RUNTIME_NAME to bun or node." >&2
      exit 1
      ;;
  esac
fi
case "$BRIDGE_RUNTIME_NAME" in
  bun|node) ;;
  *)
    echo "Unsupported bridge runtime name $BRIDGE_RUNTIME_NAME; expected bun or node." >&2
    exit 1
    ;;
esac
cp "$BRIDGE_RUNTIME_SOURCE" "$RESOURCES_DIR/$BRIDGE_RUNTIME_NAME"
chmod 755 "$RESOURCES_DIR/$BRIDGE_RUNTIME_NAME"
if [ ! -d "$REPOSITORY_DIR/node_modules/@cursor/sdk" ]; then
  echo "Missing @cursor/sdk dependencies; run npm install before packaging." >&2
  exit 1
fi
rm -rf "$RESOURCES_DIR/node_modules"
mkdir -p "$RESOURCES_DIR/node_modules"
while IFS= read -r module_path; do
  [ "$module_path" = "$REPOSITORY_DIR" ] && continue
  case "$module_path" in
    "$REPOSITORY_DIR/node_modules/"*) ;;
    *) continue ;;
  esac
  relative_module="${module_path#$REPOSITORY_DIR/node_modules/}"
  mkdir -p "$(dirname "$RESOURCES_DIR/node_modules/$relative_module")"
  cp -R "$module_path" "$RESOURCES_DIR/node_modules/$relative_module"
done < <(cd "$REPOSITORY_DIR" && npm ls --omit=dev --all --parseable)
swift - "$RESOURCES_DIR" "$ROOT_DIR" <<'SWIFT'
import Foundation
import Darwin

let resourcesDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
let rootDirectory = URL(fileURLWithPath: CommandLine.arguments[2])
let repositoryDirectory = rootDirectory.deletingLastPathComponent().deletingLastPathComponent()
let environment = ProcessInfo.processInfo.environment
var defaults: [String: String] = [:]

func unquote(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count >= 2,
       let first = trimmed.first,
       let last = trimmed.last,
       (first == "\"" && last == "\"" || first == "'" && last == "'") {
        return String(trimmed.dropFirst().dropLast())
    }
    return trimmed
}

func loadEnvironmentFile(_ url: URL) -> [String: String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        return [:]
    }
    var values: [String: String] = [:]
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
            continue
        }
        let normalized = trimmed.hasPrefix("export ") ? String(trimmed.dropFirst(7)) : trimmed
        guard let equals = normalized.firstIndex(of: "=") else {
            continue
        }
        let key = normalized[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = normalized[normalized.index(after: equals)...]
        guard !key.isEmpty else {
            continue
        }
        values[key] = unquote(String(rawValue))
    }
    return values
}

func inferSDKTransportDefaults(repositoryDirectory: URL) -> [String: String] {
    var values: [String: String] = [:]
    let packageURL = repositoryDirectory.appendingPathComponent("node_modules/@cursor/sdk/package.json")
    if let data = try? Data(contentsOf: packageURL),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let version = object["version"] as? String,
       !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        values["clientVersion"] = "sdk-\(version.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    return values
}

let localEnvironmentFiles = [
    repositoryDirectory.appendingPathComponent(".dev.vars"),
    repositoryDirectory.appendingPathComponent(".env.local"),
    repositoryDirectory.appendingPathComponent(".env"),
    rootDirectory.appendingPathComponent(".env.local")
]

var packagingValues: [String: String] = [:]
for file in localEnvironmentFiles {
    packagingValues.merge(loadEnvironmentFile(file)) { _, new in new }
}
packagingValues.merge(environment) { _, new in new }

let mappings = [
    ("CURSOR_SDK_CLIENT_VERSION", "clientVersion")
]

for (environmentKey, plistKey) in mappings {
    guard let value = packagingValues[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
        continue
    }
    defaults[plistKey] = value
}

let inferredDefaults = inferSDKTransportDefaults(repositoryDirectory: repositoryDirectory)
var usedInferredDefaults = false
for key in ["clientVersion"] {
    if defaults[key] == nil, let value = inferredDefaults[key] {
        defaults[key] = value
        usedInferredDefaults = true
    }
}

let requiredKeys: [String] = []
let missingKeys = requiredKeys.filter { defaults[$0] == nil }
let hasCompleteRouting = missingKeys.isEmpty
if hasCompleteRouting {
    let outputURL = resourcesDirectory.appendingPathComponent("CursorAPITransportDefaults.plist")
    guard NSDictionary(dictionary: defaults).write(to: outputURL, atomically: true) else {
        FileHandle.standardError.write(Data("Could not write bundled Composer routing defaults.\n".utf8))
        exit(1)
    }
    print(usedInferredDefaults ? "Embedded bundled SDK defaults from installed SDK metadata." : "Embedded bundled SDK defaults.")
} else {
    let message = "No complete bundled SDK defaults found; missing \(missingKeys.joined(separator: ", "))."
    let required = ["1", "true", "yes"].contains((environment["CURSOR_API_REQUIRE_BUNDLED_TRANSPORT"] ?? "").lowercased())
    if required {
        FileHandle.standardError.write(Data("\(message) Refusing release package.\n".utf8))
        exit(2)
    }
    print("\(message) This build will show SDK Bridge Missing.")
}
SWIFT
mkdir -p "$ICONSET_DIR"
swift - "$ICONSET_DIR" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])

func writeIcon(points: Int, scale: Int, name: String) throws {
    let pixels = points * scale
    let isSmall = pixels <= 64
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "CursorAPIIcon", code: 1)
    }

    let size = CGFloat(pixels)
    let bounds = CGRect(x: 0, y: 0, width: size, height: size)
    context.clear(bounds)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let tileRect = bounds.insetBy(dx: size * 0.022, dy: size * 0.022)
    let radius = size * 0.215
    let tilePath = CGPath(roundedRect: tileRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -size * 0.032),
        blur: size * 0.082,
        color: CGColor(gray: 0, alpha: 0.36)
    )
    context.setFillColor(CGColor(red: 0.012, green: 0.014, blue: 0.018, alpha: 1))
    context.addPath(tilePath)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    let baseGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.11, green: 0.20, blue: 0.24, alpha: 1.0),
            CGColor(red: 0.036, green: 0.048, blue: 0.066, alpha: 1.0),
            CGColor(red: 0.004, green: 0.006, blue: 0.012, alpha: 1.0)
        ] as CFArray,
        locations: [0.0, 0.56, 1.0]
    )!
    context.drawLinearGradient(
        baseGradient,
        start: CGPoint(x: tileRect.minX, y: tileRect.maxY),
        end: CGPoint(x: tileRect.maxX, y: tileRect.minY),
        options: []
    )

    let accentGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.12, green: 0.60, blue: 1.0, alpha: 0.55),
            CGColor(red: 0.00, green: 0.88, blue: 0.68, alpha: 0.18),
            CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        ] as CFArray,
        locations: [0.0, 0.34, 1.0]
    )!
    context.drawRadialGradient(
        accentGradient,
        startCenter: CGPoint(x: tileRect.minX + tileRect.width * 0.32, y: tileRect.maxY - tileRect.height * 0.18),
        startRadius: 0,
        endCenter: CGPoint(x: tileRect.minX + tileRect.width * 0.32, y: tileRect.maxY - tileRect.height * 0.18),
        endRadius: tileRect.width * 0.92,
        options: []
    )

    let lowerGlow = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.0, green: 0.70, blue: 1.0, alpha: 0.0),
            CGColor(red: 0.0, green: 0.58, blue: 1.0, alpha: 0.38),
            CGColor(red: 0.0, green: 0.55, blue: 0.44, alpha: 0.0)
        ] as CFArray,
        locations: [0.0, 0.54, 1.0]
    )!
    context.drawLinearGradient(
        lowerGlow,
        start: CGPoint(x: tileRect.minX, y: tileRect.minY + tileRect.height * 0.33),
        end: CGPoint(x: tileRect.maxX, y: tileRect.minY + tileRect.height * 0.18),
        options: []
    )

    let topSheen = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(gray: 1.0, alpha: 0.20),
            CGColor(gray: 1.0, alpha: 0.02),
            CGColor(gray: 1.0, alpha: 0.0)
        ] as CFArray,
        locations: [0.0, 0.42, 1.0]
    )!
    let sheenRect = CGRect(
        x: tileRect.minX + tileRect.width * 0.06,
        y: tileRect.maxY - tileRect.height * 0.22,
        width: tileRect.width * 0.88,
        height: tileRect.height * 0.16
    )
    context.saveGState()
    context.addEllipse(in: sheenRect)
    context.clip()
    context.drawLinearGradient(
        topSheen,
        start: CGPoint(x: sheenRect.midX, y: sheenRect.maxY),
        end: CGPoint(x: sheenRect.midX, y: sheenRect.minY),
        options: []
    )
    context.restoreGState()

    context.addPath(CGPath(roundedRect: tileRect.insetBy(dx: size * 0.012, dy: size * 0.012), cornerWidth: radius * 0.92, cornerHeight: radius * 0.92, transform: nil))
    context.setStrokeColor(CGColor(gray: 1.0, alpha: 0.18))
    context.setLineWidth(max(1, size * 0.008))
    context.strokePath()
    context.restoreGState()

    let markRect = tileRect.insetBy(dx: tileRect.width * 0.075, dy: tileRect.height * 0.095)
    let bridgeDeckY = markRect.minY + markRect.height * 0.29
    let bridgeTop = markRect.maxY - markRect.height * 0.07
    let towerWidth = markRect.width * 0.15
    let towerHeight = markRect.height * 0.67
    let leftTower = CGRect(
        x: markRect.minX + markRect.width * 0.18,
        y: bridgeDeckY - markRect.height * 0.025,
        width: towerWidth,
        height: towerHeight
    )
    let rightTower = CGRect(
        x: markRect.maxX - markRect.width * 0.18 - towerWidth,
        y: bridgeDeckY - markRect.height * 0.025,
        width: towerWidth,
        height: towerHeight
    )
    let deckRect = CGRect(
        x: markRect.minX + markRect.width * 0.01,
        y: bridgeDeckY - markRect.height * 0.07,
        width: markRect.width * 0.98,
        height: markRect.height * 0.15
    )

    func strokePath(_ path: CGPath, color: CGColor, width: CGFloat, shadow: Bool = false) {
        context.saveGState()
        if shadow {
            context.setShadow(
                offset: CGSize(width: 0, height: -size * 0.012),
                blur: size * 0.022,
                color: CGColor(gray: 0, alpha: 0.48)
            )
        }
        context.addPath(path)
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }

    let archPath = CGMutablePath()
    archPath.move(to: CGPoint(x: deckRect.minX + deckRect.width * 0.035, y: deckRect.maxY + deckRect.height * 0.14))
    archPath.addQuadCurve(
        to: CGPoint(x: deckRect.maxX - deckRect.width * 0.035, y: deckRect.maxY + deckRect.height * 0.14),
        control: CGPoint(x: markRect.midX, y: bridgeTop)
    )
    strokePath(archPath, color: CGColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.74), width: markRect.width * 0.145, shadow: true)
    strokePath(archPath, color: CGColor(red: 0.97, green: 0.995, blue: 1.0, alpha: 1.0), width: markRect.width * 0.092)

    if !isSmall {
        for fraction in [0.24, 0.34, 0.44, 0.56, 0.66, 0.76] {
            let x = deckRect.minX + deckRect.width * CGFloat(fraction)
            let topOffset = abs(CGFloat(fraction) - 0.5) * markRect.height * 0.86
            let cableTop = CGPoint(x: x, y: bridgeTop - topOffset - markRect.height * 0.04)
            let cableBottom = CGPoint(x: x, y: deckRect.maxY + markRect.height * 0.012)
            context.beginPath()
            context.move(to: cableTop)
            context.addLine(to: cableBottom)
            context.setStrokeColor(CGColor(red: 0.64, green: 0.84, blue: 1.0, alpha: 0.68))
            context.setLineWidth(max(1.4, markRect.width * 0.015))
            context.setLineCap(.round)
            context.strokePath()
        }
    }

    let towerGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 1.0, green: 1.0, blue: 0.98, alpha: 1.0),
            CGColor(red: 0.80, green: 0.86, blue: 0.90, alpha: 1.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!

    for tower in [leftTower, rightTower] {
        let towerPath = CGPath(roundedRect: tower, cornerWidth: tower.width * 0.28, cornerHeight: tower.width * 0.28, transform: nil)
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -size * 0.013),
            blur: size * 0.024,
            color: CGColor(gray: 0, alpha: 0.42)
        )
        context.addPath(towerPath)
        context.clip()
        context.drawLinearGradient(
            towerGradient,
            start: CGPoint(x: tower.minX, y: tower.maxY),
            end: CGPoint(x: tower.maxX, y: tower.minY),
            options: []
        )
        context.restoreGState()

        if !isSmall {
            let slotRect = CGRect(
                x: tower.midX - tower.width * 0.15,
                y: tower.maxY - tower.height * 0.48,
                width: tower.width * 0.30,
                height: tower.height * 0.39
            )
            context.addPath(CGPath(roundedRect: slotRect, cornerWidth: slotRect.width * 0.38, cornerHeight: slotRect.width * 0.38, transform: nil))
            context.setFillColor(CGColor(red: 0.035, green: 0.055, blue: 0.07, alpha: 0.90))
            context.fillPath()
        }
    }

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -size * 0.014),
        blur: size * 0.024,
        color: CGColor(gray: 0, alpha: 0.38)
    )
    context.addPath(CGPath(roundedRect: deckRect, cornerWidth: deckRect.height * 0.48, cornerHeight: deckRect.height * 0.48, transform: nil))
    context.setFillColor(CGColor(red: 0.96, green: 0.98, blue: 1.0, alpha: 1.0))
    context.fillPath()
    context.restoreGState()

    let baseRect = CGRect(
        x: markRect.minX + markRect.width * 0.02,
        y: deckRect.minY - markRect.height * 0.12,
        width: markRect.width * 0.96,
        height: markRect.height * 0.10
    )
    context.addPath(CGPath(roundedRect: baseRect, cornerWidth: baseRect.height * 0.5, cornerHeight: baseRect.height * 0.5, transform: nil))
    context.setFillColor(CGColor(red: 0.04, green: 0.50, blue: 1.0, alpha: 0.92))
    context.fillPath()

    if !isSmall {
        for fraction in [0.16, 0.84] {
            let nodeRadius = markRect.width * 0.044
            let nodeCenter = CGPoint(x: baseRect.minX + baseRect.width * CGFloat(fraction), y: baseRect.midY)
            context.addEllipse(in: CGRect(x: nodeCenter.x - nodeRadius, y: nodeCenter.y - nodeRadius, width: nodeRadius * 2, height: nodeRadius * 2))
            context.setFillColor(CGColor(red: 0.91, green: 0.98, blue: 1.0, alpha: 1.0))
            context.fillPath()
        }
    }

    guard let image = context.makeImage() else {
        throw NSError(domain: "CursorAPIIcon", code: 2)
    }
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CursorAPIIcon", code: 3)
    }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}

let specs = [
    (16, 1, "icon_16x16.png"),
    (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"),
    (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png")
]

for spec in specs {
    try writeIcon(points: spec.0, scale: spec.1, name: spec.2)
}
SWIFT
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/APIForCursor.icns"
rm -rf "$ICONSET_DIR"

# Use the checked-in 1024px app icon master for the final bundle icon.
# The Swift renderer above remains a deterministic fallback for development,
# but product builds should reflect the curated artwork in APIForCursor.png.
mkdir -p "$ICONSET_DIR"
source_icon() {
  local pixels="$1"
  local output="$2"
  sips -z "$pixels" "$pixels" "$APP_ICON_SOURCE" --out "$ICONSET_DIR/$output" >/dev/null
}
source_icon 16 icon_16x16.png
source_icon 32 icon_16x16@2x.png
source_icon 32 icon_32x32.png
source_icon 64 icon_32x32@2x.png
source_icon 128 icon_128x128.png
source_icon 256 icon_128x128@2x.png
source_icon 256 icon_256x256.png
source_icon 512 icon_256x256@2x.png
source_icon 512 icon_512x512.png
source_icon 1024 icon_512x512@2x.png
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/APIForCursor.icns"
rm -rf "$ICONSET_DIR"
xml_escape() {
  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}
APP_NAME_XML="$(xml_escape "$APP_NAME")"
EXECUTABLE_NAME_XML="$(xml_escape "$EXECUTABLE_NAME")"
APP_VERSION_XML="$(xml_escape "$APP_VERSION")"
APP_BUILD_XML="$(xml_escape "$APP_BUILD")"
APP_COPYRIGHT_XML="$(xml_escape "$APP_COPYRIGHT")"
APP_INFO_XML="$(xml_escape "$APP_NAME $APP_VERSION")"
APPCAST_URL_XML="$(xml_escape "$APPCAST_URL")"
SPARKLE_PUBLIC_ED_KEY_XML="$(xml_escape "$SPARKLE_PUBLIC_ED_KEY")"
SPARKLE_KEY_PLIST=""
if [ -n "$SPARKLE_PUBLIC_ED_KEY" ]; then
  SPARKLE_KEY_PLIST="  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_ED_KEY_XML</string>"
fi
cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME_XML</string>
  <key>CFBundleIdentifier</key>
  <string>ai.standardagents.cursorapi</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME_XML</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME_XML</string>
  <key>CFBundleGetInfoString</key>
  <string>$APP_INFO_XML</string>
  <key>CFBundleIconFile</key>
  <string>APIForCursor</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION_XML</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_XML</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>$APP_COPYRIGHT_XML</string>
  <key>SUFeedURL</key>
  <string>$APPCAST_URL_XML</string>
  <key>SUAutomaticallyUpdate</key>
  <true/>
$SPARKLE_KEY_PLIST
</dict>
</plist>
PLIST
if [ "$CODE_SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$FRAMEWORKS_DIR/Sparkle.framework" >/dev/null
  codesign --force --deep --sign - "$APP_DIR" >/dev/null
else
  codesign --force --deep --options runtime --timestamp --sign "$CODE_SIGN_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework" >/dev/null
  codesign --force --deep --options runtime --timestamp --sign "$CODE_SIGN_IDENTITY" "$APP_DIR" >/dev/null
fi
rm -f "$ROOT_DIR/dist/API for Cursor.zip" "$ROOT_DIR/dist/CursorAPI.zip"
ditto -c -k --keepParent "$APP_DIR" "$ROOT_DIR/dist/API for Cursor.zip"
"$ROOT_DIR/Scripts/verify-package.sh" "$APP_DIR"
echo "$APP_DIR"
