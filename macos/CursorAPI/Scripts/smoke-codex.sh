#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/API for Cursor.app"
TIMEOUT_SECONDS=35
TEMP_DIRS=()
TEMP_FILES=()

usage() {
  cat <<USAGE
Usage: $0 [--app PATH] [--timeout SECONDS]

Launch the packaged macOS app, create an isolated Codex config for API for
Cursor, verify Codex can use the custom Responses provider, and verify Codex
surfaces the local API's locked-key response without touching user configs.

  --app PATH    App bundle to launch. Defaults to dist/API for Cursor.app.
  --timeout N   Seconds to wait for app and Codex checks. Default: 35.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      APP_PATH="${2:-}"
      [ -n "$APP_PATH" ] || { echo "--app requires a path" >&2; exit 64; }
      shift
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
  echo "Codex smoke check failed: $*" >&2
  exit 1
}

cleanup() {
  for file in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
    rm -f "$file"
  done
  for dir in "${TEMP_DIRS[@]+"${TEMP_DIRS[@]}"}"; do
    rm -rf "$dir"
  done
  osascript -e 'tell application id "ai.standardagents.cursorapi" to quit' >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! command -v codex >/dev/null 2>&1; then
  echo "Skipping Codex smoke check; codex is not installed."
  exit 0
fi

smoke_output="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-codex-app.XXXXXX")"
TEMP_FILES+=("$smoke_output")

"$ROOT_DIR/Scripts/smoke-app.sh" --app "$APP_PATH" --require-server --keep-running --timeout "$TIMEOUT_SECONDS" >"$smoke_output"
cat "$smoke_output"

port="$(sed -nE 's/.*http:\/\/127\.0\.0\.1:([0-9]+)\/health.*/\1/p' "$smoke_output" | head -1)"
[ -n "$port" ] || fail "could not determine local API port from app smoke output"
status="$(sed -nE 's/.*\(([^()]*)\)\.*/\1/p' "$smoke_output" | head -1)"

temp_home="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-codex-home.XXXXXX")"
temp_project="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-codex-project.XXXXXX")"
TEMP_DIRS+=("$temp_home" "$temp_project")
mkdir -p "$temp_home/.codex"

cat > "$temp_home/.codex/config.toml" <<TOML
[model_providers.cursorapi]
name = "API for Cursor"
base_url = "http://127.0.0.1:$port/v1"
wire_api = "responses"

[model_providers.cursorapi.auth]
command = "/bin/echo"
args = ["cursor-local"]
refresh_interval_ms = 300000

[profiles.cursorapi]
model_provider = "cursorapi"
model = "composer-2.5"

[profiles.cursorapi-fast]
model_provider = "cursorapi"
model = "composer-2.5-fast"
TOML

if [ "$status" != "needs_unlock" ]; then
  echo "Skipping locked-key Codex run check because local API status is $status."
  exit 0
fi

run_output="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-codex-run.XXXXXX")"
last_message="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-codex-last-message.XXXXXX")"
TEMP_FILES+=("$run_output" "$last_message")

(
  cd "$temp_project"
  HOME="$temp_home" CODEX_HOME="$temp_home/.codex" \
    codex -a never -s read-only exec \
      --skip-git-repo-check \
      --ignore-rules \
      --ephemeral \
      --profile cursorapi \
      --output-last-message "$last_message" \
      "say hello" >"$run_output" 2>&1
) &
run_pid=$!
deadline=$((SECONDS + TIMEOUT_SECONDS))
while kill -0 "$run_pid" >/dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    kill "$run_pid" >/dev/null 2>&1 || true
    wait "$run_pid" >/dev/null 2>&1 || true
    fail "Codex run did not finish before timeout"
  fi
  sleep 0.5
done
wait "$run_pid" >/dev/null 2>&1 || true
cat "$run_output"

grep -F "provider: cursorapi" "$run_output" >/dev/null || fail "Codex did not use the cursorapi provider"
grep -F "model: composer-2.5" "$run_output" >/dev/null || fail "Codex did not use the Composer model"
grep -F "http://127.0.0.1:$port/v1/responses" "$run_output" >/dev/null || fail "Codex did not call the local Responses endpoint"
grep -F "Saved Cursor API key is locked" "$run_output" >/dev/null || fail "Codex did not surface the local locked-key response"

echo "Verified Codex can use the isolated API for Cursor custom provider config."
