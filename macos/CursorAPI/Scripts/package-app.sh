#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$RESOURCES_DIR/APIForCursor.iconset"
REQUIRE_BUNDLED_TRANSPORT="${CURSOR_API_REQUIRE_BUNDLED_TRANSPORT:-0}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release)
      REQUIRE_BUNDLED_TRANSPORT=1
      ;;
    --development)
      REQUIRE_BUNDLED_TRANSPORT=0
      ;;
    -h|--help)
      cat <<USAGE
Usage: $0 [--development|--release]

  --development  Build a local development app. Missing bundled transport defaults
                 are allowed and the app will show Transport Missing. This is the
                 default.
  --release      Refuse to package unless complete bundled Composer transport
                 defaults are available from local environment files or the
                 current environment.
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

swift build --package-path "$ROOT_DIR" -c release
rm -rf "$APP_DIR" "$LEGACY_APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/CursorAPI" "$MACOS_DIR/$EXECUTABLE_NAME"
if [ -d "$BUILD_DIR/CursorAPI_CursorAPI.bundle" ]; then
  cp -R "$BUILD_DIR/CursorAPI_CursorAPI.bundle" "$RESOURCES_DIR/"
fi
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

func firstRegexCapture(_ pattern: String, in text: String, startingAt startOffset: Int = 0) -> String? {
    guard startOffset >= 0, startOffset < text.utf16.count,
          let regex = try? NSRegularExpression(pattern: pattern) else {
        return nil
    }
    let range = NSRange(location: startOffset, length: text.utf16.count - startOffset)
    guard let match = regex.firstMatch(in: text, range: range),
          match.numberOfRanges > 1,
          let captureRange = Range(match.range(at: 1), in: text) else {
        return nil
    }
    return String(text[captureRange])
}

func inferSDKTransportDefaults(repositoryDirectory: URL) -> [String: String] {
    let sdkBundleCandidates = [
        repositoryDirectory.appendingPathComponent("node_modules/@cursor/sdk/dist/esm/index.js"),
        repositoryDirectory.appendingPathComponent("node_modules/@cursor/sdk/dist/cjs/index.js")
    ]
    guard let bundleURL = sdkBundleCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
          let bundleText = try? String(contentsOf: bundleURL, encoding: .utf8) else {
        return [:]
    }

    var values: [String: String] = [:]
    if let backend = firstRegexCapture(#"CURSOR_BACKEND_URL[^"']{0,240}["'](https?://[^"']+)["']"#, in: bundleText) {
        values["backendBaseURL"] = backend
        values["cursorAPIBaseURL"] = backend
    }

    if let serviceOffset = bundleText.range(of: "AgentService")?.lowerBound {
        let startOffset = NSRange(serviceOffset..<bundleText.endIndex, in: bundleText).location
        let service = firstRegexCapture(#"AgentService\s*=\s*\{typeName:"([^"]+)""#, in: bundleText, startingAt: startOffset)
        let method = firstRegexCapture(#"AgentService\s*=\s*\{typeName:"[^"]+",methods:\{run:\{name:"([^"]+)""#, in: bundleText, startingAt: startOffset)
        if let service, let method {
            values["localAgentEndpoint"] = "/\(service)/\(method)"
        }
    }

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
    ("CURSOR_API_BASE", "cursorAPIBaseURL"),
    ("CURSOR_BACKEND_BASE_URL", "backendBaseURL"),
    ("CURSOR_LOCAL_AGENT_ENDPOINT", "localAgentEndpoint"),
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
for key in ["backendBaseURL", "cursorAPIBaseURL", "localAgentEndpoint", "clientVersion"] {
    if defaults[key] == nil, let value = inferredDefaults[key] {
        defaults[key] = value
        usedInferredDefaults = true
    }
}

let requiredKeys = ["cursorAPIBaseURL", "backendBaseURL", "localAgentEndpoint"]
let missingKeys = requiredKeys.filter { defaults[$0] == nil }
let hasCompleteRouting = missingKeys.isEmpty
if hasCompleteRouting {
    let outputURL = resourcesDirectory.appendingPathComponent("CursorAPITransportDefaults.plist")
    guard NSDictionary(dictionary: defaults).write(to: outputURL, atomically: true) else {
        FileHandle.standardError.write(Data("Could not write bundled Composer routing defaults.\n".utf8))
        exit(1)
    }
    print(usedInferredDefaults ? "Embedded bundled Composer transport defaults from installed SDK metadata." : "Embedded bundled Composer transport defaults.")
} else {
    let message = "No complete bundled Composer transport defaults found; missing \(missingKeys.joined(separator: ", "))."
    let required = ["1", "true", "yes"].contains((environment["CURSOR_API_REQUIRE_BUNDLED_TRANSPORT"] ?? "").lowercased())
    if required {
        FileHandle.standardError.write(Data("\(message) Refusing release package.\n".utf8))
        exit(2)
    }
    print("\(message) This build will show Transport Missing.")
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

    let tileRect = bounds.insetBy(dx: size * 0.085, dy: size * 0.085)
    let radius = size * 0.205
    let tilePath = CGPath(roundedRect: tileRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -size * 0.022),
        blur: size * 0.06,
        color: CGColor(gray: 0, alpha: 0.30)
    )
    context.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.018, alpha: 1))
    context.addPath(tilePath)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    let baseGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.18, green: 0.18, blue: 0.17, alpha: 1.0),
            CGColor(red: 0.055, green: 0.055, blue: 0.052, alpha: 1.0),
            CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        ] as CFArray,
        locations: [0.0, 0.52, 1.0]
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
            CGColor(red: 0.2, green: 0.56, blue: 1.0, alpha: 0.32),
            CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawRadialGradient(
        accentGradient,
        startCenter: CGPoint(x: tileRect.minX + tileRect.width * 0.25, y: tileRect.maxY - tileRect.height * 0.18),
        startRadius: 0,
        endCenter: CGPoint(x: tileRect.minX + tileRect.width * 0.25, y: tileRect.maxY - tileRect.height * 0.18),
        endRadius: tileRect.width * 0.82,
        options: []
    )

    context.addPath(CGPath(roundedRect: tileRect.insetBy(dx: size * 0.012, dy: size * 0.012), cornerWidth: radius * 0.92, cornerHeight: radius * 0.92, transform: nil))
    context.setStrokeColor(CGColor(gray: 1.0, alpha: 0.16))
    context.setLineWidth(max(1, size * 0.008))
    context.strokePath()
    context.restoreGState()

    let markSize = tileRect.width * 0.56
    let center = CGPoint(x: tileRect.midX, y: tileRect.midY + tileRect.height * 0.015)
    let top = CGPoint(x: center.x, y: center.y + markSize * 0.40)
    let right = CGPoint(x: center.x + markSize * 0.42, y: center.y + markSize * 0.17)
    let rightBottom = CGPoint(x: center.x + markSize * 0.42, y: center.y - markSize * 0.30)
    let bottom = CGPoint(x: center.x, y: center.y - markSize * 0.55)
    let leftBottom = CGPoint(x: center.x - markSize * 0.42, y: center.y - markSize * 0.30)
    let left = CGPoint(x: center.x - markSize * 0.42, y: center.y + markSize * 0.17)
    let core = CGPoint(x: center.x, y: center.y - markSize * 0.04)

    func fillPolygon(_ points: [CGPoint], color: CGColor) {
        guard let first = points.first else { return }
        context.beginPath()
        context.move(to: first)
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.closePath()
        context.setFillColor(color)
        context.fillPath()
    }

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -size * 0.010),
        blur: size * 0.020,
        color: CGColor(gray: 0, alpha: 0.38)
    )
    fillPolygon([top, right, core, left], color: CGColor(red: 1.0, green: 1.0, blue: 0.98, alpha: 1.0))
    fillPolygon([left, core, bottom, leftBottom], color: CGColor(red: 0.78, green: 0.79, blue: 0.78, alpha: 1.0))
    fillPolygon([right, rightBottom, bottom, core], color: CGColor(red: 0.92, green: 0.93, blue: 0.91, alpha: 1.0))
    context.restoreGState()

    context.beginPath()
    context.move(to: top)
    for point in [right, rightBottom, bottom, leftBottom, left] {
        context.addLine(to: point)
    }
    context.closePath()
    context.move(to: left)
    context.addLine(to: core)
    context.addLine(to: right)
    context.move(to: core)
    context.addLine(to: bottom)
    context.setStrokeColor(CGColor(gray: 0.02, alpha: 0.28))
    context.setLineWidth(max(1, size * 0.010))
    context.setLineJoin(.round)
    context.strokePath()

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
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP_DIR" >/dev/null
rm -f "$ROOT_DIR/dist/API for Cursor.zip" "$ROOT_DIR/dist/CursorAPI.zip"
ditto -c -k --keepParent "$APP_DIR" "$ROOT_DIR/dist/API for Cursor.zip"
"$ROOT_DIR/Scripts/verify-package.sh" "$APP_DIR"
echo "$APP_DIR"
