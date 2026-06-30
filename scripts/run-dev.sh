#!/usr/bin/env bash
set -euo pipefail

# Convenience script for local macOS development: run the Swift package directly
# without building a full app bundle. Useful for fast iteration on the UI or API.

# Kill any running instance so the dev build can bind to the port.
pkill -x "API for Cursor" 2>/dev/null && echo "Stopped running instance." || true

cd "$(dirname "$0")/../macos/CursorAPI"
swift run
