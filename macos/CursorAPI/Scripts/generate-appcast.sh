#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
DMG_PATH="${1:-}"
APP_PATH="${2:-$DIST_DIR/API for Cursor.app}"
APPCAST_PATH="${CURSOR_API_APPCAST_PATH:-$DIST_DIR/appcast.xml}"
DOWNLOAD_BASE_URL="${CURSOR_API_RELEASE_BASE_URL:-https://api-for-composer.standardagents.ai/releases}"
SPARKLE_GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-}"
SPARKLE_SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-}"
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-}"

fail() {
  echo "Appcast generation failed: $*" >&2
  exit 1
}

[ -n "$DMG_PATH" ] || fail "usage: $0 /path/to/API-for-Cursor.dmg [/path/to/API for Cursor.app]"
[ -s "$DMG_PATH" ] || fail "DMG is missing at $DMG_PATH"
[ -d "$APP_PATH" ] || fail "app bundle is missing at $APP_PATH"

if [ -n "$SPARKLE_GENERATE_APPCAST" ]; then
  [ -x "$SPARKLE_GENERATE_APPCAST" ] || fail "SPARKLE_GENERATE_APPCAST is not executable"
  RELEASES_DIR="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-appcast.XXXXXX")"
  KEY_FILE=""
  trap 'rm -rf "$RELEASES_DIR" "$KEY_FILE"' EXIT
  cp "$DMG_PATH" "$RELEASES_DIR/"
  args=("--download-url-prefix" "${DOWNLOAD_BASE_URL%/}/")
  if [ -n "$SPARKLE_PRIVATE_KEY" ]; then
    KEY_FILE="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-sparkle-key.XXXXXX")"
    printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    args+=("--ed-key-file" "$KEY_FILE")
  fi
  "$SPARKLE_GENERATE_APPCAST" "${args[@]}" "$RELEASES_DIR"
  [ -s "$RELEASES_DIR/appcast.xml" ] || fail "generate_appcast did not create appcast.xml"
  cp "$RELEASES_DIR/appcast.xml" "$APPCAST_PATH"
  grep -q "${DOWNLOAD_BASE_URL%/}/" "$APPCAST_PATH" || fail "generated appcast is missing the release download URL"
  if [ -n "$SPARKLE_PRIVATE_KEY" ]; then
    grep -q 'sparkle:edSignature=' "$APPCAST_PATH" || fail "generated appcast is missing Sparkle EdDSA signature"
  fi
  echo "$APPCAST_PATH"
  exit 0
fi

[ -n "$SPARKLE_SIGN_UPDATE" ] || fail "set SPARKLE_GENERATE_APPCAST or SPARKLE_SIGN_UPDATE"
[ -x "$SPARKLE_SIGN_UPDATE" ] || fail "SPARKLE_SIGN_UPDATE is not executable"

if [ -n "$SPARKLE_PRIVATE_KEY" ]; then
  SIGNATURE_OUTPUT="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_SIGN_UPDATE" --ed-key-file - "$DMG_PATH")"
else
  SIGNATURE_OUTPUT="$("$SPARKLE_SIGN_UPDATE" "$DMG_PATH")"
fi
ED_SIGNATURE="$(printf '%s\n' "$SIGNATURE_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' | head -1)"
SPARKLE_LENGTH="$(printf '%s\n' "$SIGNATURE_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p' | head -1)"
[ -n "$ED_SIGNATURE" ] || fail "could not parse Sparkle EdDSA signature"
[ -n "$SPARKLE_LENGTH" ] || SPARKLE_LENGTH="$(stat -f%z "$DMG_PATH")"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO_PLIST")"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
DMG_NAME="$(basename "$DMG_PATH")"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

xml_escape() {
  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

cat > "$APPCAST_PATH" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$(xml_escape "$APP_NAME") Updates</title>
    <link>https://api-for-composer.standardagents.ai/</link>
    <description>Updates for $(xml_escape "$APP_NAME").</description>
    <item>
      <title>$(xml_escape "$APP_NAME") $(xml_escape "$APP_VERSION")</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$(xml_escape "$APP_BUILD")</sparkle:version>
      <sparkle:shortVersionString>$(xml_escape "$APP_VERSION")</sparkle:shortVersionString>
      <enclosure
        url="$(xml_escape "$DOWNLOAD_BASE_URL/$DMG_NAME")"
        sparkle:edSignature="$(xml_escape "$ED_SIGNATURE")"
        sparkle:length="$(xml_escape "$SPARKLE_LENGTH")"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

grep -q "${DOWNLOAD_BASE_URL%/}/" "$APPCAST_PATH" || fail "generated appcast is missing the release download URL"
grep -q 'sparkle:edSignature=' "$APPCAST_PATH" || fail "generated appcast is missing Sparkle EdDSA signature"
echo "$APPCAST_PATH"
