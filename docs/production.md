# Production Release Runbook

API for Cursor ships as a signed macOS DMG and updates through Sparkle.

## Release Architecture

- GitHub Actions builds the app bundle from `macos/CursorAPI`.
- `package-app.sh --release` embeds Sparkle, the local SDK bridge, production metadata, and the appcast URL.
- The package script bundles Node by default for the local SDK bridge, with Bun as the fallback.
- `create-dmg.sh` creates a compressed DMG with the app and `/Applications` shortcut.
- `notarize-dmg.sh` submits the DMG to Apple and staples the ticket.
- `generate-appcast.sh` signs the update with Sparkle EdDSA and writes `appcast.xml`.
- The release workflow uploads the versioned DMG, latest DMG alias, and appcast to Cloudflare R2.
- The Worker serves `/download`, `/releases/...`, and `/appcast.xml` from Cloudflare.

## Local Bridge Lifecycle

In the packaged macOS app the SDK bridge runs as a managed child process.

**Ownership and shutdown sequence:**

- The macOS app launches the bridge child and holds its lifetime.
- The child polls the original parent PID at a configurable cadence (default 1000 ms;
  `CURSOR_SDK_BRIDGE_PARENT_LOSS_POLL_INTERVAL_MS`). When the parent exits or the PID
  changes, shutdown begins.
- During shutdown the bridge rejects new incoming requests immediately.
- In-flight request creation and any cached or pending SDK agents are drained with awaited
  `Symbol.asyncDispose`; a synchronous `close()` call is used only when `asyncDispose` is
  absent.
- Node is given a bounded drain window (default 15000 ms;
  `CURSOR_SDK_BRIDGE_SHUTDOWN_TIMEOUT_MS`) before exiting.
- The run timeout is 180000 ms by default (`CURSOR_SDK_BRIDGE_RUN_TIMEOUT_MS`); the packaged
  macOS app explicitly overrides this to 120000 ms.
- The Swift app waits 16000 ms (the Node drain bound of 15000 ms plus 1000 ms extra grace)
  before sending SIGKILL.

**Recovery:**

Two retry layers are active.

Inside the bridge, SDK-run errors that occur before any event is emitted are retried up to
`maxRunRetries` times (default 3; configurable via `CURSOR_SDK_BRIDGE_MAX_RUN_RETRIES`). The
`attempt` counter starts at 0; retries continue while `attempt < maxRunRetries`, yielding at
most 4 SDK-run attempts per bridge call.

At the Swift app layer (`bridgeTransportAttempts = 2`), only retryable pre-output failures
recycle the owned bridge once: transport-level failures and known
`503`/`cursor_sdk_unavailable` stale-state errors that occur before any text or tool output
has been produced. The recycled bridge handles one final attempt. If that also fails, the
`CursorAPIError`/OpenAI-compatible error is returned unchanged.

The bridge is shared by all local SDK sessions. Recycling it is therefore process-wide:
shutdown disposes every cached agent and can interrupt unrelated concurrent requests.
This is an intentional recovery trade-off for the local macOS service so stale or
poisoned SDK process state is removed completely; interrupted callers receive the normal
error contract and can retry.

Auth failures, arbitrary upstream errors, and any failure after output has begun are never
retried at either layer.

**Verification:**

- Node lifecycle suite: `npx vitest run scripts/cursor-sdk-local-agent-bridge.test.mjs`
  must pass.
- Swift build: `swift build -c release` from `macos/CursorAPI` (core and production-seam
  typecheck green).
- Swift XCTest: requires a full Xcode installation with the XCTest framework; Command Line
  Tools alone cannot execute `.xctest` bundles. Run via Xcode or `xcodebuild test`.
- No live credentialed model call was performed during lifecycle fix verification.

**Dependency decision recorded 2026-07-12:**

Lockfile remains at `@cursor/sdk 1.0.13`. Official `1.0.23` was evaluated: it retains a
non-awaited `close()` path while `asyncDispose` correctly awaits, and it raises the Node
engine requirement to `>=22.13`. The update was deferred; it does not fix the lifecycle root
cause alone and requires a runtime version bump. No package or lockfile change was made.
Re-evaluate this decision when changing the SDK lockfile or the bundled Node runtime.

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
- `NOTARY_WEBHOOK_TOKEN` (optional): unguessable token used to build the Apple
  notarization webhook URL for slow notarization jobs.

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

- `https://api-for-cursor.standardagents.ai/download`
- `https://api-for-cursor.standardagents.ai/appcast.xml`
- `https://api-for-cursor.standardagents.ai/releases/<dmg-name>`

Release workflows must pass `--remote` to `wrangler r2 object put`; without it,
Wrangler writes to the local development R2 store and the public routes continue
to return 404.

The old hosted API domain remains configured until the cutover is verified. Do not add redirects or delete hosted API routes until the local app release is confirmed.

For webhook-based notarization finalization, configure these Worker secrets:

```bash
npx wrangler secret put WAITLIST_API_TOKEN
npx wrangler secret put NOTARY_WEBHOOK_TOKEN
npx wrangler secret put GITHUB_RELEASE_DISPATCH_TOKEN
```

`WAITLIST_API_TOKEN` forwards Standard Agents early-access submissions to the
shared waitlist API.
`NOTARY_WEBHOOK_TOKEN` must match the GitHub secret with the same name.
`GITHUB_RELEASE_DISPATCH_TOKEN` should be a fine-grained GitHub token that can
create repository dispatch events for `standardagents/composer-api`. The Worker
uses it only to trigger the `Finalize notarized macOS release` workflow after
Apple posts a notary completion webhook.

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

The `Release macOS app` workflow builds, signs, notarizes, generates the
appcast, uploads to R2, and attaches release assets to the GitHub release.

Apple notarization is bounded by `APPLE_NOTARY_TIMEOUT`, defaulting to `45m`.
When `NOTARY_WEBHOOK_TOKEN` is configured, the release workflow submits the DMG
with an Apple notary webhook and uploads a short-lived pending artifact before
waiting. If Apple accepts quickly, the workflow publishes inline. If Apple is
still processing when the timeout is reached, the workflow exits successfully as
pending; Apple's webhook wakes the `Finalize notarized macOS release` workflow,
which verifies the submission with Apple, staples the pending DMG, generates the
Sparkle appcast, uploads release files to R2, and attaches GitHub release
assets. If Apple rejects a DMG, the notary log is printed so the invalid binary,
entitlement, or signing issue is visible in Actions output.

## Verify A Release

Run the public release gate:

```bash
scripts/verify-production-release.sh
```

1. Download from `/download`.
2. Mount the DMG and drag the app to `/Applications`.
3. Launch the app and confirm macOS does not show an unidentified developer warning.
4. Confirm `Check for Updates...` reaches `/appcast.xml`.
5. Confirm `/v1/models`, `/v1/chat/completions`, and `/v1/responses` work from the local base URL.
6. Confirm OpenCode and Codex installed providers point at `http://127.0.0.1:<port>/v1`.

Only after those checks should the hosted API endpoint be redirected or removed.
