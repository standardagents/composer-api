# API for Cursor

Local OpenAI-compatible `chat.completions` and `responses` endpoints backed by Cursor Composer.

Download site: https://api-for-composer.standardagents.ai

## What this is

Cursor does not expose Composer as a raw OpenAI-compatible model endpoint. API for Cursor now ships as a local macOS app that starts a localhost `/v1` server, stores the Cursor API key locally, and configures local agent tools.

The hosted Worker routes remain in the repository for temporary compatibility while the local app rollout is verified. Cursor has asked us to take down the hosted API path, so the production release path is the signed macOS app.

## Supported endpoints

- `POST /v1/chat/completions`
- `POST /v1/responses`
- `GET /v1/models`

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

Token usage is estimated from character counts because Cursor's stream does not return OpenAI token accounting on this path. For Composer 2.5 and Composer 2.5 Fast, `usage.cost` is estimated from Cursor's published per-million-token pricing.

## OpenCode

![Composer 2.5 in OpenCode](public/opencode-composer-2-5.webp)

Use the app's **Agent Setup** pane to install the local OpenCode provider. The configured provider points at the local base URL, not the hosted Worker.

## Factory

Use the app's **Agent Setup** pane to add Composer 2.5 and Composer 2.5 Fast as
Factory.ai Droid custom models. The installer writes `customModels` entries into
`~/.factory/settings.json` (backing the file up first) that point Droid at the
local OpenAI-compatible base URL. Restart Factory or open a new session to see
them in the model picker.

The one-click Factory flow is adapted from
[DroidProxy](https://github.com/anand-92/droidproxy) — thanks to DroidProxy for
the approach of writing Factory custom models from a local proxy app.

## Local development

```bash
npm install
npm run db:migrate:local
npm run dev
```

Create a local `.dev.vars` file:

```bash
ENCRYPTION_KEY="replace-with-a-long-random-secret"
WAITLIST_API_TOKEN="optional-standard-agents-waitlist-token"
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

The bridge process also accepts `CURSOR_SDK_BRIDGE_RUN_TIMEOUT_MS`; the default is
`180000`.

Release packages prefer a bundled Bun runtime for the local SDK bridge and fall
back to Node when Bun is unavailable.

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

Optional secret for direct waitlist writes. If omitted, the Worker falls back to the deployed token-cost early-access endpoint.

```bash
wrangler secret put WAITLIST_API_TOKEN
```

## Research sources

- Cursor SDK package: `@cursor/sdk@1.0.13`
- Cursor SDK TypeScript docs: https://cursor.com/docs/api/sdk/typescript
- Cursor Composer 2.5 changelog: https://cursor.com/changelog/composer-2-5
- OpenAI Chat Completions reference: https://developers.openai.com/api/docs/api-reference/chat
- OpenAI Responses reference: https://developers.openai.com/api/docs/api-reference/responses
- OpenAI migration guide: https://developers.openai.com/api/docs/guides/migrate-to-responses
- Cloudflare Containers getting started: https://developers.cloudflare.com/containers/get-started/
- Cloudflare Containers container class: https://developers.cloudflare.com/containers/container-class/
