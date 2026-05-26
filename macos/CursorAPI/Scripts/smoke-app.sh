#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/API for Cursor.app"
KEEP_RUNNING=0
REQUIRE_SERVER=0
TIMEOUT_SECONDS=20

usage() {
  cat <<USAGE
Usage: $0 [--app PATH] [--keep-running] [--require-server] [--timeout SECONDS]

Launch the packaged macOS app, verify the main window renders, and verify the
local /health endpoint when the app can start its local API.

  --app PATH        App bundle to launch. Defaults to dist/API for Cursor.app.
  --keep-running   Leave the launched app running after the smoke check.
  --require-server Fail when /health is not available before the timeout.
  --timeout N      Seconds to wait for the window and health checks. Default: 20.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      APP_PATH="${2:-}"
      [ -n "$APP_PATH" ] || { echo "--app requires a path" >&2; exit 64; }
      shift
      ;;
    --keep-running)
      KEEP_RUNNING=1
      ;;
    --require-server)
      REQUIRE_SERVER=1
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2:-}"
      [ -n "$TIMEOUT_SECONDS" ] || { echo "--timeout requires seconds" >&2; exit 64; }
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

fail() {
  echo "App smoke check failed: $*" >&2
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null
}

[ -d "$APP_PATH" ] || fail "app bundle is missing at $APP_PATH"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
[ -f "$INFO_PLIST" ] || fail "Info.plist is missing"

APP_NAME="$(plist_value CFBundleDisplayName "$INFO_PLIST")"
BUNDLE_ID="$(plist_value CFBundleIdentifier "$INFO_PLIST")"
ICON_PATH="$APP_PATH/Contents/Resources/APIForCursor.icns"

[ "$APP_NAME" = "API for Cursor" ] || fail "unexpected app name: $APP_NAME"
[ "$BUNDLE_ID" = "ai.standardagents.cursorapi" ] || fail "unexpected bundle id: $BUNDLE_ID"
[ -s "$ICON_PATH" ] || fail "app icon is missing"

ICON_WIDTH="$(sips -g pixelWidth "$ICON_PATH" 2>/dev/null | awk '/pixelWidth:/ {print $2; exit}')"
ICON_HEIGHT="$(sips -g pixelHeight "$ICON_PATH" 2>/dev/null | awk '/pixelHeight:/ {print $2; exit}')"
[ "$ICON_WIDTH" = "1024" ] || fail "app icon width is $ICON_WIDTH, expected 1024"
[ "$ICON_HEIGHT" = "1024" ] || fail "app icon height is $ICON_HEIGHT, expected 1024"

cleanup() {
  if [ "$KEEP_RUNNING" -eq 0 ]; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
sleep 0.5

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP_PATH" >/dev/null 2>&1 || true
fi

open -n "$APP_PATH"

window_visible() {
  swift - "$APP_NAME" <<'SWIFT'
import CoreGraphics
import Foundation

let appName = CommandLine.arguments[1]
guard let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}

for window in windows {
    guard (window[kCGWindowOwnerName as String] as? String) == appName else { continue }
    guard (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double,
          let height = bounds["Height"] as? Double,
          width >= 700,
          height >= 500 else {
        continue
    }
    exit(0)
}

exit(1)
SWIFT
}

deadline=$((SECONDS + TIMEOUT_SECONDS))
until window_visible; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    fail "main window did not appear"
  fi
  sleep 0.5
done

port_candidates() {
  swift - "$BUNDLE_ID" "$TIMEOUT_SECONDS" <<'SWIFT'
import Foundation

let bundleID = CommandLine.arguments[1]
let defaults = UserDefaults(suiteName: bundleID)
var starts: [Int] = []

if let envPort = ProcessInfo.processInfo.environment["CURSOR_API_PORT"].flatMap(Int.init) {
    starts.append(envPort)
}

if let data = defaults?.data(forKey: "CursorAPI.settings.v1"),
   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let port = object["port"] as? Int {
    starts.append(port)
}

starts.append(8787)

var seen = Set<Int>()
for start in starts {
    for offset in 0..<20 {
        let port = start + offset
        guard port > 0, port <= Int(UInt16.max), !seen.contains(port) else { continue }
        seen.insert(port)
        print(port)
    }
}
SWIFT
}

validate_health() {
  local file="$1"
  local port="$2"
  local service host model_a model_b routing sdk base_url

  service="$(plutil -extract service raw -o - "$file" 2>/dev/null || true)"
  host="$(plutil -extract host raw -o - "$file" 2>/dev/null || true)"
  model_a="$(plutil -extract models.0 raw -o - "$file" 2>/dev/null || true)"
  model_b="$(plutil -extract models.1 raw -o - "$file" 2>/dev/null || true)"
  routing="$(plutil -extract routingConfigured raw -o - "$file" 2>/dev/null || true)"
  sdk="$(plutil -extract sdkConfigured raw -o - "$file" 2>/dev/null || true)"
  base_url="$(plutil -extract baseUrl raw -o - "$file" 2>/dev/null || true)"

  [ "$service" = "$APP_NAME" ] || return 1
  [ "$host" = "127.0.0.1" ] || return 1
  [ "$model_a" = "composer-2.5" ] || return 1
  [ "$model_b" = "composer-2.5-fast" ] || return 1
  [ "$routing" = "true" ] || return 1
  [ "$sdk" = "true" ] || return 1
  [ "$base_url" = "http://127.0.0.1:$port/v1" ] || return 1
}

health_file="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-health.XXXXXX.json")"
trap 'rm -f "$health_file"; cleanup' EXIT

health_found=0
deadline=$((SECONDS + TIMEOUT_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
  while IFS= read -r port; do
    if curl -fsS --connect-timeout 0.08 --max-time 0.25 "http://127.0.0.1:$port/health" -o "$health_file" >/dev/null 2>&1; then
      if validate_health "$health_file" "$port"; then
        status="$(plutil -extract status raw -o - "$health_file" 2>/dev/null || true)"
        echo "Verified $APP_NAME window, icon, and local health endpoint at http://127.0.0.1:$port/health ($status)."
        health_found=1
        break 2
      fi
    fi
  done < <(port_candidates)
  sleep 0.5
done

if [ "$health_found" -eq 0 ]; then
  if [ "$REQUIRE_SERVER" -eq 1 ]; then
    fail "local /health endpoint did not become available"
  fi
  echo "Verified $APP_NAME window and icon. Local /health was not available; this is expected before a Cursor API key is saved."
fi
