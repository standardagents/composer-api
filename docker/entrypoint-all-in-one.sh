#!/bin/sh
set -eu

export CURSOR_SDK_BRIDGE_HOST="${CURSOR_SDK_BRIDGE_HOST:-0.0.0.0}"
export CURSOR_SDK_BRIDGE_PORT="${CURSOR_SDK_BRIDGE_PORT:-8792}"
export CURSOR_SDK_BRIDGE_URL="${CURSOR_SDK_BRIDGE_URL:-http://127.0.0.1:${CURSOR_SDK_BRIDGE_PORT}/sdk}"

node scripts/cursor-sdk-local-agent-bridge.mjs &
BRIDGE_PID=$!

for _ in $(seq 1 60); do
  if node -e "fetch('http://127.0.0.1:${CURSOR_SDK_BRIDGE_PORT}/health').then((r) => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"; then
    break
  fi
  if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    echo "Cursor SDK bridge exited before becoming healthy." >&2
    exit 1
  fi
  sleep 0.5
done

trap 'kill "$BRIDGE_PID" 2>/dev/null || true' EXIT INT TERM

exec docker/entrypoint-api.sh
