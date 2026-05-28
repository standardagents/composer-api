#!/usr/bin/env bash
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-standardagents/composer-api}"
SECRETS_DIR="${API_FOR_CURSOR_RELEASE_SECRETS_DIR:-$HOME/.config/api-for-cursor/release-secrets}"

require_file() {
  local path="$1"
  if [ ! -s "$path" ]; then
    echo "Missing required secret file: $path" >&2
    exit 1
  fi
}

read_value() {
  local env_name="$1"
  local file_name="$2"
  local value="${!env_name:-}"

  if [ -z "$value" ] && [ -s "$SECRETS_DIR/$file_name" ]; then
    value="$(tr -d '\n' < "$SECRETS_DIR/$file_name")"
  fi

  if [ -z "$value" ]; then
    echo "Set $env_name or create $SECRETS_DIR/$file_name" >&2
    exit 1
  fi

  printf '%s' "$value"
}

set_file_secret() {
  local name="$1"
  local file_name="$2"
  local path="$SECRETS_DIR/$file_name"

  require_file "$path"
  gh secret set "$name" --repo "$REPO" < "$path" >/dev/null
  echo "Set $name"
}

set_value_secret() {
  local name="$1"
  local value="$2"

  printf '%s' "$value" | gh secret set "$name" --repo "$REPO" >/dev/null
  echo "Set $name"
}

command -v gh >/dev/null || {
  echo "GitHub CLI is required. Install it or authenticate with: gh auth login -h github.com" >&2
  exit 1
}

gh auth status -h github.com >/dev/null

set_file_secret MACOS_DEVELOPER_ID_CERTIFICATE_BASE64 developer-id-application.p12.b64
set_file_secret MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD developer-id-application.p12.password
set_file_secret MACOS_CODE_SIGN_IDENTITY macos-code-sign-identity.txt
set_file_secret SPARKLE_PUBLIC_ED_KEY sparkle-public-ed25519.key.b64
set_file_secret SPARKLE_PRIVATE_KEY sparkle-private-ed25519.seed.b64
set_file_secret APPLE_APP_PASSWORD apple-app-password.txt
set_file_secret CLOUDFLARE_API_TOKEN cloudflare-api-token.txt

set_value_secret APPLE_ID "$(read_value APPLE_ID apple-id.txt)"
set_value_secret APPLE_TEAM_ID "$(read_value APPLE_TEAM_ID apple-team-id.txt)"
set_value_secret CLOUDFLARE_ACCOUNT_ID "$(read_value CLOUDFLARE_ACCOUNT_ID cloudflare-account-id.txt)"

if [ -n "${NOTARY_WEBHOOK_TOKEN:-}" ] || [ -s "$SECRETS_DIR/notary-webhook-token.txt" ]; then
  set_value_secret NOTARY_WEBHOOK_TOKEN "$(read_value NOTARY_WEBHOOK_TOKEN notary-webhook-token.txt)"
fi

echo "Release secrets are configured for $REPO."
