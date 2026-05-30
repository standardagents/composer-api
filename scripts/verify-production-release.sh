#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${API_FOR_CURSOR_PUBLIC_BASE_URL:-https://api-for-composer.standardagents.ai}"
OLD_API_URL="${API_FOR_CURSOR_OLD_API_URL:-https://cursor-api.standardagents.ai/v1/models}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-release-check.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "Release verification failed: $*" >&2
  exit 1
}

check_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq "$needle" "$file" || fail "$file does not contain: $needle"
}

http_code() {
  local url="$1"
  curl -sS -o /dev/null -w '%{http_code}' "$url"
}

echo "Verifying public site at $BASE_URL"
site_html="$TMP_DIR/site.html"
curl -fsSL "$BASE_URL/" -o "$site_html"
check_contains "$site_html" "API for Cursor"
check_contains "$site_html" "Download for macOS"
check_contains "$site_html" "Looking for the hosted API endpoints?"
check_contains "$site_html" "Use Cursor's models with any harness"
check_contains "$site_html" "OpenCode"
check_contains "$site_html" "Codex"

echo "Verifying download redirect"
download_headers="$TMP_DIR/download.headers"
curl -fsSI "$BASE_URL/download" -o "$download_headers"
check_contains "$download_headers" "releases/API-for-Cursor-latest.dmg"

echo "Verifying appcast"
appcast="$TMP_DIR/appcast.xml"
curl -fsSL "$BASE_URL/appcast.xml" -o "$appcast"
check_contains "$appcast" "sparkle:edSignature="
check_contains "$appcast" "$BASE_URL/releases/"

echo "Verifying latest DMG"
dmg_headers="$TMP_DIR/dmg.headers"
curl -fsSIL "$BASE_URL/releases/API-for-Cursor-latest.dmg" -o "$dmg_headers"
grep -Eiq '^content-type: *(application/x-apple-diskimage|application/octet-stream)' "$dmg_headers" \
  || fail "latest DMG content type is not a disk image"
curl -fsSL --range 0-0 "$BASE_URL/releases/API-for-Cursor-latest.dmg" -o "$TMP_DIR/latest-dmg-byte"
[ -s "$TMP_DIR/latest-dmg-byte" ] || fail "latest DMG range request returned no bytes"

echo "Verifying legacy API host redirects to canonical host"
old_api_code="$(http_code "$OLD_API_URL")"
[ "$old_api_code" = "308" ] || fail "expected legacy API host to redirect with 308, got $old_api_code"
old_api_redirected_code="$(curl -LsS -o /dev/null -w '%{http_code}' "$OLD_API_URL")"
[ "$old_api_redirected_code" = "401" ] || fail "expected redirected API request to remain gated with 401, got $old_api_redirected_code"

echo "Production release verification passed."
