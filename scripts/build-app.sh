#!/usr/bin/env bash
set -euo pipefail

# Convenience script for local macOS development: package a development app
# bundle and open it. Development builds allow a missing bundled SDK bridge
# and display "SDK Bridge Missing" in the UI until the full bridge is built.

# Kill any running instance so the new build can bind to the port on launch.
pkill -x "API for Cursor" 2>/dev/null && echo "Stopped running instance." || true

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$repo_dir/macos/CursorAPI"

# Ensure the Node dependencies used by the SDK bridge packaging step exist.
if [ ! -d "$repo_dir/node_modules/@cursor/sdk" ]; then
  echo "Installing Node dependencies for the bundled SDK bridge..."
  (cd "$repo_dir" && npm install)
fi

cd "$app_dir"
"$app_dir/Scripts/package-app.sh" --development

APP="dist/API for Cursor.app"
echo ""
echo "Built: $APP"
echo "cd $app_dir"
echo "To launch:  open \"$APP\""
echo "If macOS blocks it:  xattr -dr com.apple.quarantine \"$APP\""

open "$APP"
