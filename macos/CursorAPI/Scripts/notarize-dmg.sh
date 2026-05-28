#!/usr/bin/env bash
set -euo pipefail

DMG_PATH="${1:-}"
NOTARY_PROFILE="${APPLE_NOTARY_KEYCHAIN_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_APP_PASSWORD="${APPLE_APP_PASSWORD:-}"
NOTARY_TIMEOUT="${APPLE_NOTARY_TIMEOUT:-45m}"
NOTARY_WEBHOOK_URL="${APPLE_NOTARY_WEBHOOK_URL:-}"
NOTARY_OUTPUT="${APPLE_NOTARY_OUTPUT:-}"
NOTARY_PENDING_OK="${APPLE_NOTARY_PENDING_OK:-}"

fail() {
  echo "Notarization failed: $*" >&2
  exit 1
}

[ -n "$DMG_PATH" ] || fail "usage: $0 /path/to/API-for-Cursor.dmg"
[ -s "$DMG_PATH" ] || fail "DMG is missing at $DMG_PATH"
command -v xcrun >/dev/null 2>&1 || fail "xcrun is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

NOTARY_AUTH_ARGS=()
if [ -n "$NOTARY_PROFILE" ]; then
  NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "$APPLE_ID" ] && [ -n "$APPLE_TEAM_ID" ] && [ -n "$APPLE_APP_PASSWORD" ]; then
  NOTARY_AUTH_ARGS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
else
  fail "set APPLE_NOTARY_KEYCHAIN_PROFILE or APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD"
fi

NOTARY_SUBMIT_ARGS=()
if [ -n "$NOTARY_WEBHOOK_URL" ]; then
  NOTARY_SUBMIT_ARGS+=(--webhook "$NOTARY_WEBHOOK_URL")
fi

SUBMISSION_JSON="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-notary.XXXXXX.json")"
cleanup() {
  rm -f "$SUBMISSION_JSON"
}
trap cleanup EXIT

set +e
xcrun notarytool submit "$DMG_PATH" \
  "${NOTARY_AUTH_ARGS[@]}" \
  "${NOTARY_SUBMIT_ARGS[@]}" \
  --wait \
  --timeout "$NOTARY_TIMEOUT" \
  --output-format json >"$SUBMISSION_JSON"
submit_status=$?
set -e

read_json_field() {
  local field="$1"
  python3 - "$SUBMISSION_JSON" "$field" <<'PY'
import json
import sys

path, field = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    sys.exit(0)
value = data.get(field)
if value is not None:
    print(value)
PY
}

SUBMISSION_ID="$(read_json_field id)"
SUBMISSION_STATUS="$(read_json_field status)"

write_output() {
  if [ -z "$NOTARY_OUTPUT" ]; then
    return 0
  fi
  {
    printf 'submission_id=%s\n' "$SUBMISSION_ID"
    printf 'submission_status=%s\n' "$SUBMISSION_STATUS"
  } >> "$NOTARY_OUTPUT"
}

write_output

if [ "$SUBMISSION_STATUS" = "In Progress" ] && [ -n "$NOTARY_PENDING_OK" ]; then
  echo "Notarization submission $SUBMISSION_ID is still in progress; Apple will continue processing it." >&2
  exit 75
fi

if [ "$submit_status" -ne 0 ] || [ "$SUBMISSION_STATUS" != "Accepted" ]; then
  if [ -n "$SUBMISSION_ID" ]; then
    echo "Notarization submission $SUBMISSION_ID ended with status ${SUBMISSION_STATUS:-unknown}." >&2
    xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_AUTH_ARGS[@]}" >&2 || true
  else
    cat "$SUBMISSION_JSON" >&2 || true
  fi
  fail "Apple notarization did not complete successfully within $NOTARY_TIMEOUT"
fi

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"

echo "$DMG_PATH"
