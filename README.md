# API for Cursor

Local OpenAI-compatible `chat.completions` and `responses` endpoints backed by Cursor models (Composer 2.5, Grok 4.6, and more).

Download site: https://api-for-cursor.standardagents.ai

## What this is

Cursor does not expose Composer or other first-party models as a raw OpenAI-compatible model endpoint. API for Cursor now ships as a local macOS app that starts a localhost `/v1` server, stores the Cursor API key locally, and configures local agent tools.

The hosted Worker routes remain in the repository for temporary compatibility while the local app rollout is verified. Cursor has asked us to take down the hosted API path, so the production release path is the signed macOS app.

## Supported endpoints

- `POST /v1/chat/completions`
- `POST /v1/responses`
- `GET /v1/models`

## Models

Primary local model ids:

- `composer-2.5`
- `composer-2.5-fast`
- `grok-4.6`
- `grok-4.6-fast`
- `grok-4.5`
- `grok-4.5-fast`

## Usage

Install the macOS app from the DMG and start the local API. The default base URL is:

```txt
http://127.0.0.1:8787/v1
```

Point any OpenAI-compatible client at the local base URL and authenticate with any Bearer token your client requires. The app uses the Cursor API key stored locally in the app UI.

```ts
import OpenAI from "openai";

const client = new OpenAI({
  apiKey: "local",
  baseURL: "http://127.0.0.1:8787/v1"
});

const completion = await client.chat.completions.create({
  model: "composer-2.5",
  messages: [{ role: "user", content: "Write a TypeScript debounce." }]
});
```

```bash
curl http://127.0.0.1:8787/v1/chat/completions \
  -H "Authorization: Bearer local" \
  -H "Content-Type: application/json" \
  -d '{"model":"composer-2.5","messages":[{"role":"user","content":"Hello"}]}'
```

A Cursor user API key comes from the Cursor Dashboard under Integrations. Enter it in the app; do not commit it to source control.

## macOS production release

Release details live in [docs/production.md](docs/production.md).

- Builds are packaged as a signed DMG.
- DMGs are notarized by Apple.
- Sparkle is embedded for auto-updates.
- Versioned DMGs, the latest DMG alias, and `appcast.xml` are uploaded to Cloudflare R2.
- The Worker serves `/download`, `/releases/...`, and `/appcast.xml`.

## Legacy hosted-key flow (optional)

The Worker also keeps a backward-compatible hosted-key flow: `POST /api/signup`
verifies a Cursor API key, stores it encrypted in D1, and mints a separate
`cmp_...` proxy key usable against per-account endpoints at
`/u/{account_id}/v1/...`. This flow is optional; the direct Bearer usage above
is the recommended path. A `cmp_...` token is always resolved against D1 and is
never forwarded to Cursor as a Cursor key.

## Compatibility notes

This project supports text and image input, non-streaming and streaming output, JSON-output prompt constraints, and the common SDK response shapes. Image inputs can be sent as Chat Completions `image_url` parts or Responses `input_image` parts; each resolved image must be 1MB or smaller.

These OpenAI features are intentionally rejected because Cursor does not expose equivalent OpenAI controls through this path:

- `n` greater than `1`
- `logprobs` and `top_logprobs`
- audio output
- OpenAI function/tool calls on the Responses API
- background Responses API jobs

Token usage is estimated from character counts because Cursor's stream does not return OpenAI token accounting on this path. For Composer 2.5 and the listed Grok models, `usage.cost` is estimated from Cursor's published per-million-token pricing.

## OpenCode

![Composer 2.5 in OpenCode](public/opencode-composer-2-5.webp)

Use the app's **Agent Setup** pane to install the local OpenCode provider. The configured provider points at the local base URL, not the hosted Worker.

## Local development

```bash
npm install
npm run db:migrate:local
npm run dev
```

Create a local `.dev.vars` file:

```bash
ENCRYPTION_KEY="replace-with-a-long-random-secret"
WAITLIST_API_TOKEN="standard-agents-waitlist-token"
CURSOR_SDK_BRIDGE_URL="optional-external-node-sdk-bridge-url"
CURSOR_SDK_BRIDGE_TOKEN="optional-external-shared-bridge-token"
CURSOR_SDK_BRIDGE_TIMEOUT_MS="180000"
CURSOR_CLIENT_VERSION="2.6.22"
CURSOR_SDK_CLIENT_VERSION="sdk-1.0.13"
```

Run the optional SDK local-agent bridge in a local Bun or Node environment:

```bash
npm run sdk:opencode-bridge
```

The bridge process also accepts optional runtime knobs; defaults shown:

```bash
CURSOR_SDK_BRIDGE_RUN_TIMEOUT_MS=180000              # per-request run timeout (packaged app overrides to 120000)
CURSOR_SDK_BRIDGE_MAX_RUN_RETRIES=3                  # SDK-run retries per bridge call (4 total attempts)
CURSOR_SDK_BRIDGE_SHUTDOWN_TIMEOUT_MS=15000          # Node drain bound during shutdown
CURSOR_SDK_BRIDGE_PARENT_LOSS_POLL_INTERVAL_MS=1000  # parent-PID watchdog cadence (packaged app)
```

In the packaged macOS app the bridge runs as a child process owned by the app. The bridge
follows parent lifetime: it stops accepting new requests when the app begins shutdown, then
awaits in-flight SDK agent asynchronous disposal before exiting.

Two retry layers apply. Inside the bridge, `maxRunRetries` (default 3) controls SDK-run
retries: `attempt` starts at 0 and increments after each retryable SDK-run error that
occurs before any event is emitted, allowing up to 3 retries (4 total SDK-run attempts)
per bridge call. At the Swift app layer, `bridgeTransportAttempts = 2` means a retryable
pre-output transport failure, 503, or `cursor_sdk_unavailable` error causes the app to
recycle the owned bridge exactly once and issue one final bridge request. Auth failures,
arbitrary upstream errors, and any failure after output has begun are never retried at
either layer. Recycling is process-wide: because all local SDK sessions share the owned
bridge process, a recycle disposes every cached agent and may interrupt other concurrent
requests. This trade-off favors clearing poisoned local SDK state; affected callers can
retry through the unchanged public OpenAI-compatible response and error contract.

Release packages prefer a bundled Node runtime for the local SDK bridge and fall
back to Bun when Node is unavailable.

## Cloudflare

The Worker uses Cloudflare Vite and D1.

Remote migration and deploy commands require a valid `CLOUDFLARE_API_TOKEN` in
the shell environment.

```bash
npm run build
npm run test
npm run typecheck
npm run db:migrate:remote
npm run deploy
```

Required secrets:

```bash
wrangler secret put ENCRYPTION_KEY
wrangler secret put CURSOR_BACKEND_BASE_URL
wrangler secret put CURSOR_CHAT_ENDPOINT
wrangler secret put WAITLIST_API_TOKEN
```

The OpenCode SDK harness also requires the `0002_sdk_sessions.sql` migration so
local SDK agent ids can be resumed across Worker isolates.

The Cloudflare deployment uses the container-backed bridge by default. Do not set
`CURSOR_SDK_BRIDGE_URL` for that path. Only set it when intentionally routing the
SDK harness to an external Node or Bun bridge instead of the
`CURSOR_SDK_BRIDGE_CONTAINER` Durable Object binding.

Optional SDK harness overrides:

```bash
wrangler secret put CURSOR_SDK_CLIENT_VERSION
wrangler secret put CURSOR_SDK_BRIDGE_URL
wrangler secret put CURSOR_SDK_BRIDGE_TOKEN
```

## Research sources

- Cursor SDK package: `@cursor/sdk@1.0.13`
- Cursor SDK TypeScript docs: https://cursor.com/docs/api/sdk/typescript
- Cursor Composer 2.5 changelog: https://cursor.com/changelog/composer-2-5
- Cursor Grok 4.6 docs: https://cursor.com/docs/models/grok-4-6
- Cursor Grok 4.5 docs: https://cursor.com/docs/models/grok-4-5
- OpenAI Chat Completions reference: https://developers.openai.com/api/docs/api-reference/chat
- OpenAI Responses reference: https://developers.openai.com/api/docs/api-reference/responses
- OpenAI migration guide: https://developers.openai.com/api/docs/guides/migrate-to-responses
- Cloudflare Containers getting started: https://developers.cloudflare.com/containers/get-started/
- Cloudflare Containers container class: https://developers.cloudflare.com/containers/container-class/
