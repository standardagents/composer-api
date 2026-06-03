#!/bin/sh
set -eu

: "${CURSOR_SDK_BRIDGE_URL:=http://bridge:8792/sdk}"

exec npx tsx docker/api-server.ts
