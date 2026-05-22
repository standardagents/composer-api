# Composer API

OpenAI-compatible `chat.completions` and `responses` endpoints backed by Cursor Composer.

Live deployment: https://cursor-api.standardagents.ai

## What this is

Cursor does not expose Composer 2.5 as a raw OpenAI-compatible model endpoint. This Worker adapts OpenAI-style requests into the format Cursor accepts:

- `POST /auth/exchange_user_api_key`
- a private Cursor chat endpoint configured with `CURSOR_CHAT_ENDPOINT`

Each request is stateless from the caller's perspective: the Worker creates a fresh request/conversation id, sends the full prompt, streams text back, and does not create a Cursor Cloud Agent. Chat Completions requests that include tools are sent in Composer Agent mode, and Composer tool-call markers are translated back into OpenAI-compatible `tool_calls`.

## Supported endpoints

- `POST /v1/chat/completions`
- `POST /v1/responses`
- `GET /v1/models`

## Usage

Point any OpenAI-compatible client at the base URL and authenticate with your own
Cursor API key as the bearer token. The key is forwarded to Cursor per request and
is **not stored**: no signup, no encrypted-at-rest secret, no request logs.

```ts
import OpenAI from "openai";

const client = new OpenAI({
  apiKey: process.env.CURSOR_API_KEY, // your Cursor user API key
  baseURL: "https://<deployment>/v1"
});

const completion = await client.chat.completions.create({
  model: "composer-2.5",
  messages: [{ role: "user", content: "Write a TypeScript debounce." }]
});
```

```bash
curl https://<deployment>/v1/chat/completions \
  -H "Authorization: Bearer $CURSOR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"composer-2.5","messages":[{"role":"user","content":"Hello"}]}'
```

A Cursor user API key comes from the Cursor Dashboard under Integrations.

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

Token usage is estimated from character counts because Cursor's stream does not return OpenAI token accounting.

## OpenCode

OpenCode should use the hosted OpenCode route, not the generic `/v1` route. The
OpenCode route keeps tool execution local to OpenCode: the Worker translates
Cursor tool-call output into OpenAI-compatible `tool_calls`, then OpenCode runs
the file and shell tools in your project.

Base URL:

```txt
https://cursor-api.standardagents.ai/opencode/v1
```

OpenCode uses these endpoints:

- `GET /opencode/v1/models`
- `POST /opencode/v1/chat/completions`

Configure the provider with `@ai-sdk/openai-compatible` and select
`cursor/composer-2.5`, displayed as **Composer 2.5 via Cursor API**.

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
CURSOR_BACKEND_BASE_URL="private-cursor-backend-origin"
CURSOR_CHAT_ENDPOINT="private-cursor-chat-endpoint"
CURSOR_CLIENT_VERSION="2.6.22"
```

## Cloudflare

The Worker uses Cloudflare Vite and D1.

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
