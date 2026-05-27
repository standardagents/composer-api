#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/API for Cursor.app"
TIMEOUT_SECONDS=45
RUN_OPENCODE=1
RUN_DEEP_OPENCODE=0
KEEP_RUNNING=0
TEMP_DIRS=()
TEMP_FILES=()

usage() {
  cat <<USAGE
Usage: CURSOR_API_TEST_KEY=crsr_... $0 [--app PATH] [--timeout SECONDS] [--skip-opencode] [--deep-opencode] [--keep-running]

Launch the packaged macOS app and verify the live Composer routing path using
an environment-provided Cursor API key. This checks direct chat completions,
streaming chat completions, Responses API output, SDK bridge process reuse, and
OpenCode interactive tool/file-write round trips when opencode and tmux are
installed.

  --app PATH        App bundle to launch. Defaults to dist/API for Cursor.app.
  --timeout N       Seconds to wait for app and live requests. Default: 45.
  --skip-opencode   Skip the interactive OpenCode check.
  --deep-opencode   Also run a longer OpenCode Vite/React project build.
  --keep-running    Leave the launched app running after the smoke check.
USAGE
}

fail() {
  echo "Live routing smoke check failed: $*" >&2
  exit 1
}

absolute_path() {
  local path="$1"
  local dir
  local base
  dir="$(cd "$(dirname "$path")" && pwd)"
  base="$(basename "$path")"
  printf '%s/%s\n' "$dir" "$base"
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
    --skip-opencode)
      RUN_OPENCODE=0
      ;;
    --deep-opencode)
      RUN_DEEP_OPENCODE=1
      ;;
    --keep-running)
      KEEP_RUNNING=1
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

[ -n "${CURSOR_API_TEST_KEY:-}" ] || fail "set CURSOR_API_TEST_KEY to a Cursor API key before running this live smoke check"
[ -d "$APP_PATH" ] || fail "app bundle is missing at $APP_PATH"
APP_PATH="$(absolute_path "$APP_PATH")"

JS_RUNTIME="$APP_PATH/Contents/Resources/node"
if [ ! -x "$JS_RUNTIME" ]; then
  JS_RUNTIME="$APP_PATH/Contents/Resources/bun"
fi
if [ ! -x "$JS_RUNTIME" ]; then
  JS_RUNTIME="$(command -v node || command -v bun || true)"
fi
[ -x "$JS_RUNTIME" ] || fail "Bun or Node is required for JSON assertions; package the app or install one locally"

cleanup() {
  for file in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
    rm -f "$file" || true
  done
  for dir in "${TEMP_DIRS[@]+"${TEMP_DIRS[@]}"}"; do
    rm -rf "$dir" || true
  done
  if [ "$KEEP_RUNNING" -eq 0 ]; then
    osascript -e 'tell application id "ai.standardagents.cursorapi" to quit' >/dev/null 2>&1 || true
    pkill -f 'cursor-sdk-local-agent-bridge.mjs' >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

osascript -e 'tell application id "ai.standardagents.cursorapi" to quit' >/dev/null 2>&1 || true
pkill -f 'cursor-sdk-local-agent-bridge.mjs' >/dev/null 2>&1 || true
sleep 0.5

smoke_output="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-live-app.XXXXXX")"
TEMP_FILES+=("$smoke_output")
"$ROOT_DIR/Scripts/smoke-app.sh" --app "$APP_PATH" --require-server --keep-running --timeout "$TIMEOUT_SECONDS" >"$smoke_output"
cat "$smoke_output"

port="$(sed -nE 's/.*http:\/\/127\.0\.0\.1:([0-9]+)\/health.*/\1/p' "$smoke_output" | head -1)"
[ -n "$port" ] || fail "could not determine local API port from app smoke output"
base_url="http://127.0.0.1:$port/v1"

post_json() {
  local path="$1"
  local body="$2"
  curl -fsS --max-time "$TIMEOUT_SECONDS" "$base_url$path" \
    -H "Authorization: Bearer $CURSOR_API_TEST_KEY" \
    -H "Content-Type: application/json" \
    -d "$body"
}

extract_chat_content() {
  "$JS_RUNTIME" -e '
let body = "";
process.stdin.on("data", (chunk) => body += chunk);
process.stdin.on("end", () => {
  const json = JSON.parse(body);
  process.stdout.write(json.choices?.[0]?.message?.content?.trim() || "");
});
'
}

extract_response_text() {
  "$JS_RUNTIME" -e '
let body = "";
process.stdin.on("data", (chunk) => body += chunk);
process.stdin.on("end", () => {
  const json = JSON.parse(body);
  let text = json.output_text || "";
  if (!text && Array.isArray(json.output)) {
    text = json.output.flatMap((item) => item.content || []).map((content) => content.text || "").join("");
  }
  process.stdout.write(text.trim());
});
'
}

extract_stream_text() {
  "$JS_RUNTIME" -e '
let body = "";
process.stdin.on("data", (chunk) => body += chunk);
process.stdin.on("end", () => {
  let text = "";
  let done = false;
  for (const line of body.split(/\r?\n/)) {
    if (!line.startsWith("data:")) continue;
    const payload = line.slice(5).trim();
    if (payload === "[DONE]") {
      done = true;
      continue;
    }
    if (!payload) continue;
    const json = JSON.parse(payload);
    text += json.choices?.[0]?.delta?.content || "";
  }
  if (!done) process.exit(2);
  process.stdout.write(text.trim());
});
'
}

chat_body='{"model":"composer-2.5-fast","messages":[{"role":"user","content":"Reply exactly: hello"}],"stream":false}'
chat_content="$(post_json "/chat/completions" "$chat_body" | extract_chat_content)"
[ "$chat_content" = "hello" ] || fail "chat completions returned '$chat_content', expected hello"

stream_body='{"model":"composer-2.5-fast","messages":[{"role":"user","content":"Reply exactly: hello"}],"stream":true,"stream_options":{"include_usage":true}}'
stream_content="$(post_json "/chat/completions" "$stream_body" | extract_stream_text)"
[ "$stream_content" = "hello" ] || fail "streaming chat returned '$stream_content', expected hello"

responses_body='{"model":"composer-2.5-fast","input":"Reply exactly: hello","stream":false}'
responses_content="$(post_json "/responses" "$responses_body" | extract_response_text)"
[ "$responses_content" = "hello" ] || fail "Responses API returned '$responses_content', expected hello"

bridge_process_count() {
  ps ax -o command= \
    | grep -F "cursor-sdk-local-agent-bridge.mjs" \
    | grep -F "$APP_PATH/Contents/Resources/" \
    | grep -v grep \
    | wc -l \
    | tr -d " "
}

verify_deep_opencode_todo_app() {
  local deep_timeout="$TIMEOUT_SECONDS"
  if [ "$deep_timeout" -lt 180 ]; then
    deep_timeout=180
  fi

  local deep_project
  local deep_output
  local deep_build_output
  deep_project="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-live-opencode-deep-project.XXXXXX")"
  deep_output="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-live-opencode-deep-run.XXXXXX")"
  deep_build_output="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-live-opencode-deep-build.XXXXXX")"
  TEMP_DIRS+=("$deep_project")
  TEMP_FILES+=("$deep_output" "$deep_build_output")

  (
    cd "$deep_project"
    HOME="$temp_home" XDG_CONFIG_HOME="$temp_config" \
      opencode --pure run --agent build --model cursorapi/composer-2.5-fast --format json --dangerously-skip-permissions \
        "Build a todo app in Vite 8 and React. Create the files in this empty project, install or declare any needed package scripts, and keep it minimal but runnable."
  ) >"$deep_output" 2>&1 &
  local deep_pid=$!
  local deadline=$((SECONDS + deep_timeout))
  while kill -0 "$deep_pid" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill "$deep_pid" >/dev/null 2>&1 || true
      wait "$deep_pid" >/dev/null 2>&1 || true
      tail -120 "$deep_output"
      fail "OpenCode deep Vite/React build did not finish before timeout"
    fi
    sleep 1
  done
  wait "$deep_pid" >/dev/null 2>&1 || true

  if grep -E "SchemaError|Invalid tool|tool_use_error|missing.*required|NoSuchTool" "$deep_output" >/dev/null; then
    tail -160 "$deep_output"
    fail "OpenCode deep Vite/React build reported a tool/schema error"
  fi

  [ -f "$deep_project/package.json" ] || fail "OpenCode deep build did not create package.json"
  [ -f "$deep_project/index.html" ] || fail "OpenCode deep build did not create index.html"
  if [ ! -f "$deep_project/src/App.jsx" ] && [ ! -f "$deep_project/src/App.tsx" ]; then
    fail "OpenCode deep build did not create a React App component"
  fi
  grep -F '"vite"' "$deep_project/package.json" >/dev/null || fail "OpenCode deep build package.json does not declare Vite"
  grep -F '"react"' "$deep_project/package.json" >/dev/null || fail "OpenCode deep build package.json does not declare React"
  grep -F '"build"' "$deep_project/package.json" >/dev/null || fail "OpenCode deep build package.json does not declare a build script"

  (cd "$deep_project" && npm install --no-audit --fund=false) >"$deep_build_output" 2>&1 \
    || { cat "$deep_build_output"; fail "OpenCode deep build dependencies could not be installed"; }
  (cd "$deep_project" && npm run build) >"$deep_build_output" 2>&1 \
    || { cat "$deep_build_output"; fail "OpenCode deep Vite/React app did not build"; }

  grep -F '"tool":"bash"' "$deep_output" >/dev/null || fail "OpenCode deep build did not execute local tools"
  echo "Verified live OpenCode deep Vite/React app build through API for Cursor."
}

bridge_count="$(bridge_process_count)"
[ "$bridge_count" = "1" ] || fail "expected one shared SDK bridge process, found $bridge_count"
echo "Verified direct chat, streaming chat, Responses API, and one shared SDK bridge process."

if command -v pi >/dev/null 2>&1; then
  pi_home="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-live-pi-home.XXXXXX")"
  TEMP_DIRS+=("$pi_home")
  pi_agent_dir="$pi_home/.pi/agent"
  mkdir -p "$pi_agent_dir"
  pi_config_file="$pi_agent_dir/models.json"
  sed \
    -e "s#__BASE_URL__#$base_url#g" \
    -e "s#__API_KEY__#$CURSOR_API_TEST_KEY#g" >"$pi_config_file" <<'JSON'
{
  "providers": {
    "cursorapi": {
      "baseUrl": "__BASE_URL__",
      "apiKey": "__API_KEY__",
      "authHeader": true,
      "api": "openai-completions",
      "models": [
        {
          "id": "composer-2.5-fast",
          "name": "Composer 2.5 Fast",
          "api": "openai-completions",
          "reasoning": false,
          "input": ["text"],
          "contextWindow": 200000,
          "maxTokens": 65536,
          "cost": { "input": 3, "output": 15, "cacheRead": 0, "cacheWrite": 0 },
          "limit": { "context": 200000, "output": 65536 },
          "compat": {
            "supportsUsageInStreaming": true,
            "maxTokensField": "max_tokens",
            "requiresAssistantAfterToolResult": false
          }
        }
      ]
    }
  }
}
JSON
  pi_output="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-live-pi-run.XXXXXX")"
  TEMP_FILES+=("$pi_output")
  (
    HOME="$pi_home" PI_CODING_AGENT_DIR="$pi_agent_dir" \
      pi --provider cursorapi --model composer-2.5-fast --no-session -p "Reply exactly: pismoke" >"$pi_output" 2>&1
  ) &
  pi_pid=$!
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while kill -0 "$pi_pid" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill "$pi_pid" >/dev/null 2>&1 || true
      wait "$pi_pid" >/dev/null 2>&1 || true
      fail "pi live run did not finish before timeout"
    fi
    sleep 0.5
  done
  wait "$pi_pid" >/dev/null 2>&1 || true
  cat "$pi_output"
  grep -F "pismoke" "$pi_output" >/dev/null || fail "pi did not surface the live Composer response"
  echo "Verified live pi response through API for Cursor."

  pi_tool_project="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-live-pi-tool-project.XXXXXX")"
  pi_tool_output="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-live-pi-tool-run.XXXXXX")"
  TEMP_DIRS+=("$pi_tool_project")
  TEMP_FILES+=("$pi_tool_output")
  (
    cd "$pi_tool_project"
    HOME="$pi_home" PI_CODING_AGENT_DIR="$pi_agent_dir" \
      pi --provider cursorapi --model composer-2.5-fast --no-session -p \
        "Use your write tool to create pi-tool-smoke.txt in the current directory containing exactly PI_TOOL_OK. Then reply exactly: PI_TOOL_DONE" >"$pi_tool_output" 2>&1
  ) &
  pi_tool_pid=$!
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while kill -0 "$pi_tool_pid" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill "$pi_tool_pid" >/dev/null 2>&1 || true
      wait "$pi_tool_pid" >/dev/null 2>&1 || true
      cat "$pi_tool_output"
      fail "pi live tool run did not finish before timeout"
    fi
    sleep 0.5
  done
  wait "$pi_tool_pid" >/dev/null 2>&1 || true
  cat "$pi_tool_output"
  [ -f "$pi_tool_project/pi-tool-smoke.txt" ] || fail "pi did not create the live tool smoke file"
  [ "$(cat "$pi_tool_project/pi-tool-smoke.txt")" = "PI_TOOL_OK" ] || fail "pi live tool smoke file had unexpected contents"
  grep -F "PI_TOOL_DONE" "$pi_tool_output" >/dev/null || fail "pi did not finish after live tool execution"
  echo "Verified live pi tool execution through API for Cursor."
else
  echo "Skipping live pi check; pi is not installed."
fi

if command -v codex >/dev/null 2>&1; then
  codex_home="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-live-codex-home.XXXXXX")"
  codex_project="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-live-codex-project.XXXXXX")"
  TEMP_DIRS+=("$codex_home" "$codex_project")
  mkdir -p "$codex_home/.codex"
  codex_config_file="$codex_home/.codex/config.toml"
  sed \
    -e "s#__BASE_URL__#$base_url#g" \
    -e "s#__API_KEY__#$CURSOR_API_TEST_KEY#g" >"$codex_config_file" <<'TOML'
[model_providers.cursorapi]
name = "API for Cursor"
base_url = "__BASE_URL__"
wire_api = "responses"

[model_providers.cursorapi.auth]
command = "/bin/echo"
args = ["__API_KEY__"]
refresh_interval_ms = 300000

[profiles.cursorapi-fast]
model_provider = "cursorapi"
model = "composer-2.5-fast"
TOML
  codex_output="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-live-codex-run.XXXXXX")"
  codex_last_message="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-live-codex-last-message.XXXXXX")"
  TEMP_FILES+=("$codex_output" "$codex_last_message")
  (
    cd "$codex_project"
    HOME="$codex_home" CODEX_HOME="$codex_home/.codex" \
      codex -a never -s read-only exec \
        --skip-git-repo-check \
        --ignore-rules \
        --ephemeral \
        --profile cursorapi-fast \
        --output-last-message "$codex_last_message" \
        "Reply exactly: codexsmoke" >"$codex_output" 2>&1
  ) &
  codex_pid=$!
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while kill -0 "$codex_pid" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill "$codex_pid" >/dev/null 2>&1 || true
      wait "$codex_pid" >/dev/null 2>&1 || true
      fail "Codex live run did not finish before timeout"
    fi
    sleep 0.5
  done
  wait "$codex_pid" >/dev/null 2>&1 || true
  cat "$codex_output"
  grep -F "provider: cursorapi" "$codex_output" >/dev/null || fail "Codex did not use the cursorapi provider"
  grep -F "model: composer-2.5-fast" "$codex_output" >/dev/null || fail "Codex did not use the Composer fast model"
  if ! grep -F "codexsmoke" "$codex_last_message" "$codex_output" >/dev/null; then
    fail "Codex did not surface the live Composer response"
  fi
  if grep -F "ERROR:" "$codex_output" >/dev/null; then
    fail "Codex live run reported an error"
  fi
  echo "Verified live Codex response through API for Cursor."

  codex_tool_project="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-live-codex-tool-project.XXXXXX")"
  codex_tool_output="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-live-codex-tool-run.XXXXXX")"
  codex_tool_last_message="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-live-codex-tool-last-message.XXXXXX")"
  TEMP_DIRS+=("$codex_tool_project")
  TEMP_FILES+=("$codex_tool_output" "$codex_tool_last_message")
  (
    cd "$codex_tool_project"
    HOME="$codex_home" CODEX_HOME="$codex_home/.codex" \
      codex -a never -s workspace-write exec \
        --skip-git-repo-check \
        --ignore-rules \
        --ephemeral \
        --profile cursorapi-fast \
        --output-last-message "$codex_tool_last_message" \
        "Create a file named codex-tool-smoke.txt in the current directory containing exactly CODEX_TOOL_OK. Then reply exactly: CODEX_TOOL_DONE" >"$codex_tool_output" 2>&1
  ) &
  codex_tool_pid=$!
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while kill -0 "$codex_tool_pid" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill "$codex_tool_pid" >/dev/null 2>&1 || true
      wait "$codex_tool_pid" >/dev/null 2>&1 || true
      cat "$codex_tool_output"
      fail "Codex live tool run did not finish before timeout"
    fi
    sleep 0.5
  done
  wait "$codex_tool_pid" >/dev/null 2>&1 || true
  cat "$codex_tool_output"
  [ -f "$codex_tool_project/codex-tool-smoke.txt" ] || fail "Codex did not create the live tool smoke file"
  [ "$(cat "$codex_tool_project/codex-tool-smoke.txt")" = "CODEX_TOOL_OK" ] || fail "Codex live tool smoke file had unexpected contents"
  if ! grep -F "CODEX_TOOL_DONE" "$codex_tool_last_message" "$codex_tool_output" >/dev/null; then
    fail "Codex did not finish after live tool execution"
  fi
  echo "Verified live Codex tool execution through API for Cursor."
else
  echo "Skipping live Codex check; codex is not installed."
fi

if [ "$RUN_OPENCODE" -eq 1 ]; then
  if ! command -v opencode >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1; then
    echo "Skipping live OpenCode check; opencode or tmux is not installed."
    exit 0
  fi

  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-live-opencode-home.XXXXXX")"
  temp_config="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-live-opencode-config.XXXXXX")"
  temp_project="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-live-opencode-project.XXXXXX")"
  TEMP_DIRS+=("$temp_home" "$temp_config" "$temp_project")
  mkdir -p "$temp_config/opencode"

  config_file="$temp_config/opencode/opencode.json"
  TEMP_FILES+=("$config_file")
  sed \
    -e "s#__BASE_URL__#$base_url#g" \
    -e "s#__API_KEY__#$CURSOR_API_TEST_KEY#g" >"$config_file" <<'JSON'
{
  "provider": {
    "cursorapi": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "API for Cursor",
      "options": {
        "baseURL": "__BASE_URL__",
        "apiKey": "__API_KEY__"
      },
      "models": {
        "composer-2.5-fast": {
          "name": "Composer 2.5 Fast",
          "cost": { "input": 3, "output": 15 },
          "limit": { "context": 200000, "output": 65536 }
        }
      }
    }
  }
}
JSON

  models_output="$(cd "$temp_project" && HOME="$temp_home" XDG_CONFIG_HOME="$temp_config" opencode --pure models cursorapi 2>&1)"
  printf '%s\n' "$models_output"
  grep -F "cursorapi/composer-2.5-fast" <<<"$models_output" >/dev/null || fail "OpenCode did not list composer-2.5-fast"

  glob_project="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-live-opencode-glob-project.XXXXXX")"
  glob_output="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-live-opencode-glob-run.XXXXXX")"
  TEMP_DIRS+=("$glob_project")
  TEMP_FILES+=("$glob_output")
  mkdir -p "$glob_project/src"
  printf 'export const smoke = true\n' > "$glob_project/src/App.tsx"
  printf '{"name":"api-for-cursor-glob-smoke"}\n' > "$glob_project/package.json"
  (
    cd "$glob_project"
    HOME="$temp_home" XDG_CONFIG_HOME="$temp_config" \
      opencode --pure run --agent build --model cursorapi/composer-2.5-fast --format json --dangerously-skip-permissions \
        "Use the glob tool, not bash, to find files matching **/*.tsx in the current project."
  ) >"$glob_output" 2>&1 &
  glob_pid=$!
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  glob_verified=0
  while kill -0 "$glob_pid" >/dev/null 2>&1; do
    if grep -F '"tool":"glob"' "$glob_output" >/dev/null \
      && (grep -F '"pattern":"**/*"' "$glob_output" >/dev/null || grep -F '"pattern":"**/*.tsx"' "$glob_output" >/dev/null) \
      && grep -F 'src/App.tsx' "$glob_output" >/dev/null \
      && ! grep -F "SchemaError" "$glob_output" >/dev/null; then
      glob_verified=1
      kill "$glob_pid" >/dev/null 2>&1 || true
      wait "$glob_pid" >/dev/null 2>&1 || true
      break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill "$glob_pid" >/dev/null 2>&1 || true
      wait "$glob_pid" >/dev/null 2>&1 || true
      tail -80 "$glob_output"
      fail "OpenCode live glob run did not finish before timeout"
    fi
    sleep 0.5
  done
  wait "$glob_pid" >/dev/null 2>&1 || true
  if [ "$glob_verified" -ne 1 ]; then
    tail -80 "$glob_output"
    fail "OpenCode did not execute a valid live glob tool round trip"
  fi
  echo "Verified live OpenCode glob tool schema through API for Cursor."

  webfetch_project="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-live-opencode-webfetch-project.XXXXXX")"
  webfetch_output="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-live-opencode-webfetch-run.XXXXXX")"
  TEMP_DIRS+=("$webfetch_project")
  TEMP_FILES+=("$webfetch_output")
  (
    cd "$webfetch_project"
    HOME="$temp_home" XDG_CONFIG_HOME="$temp_config" \
      opencode --pure run --agent build --model cursorapi/composer-2.5-fast --format json --dangerously-skip-permissions \
        "Use the webfetch tool, not bash, to fetch https://example.com. Do not use bash."
  ) >"$webfetch_output" 2>&1 &
  webfetch_pid=$!
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  webfetch_verified=0
  while kill -0 "$webfetch_pid" >/dev/null 2>&1; do
    if grep -F '"tool":"webfetch"' "$webfetch_output" >/dev/null \
      && grep -F "Example Domain" "$webfetch_output" >/dev/null \
      && ! grep -E '"tool":"bash"|SchemaError|Invalid tool|tool_use_error|NoSuchTool' "$webfetch_output" >/dev/null; then
      webfetch_verified=1
      kill "$webfetch_pid" >/dev/null 2>&1 || true
      wait "$webfetch_pid" >/dev/null 2>&1 || true
      break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill "$webfetch_pid" >/dev/null 2>&1 || true
      wait "$webfetch_pid" >/dev/null 2>&1 || true
      tail -80 "$webfetch_output"
      fail "OpenCode live webfetch run did not finish before timeout"
    fi
    sleep 0.5
  done
  wait "$webfetch_pid" >/dev/null 2>&1 || true
  if [ "$webfetch_verified" -ne 1 ]; then
    tail -80 "$webfetch_output"
    fail "OpenCode did not execute a valid live non-builtin webfetch tool round trip"
  fi
  echo "Verified live OpenCode non-builtin webfetch tool through API for Cursor."

  session="api-for-cursor-live-opencode-$$"
  marker="AFC_TOOL_DONE_$$"
  tool_file="opencode_live_tool_smoke.txt"
  file_marker="AFC_FILE_WRITE_DONE_$$"
  generated_file="rain-in-spain-live.html"
  tmux new-session -d -x 180 -y 56 -s "$session" "cd \"$temp_project\" && HOME=\"$temp_home\" XDG_CONFIG_HOME=\"$temp_config\" opencode --pure run --interactive --dangerously-skip-permissions --model cursorapi/composer-2.5-fast"
  sleep 4
  tmux send-keys -t "$session" "Use the bash tool to run exactly: printf TOOL_OK > $tool_file. After the tool succeeds, reply exactly: $marker" Enter

  deadline=$((SECONDS + TIMEOUT_SECONDS))
  last_capture=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    last_capture="$(tmux capture-pane -t "$session" -p -J -S -200 2>/dev/null || true)"
    marker_count="$( (printf "%s\n" "$last_capture" | grep -F "$marker" || true) | wc -l | tr -d " " )"
    if [ -f "$temp_project/$tool_file" ] \
      && [ "$(cat "$temp_project/$tool_file")" = "TOOL_OK" ] \
      && [ "${marker_count:-0}" -ge 2 ] \
      && printf "%s\n" "$last_capture" | grep -F "API for Cursor" >/dev/null; then
      echo "Verified live OpenCode interactive tool execution through API for Cursor."
      break
    fi
    sleep 1
  done

  if [ ! -f "$temp_project/$tool_file" ] \
    || [ "$(cat "$temp_project/$tool_file" 2>/dev/null || true)" != "TOOL_OK" ] \
    || [ "${marker_count:-0}" -lt 2 ]; then
    printf "%s\n" "$last_capture" | tail -80
    tmux kill-session -t "$session" >/dev/null 2>&1 || true
    fail "OpenCode did not execute the live tool round trip before timeout"
  fi

  tmux send-keys -t "$session" "Create $generated_file in the current project containing a short HTML page about how the rain in Spain falls mainly on the plain. After the tool succeeds, reply exactly: $file_marker" Enter

  deadline=$((SECONDS + TIMEOUT_SECONDS))
  last_capture=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    last_capture="$(tmux capture-pane -t "$session" -p -J -S -260 2>/dev/null || true)"
    file_marker_count="$( (printf "%s\n" "$last_capture" | grep -F "$file_marker" || true) | wc -l | tr -d " " )"
    if [ -f "$temp_project/$generated_file" ] \
      && grep -E "rain in Spain|Rain in Spain|plain" "$temp_project/$generated_file" >/dev/null \
      && [ "${file_marker_count:-0}" -ge 2 ]; then
      tmux kill-session -t "$session" >/dev/null 2>&1 || true
      echo "Verified live OpenCode generic file write through API for Cursor."
      bridge_count="$(bridge_process_count)"
      [ "$bridge_count" = "1" ] || fail "expected one shared SDK bridge process after OpenCode, found $bridge_count"
      if [ "$RUN_DEEP_OPENCODE" -eq 1 ]; then
        verify_deep_opencode_todo_app
      fi
      exit 0
    fi
    sleep 1
  done

  printf "%s\n" "$last_capture" | tail -80
  tmux kill-session -t "$session" >/dev/null 2>&1 || true
  fail "OpenCode did not execute the live generic file write before timeout"
fi
