# Composer API

OpenAI-compatible `chat.completions` and `responses` endpoints backed by Cursor Composer through Cursor's public Cloud Agent API.

## What this is

Cursor does not expose Composer 2.5 as a raw OpenAI-compatible model endpoint. The public SDK uses Cursor API keys against Cloud Agent endpoints:

- `GET /v1/me`
- `GET /v1/models`
- `POST /v1/agents`
- `GET /v1/agents/{agentId}/runs/{runId}/stream`

This Worker verifies a user's Cursor API key, stores it encrypted in D1, mints a separate `cmp_...` proxy key, and adapts basic OpenAI-style requests to short-lived Cursor agent runs.

## Supported endpoints

- `POST /v1/chat/completions`
- `POST /v1/responses`
- `GET /v1/models`
- Per-account equivalents at `/u/{account_id}/v1/...`

The per-account base URL is shown after signup and is the recommended SDK base URL.

```ts
import OpenAI from "openai";

const client = new OpenAI({
  apiKey: process.env.COMPOSER_API_KEY,
  baseURL: "https://<deployment>/u/<account_id>/v1"
});

const completion = await client.chat.completions.create({
  model: "composer-2.5",
  messages: [{ role: "user", content: "Write a TypeScript debounce." }]
});
```

## Compatibility notes

This project supports text and image input, non-streaming and streaming output, JSON-output prompt constraints, and the common SDK response shapes.

These OpenAI features are intentionally rejected because Cursor's public agent API does not expose equivalent raw model controls:

- `n` greater than `1`
- `logprobs` and `top_logprobs`
- audio output
- OpenAI function/tool calls
- background Responses API jobs

Token usage is estimated from character counts because Cursor's agent stream does not return OpenAI token accounting.

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

Required secret:

```bash
wrangler secret put ENCRYPTION_KEY
```

Optional secret:

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
