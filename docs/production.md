# Production Release Runbook

API for Cursor ships as a signed macOS DMG and updates through Sparkle.

## Release Architecture

- GitHub Actions builds the app bundle from `macos/CursorAPI`.
- `package-app.sh --release` embeds Sparkle, the local SDK bridge, production metadata, and the appcast URL.
- The package script bundles Bun by default for a smaller bridge runtime, with Node as the fallback.
- `create-dmg.sh` creates a compressed DMG with the app and `/Applications` shortcut.
- `notarize-dmg.sh` submits the DMG to Apple and staples the ticket.
- `generate-appcast.sh` signs the update with Sparkle EdDSA and writes `appcast.xml`.
- The release workflow uploads the versioned DMG, latest DMG alias, and appcast to Cloudflare R2.
- The Worker serves `/download`, `/releases/...`, and `/appcast.xml` from Cloudflare.

## Required GitHub Secrets

- `MACOS_DEVELOPER_ID_CERTIFICATE_BASE64`: base64-encoded Developer ID Application `.p12`.
- `MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD`: password for that `.p12`.
- `MACOS_CODE_SIGN_IDENTITY`: Developer ID Application identity name.
- `APPLE_ID`: Apple ID used by `notarytool`.
- `APPLE_TEAM_ID`: Apple developer team id.
- `APPLE_APP_PASSWORD`: app-specific password for notarization.
- `SPARKLE_PUBLIC_ED_KEY`: Sparkle public EdDSA key embedded in the app.
- `SPARKLE_PRIVATE_KEY`: Sparkle private EdDSA key used to sign updates.
- `CLOUDFLARE_API_TOKEN`: token with Worker deploy and R2 object write permissions.
- `CLOUDFLARE_ACCOUNT_ID`: Cloudflare account id.

The helper script `scripts/set-release-secrets.sh` can load these from
`~/.config/api-for-cursor/release-secrets` with GitHub CLI. It expects the
secret files created during release prep and reads `APPLE_ID`, `APPLE_TEAM_ID`,
and `CLOUDFLARE_ACCOUNT_ID` from either environment variables or matching local
files in that directory.

## Cloudflare Setup

Create the release bucket once:

```bash
npx wrangler r2 bucket create api-for-composer-releases
```

The Worker binding is named `RELEASES`, and the public routes are:

- `https://api-for-composer.standardagents.ai/download`
- `https://api-for-composer.standardagents.ai/appcast.xml`
- `https://api-for-composer.standardagents.ai/releases/<dmg-name>`

The old hosted API domain remains configured until the cutover is verified. Do not add redirects or delete hosted API routes until the local app release is confirmed.

## Cut A Release

The `Package macOS smoke` workflow should be green on the commit being released.
It builds the development app bundle, verifies Sparkle and the bundled bridge
runtime, creates a DMG, and generates a signed appcast smoke file with a
throwaway Sparkle key without requiring Apple signing credentials.

Tag a release:

```bash
git status --short
git tag v0.1.0
git push origin v0.1.0
```

Always tag the commit that contains the release workflow and packaging changes
you intend to ship. If a previous tag already exists or points at an older
commit, cut a new version tag instead of rerunning the stale tag workflow.

The `Release macOS app` workflow builds, signs, notarizes, generates the appcast, uploads to R2, and attaches release assets to the GitHub release.

## Verify A Release

1. Download from `/download`.
2. Mount the DMG and drag the app to `/Applications`.
3. Launch the app and confirm macOS does not show an unidentified developer warning.
4. Confirm `Check for Updates...` reaches `/appcast.xml`.
5. Confirm `/v1/models`, `/v1/chat/completions`, and `/v1/responses` work from the local base URL.
6. Confirm OpenCode and Codex installed providers point at `http://127.0.0.1:<port>/v1`.

Only after those checks should the hosted API endpoint be redirected or removed.
