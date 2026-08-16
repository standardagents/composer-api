# Security Audit Report — composer-api

**Date:** 2026-05-23
**Scope:** `/Users/ironin/Work/Pi-Agent/composer-api` (commit on `main`)
**Type:** Full security review — supply chain, dependency audit, static code review

---

## Executive Summary

`composer-api` is a Cloudflare Workers application that proxies OpenAI-compatible requests to Cursor Composer. It consists of:

- **Worker** (server-side): TypeScript, handles auth, request transformation, streaming SSE, D1 database, AES-GCM encryption of API keys
- **Client SPA** (browser-side): TypeScript, chat UI, localStorage session management
- **SDK proxy script** (local dev tool): Node.js HTTP server wrapping `@cursor/sdk`

**Overall risk: MEDIUM-HIGH.** No critical RCE or credential leak in the worker itself, but there are real supply-chain vulnerabilities in dependencies, a wildcard CORS policy, missing security headers, an SSRF vector, and the SDK proxy script disables sandboxing.

---

## 1. Supply Chain & Dependencies

### 1.1 npm Audit — 14 vulnerabilities

| Severity | Package | Chain | Notes |
|----------|---------|-------|-------|
| **HIGH** | `sqlite3` (5.0.0–5.1.7) | via `node-gyp` → `make-fetch-happen` → `cacache` → `tar` | `tar` has multiple path-traversal CVEs (GHSA-34x7-hfp2-rc4v, GHSA-8qq5-rm4j-mr97, GHSA-83g3-92jg-28cx, GHSA-qffp-2rhf-9h96, GHSA-9ppj-qmqm-q256, GHSA-r6q2-hw4h-h46w) |
| **HIGH** | `tar` (<7.5.7) | direct transitive dep | Arbitrary file creation/overwrite via hardlink path traversal (CVSS 8.2) |
| **HIGH** | `undici` (≤6.23.0) | via `@connectrpc/connect-node` → `@cursor/sdk` | Unbounded decompression chain → DoS (GHSA-g9mf-h72j-4rw9); HTTP request/response smuggling (GHSA-2mjp-6q6p-2qxm); WebSocket memory issues |
| **HIGH** | `@cursor/sdk` (1.0.13) | direct dependency | Depends on vulnerable `@connectrpc/connect-node` + `sqlite3`; **no fix available** without upstream fix |
| **MODERATE** | `ws` (8.0.0–8.20.0) | via `miniflare` → `@cloudflare/vite-plugin`, `wrangler` | Uninitialized memory disclosure (GHSA-58qx-3vcg-4xpx) |
| **LOW** | `@tootallnate/once` (<2.0.1) | via `http-proxy-agent` | Incorrect control flow scoping (GHSA-vpq2-c234-7xj6) |

**Risk assessment:** The `tar` CVEs are **HIGH severity at build time only** — the worker never extracts tarballs. The `undici` CVEs affect the Node.js fetch runtime — also **build-time/dev-time only** since the deployed Cloudflare Worker uses its own fetch, not Node.js. `@cursor/sdk` vulnerabilities are dev-time only (the SDK proxy script). **None of these are exploitable in production on Cloudflare Workers**, but they matter for local development.

**Remediation:** `npm audit fix` resolves most; `@cursor/sdk` needs upstream update.

### 1.2 Install Scripts

No `postinstall`, `preinstall`, or `prepare` scripts in `package.json`. No custom install scripts. ✅

### 1.3 Non-npm Resolutions

No `overrides`, `resolutions`, or `pnpm.overrides` in package.json. Only two direct dependencies: `@cursor/sdk` (npm) and `lucide` (npm). ✅

---

## 2. Code Review Findings

### FINDING 1 — Wildcard CORS on API Endpoints
**Severity: MEDIUM**
**File:** `worker/http.ts:5-9`, `worker/http.ts:13-20`
**Location:** `CORS_HEADERS`, `withCors()`

```ts
const CORS_HEADERS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET,POST,OPTIONS",
  "access-control-allow-headers": "authorization,content-type,x-api-key,idempotency-key",
  "access-control-max-age": "86400"
};
```

Every response (including error responses) gets `Access-Control-Allow-Origin: *`. For an API that handles authentication tokens, this is permissive. An attacker's page could make authenticated requests to the API via CORS if the browser sends credentials (though `credentials: "include"` would be blocked by the lack of `Access-Control-Allow-Credentials: true`).

**Risk:** Low in practice because the API uses Bearer tokens (not cookies), but still exposes all endpoints to cross-origin requests. The `/api/signup` endpoint that stores encrypted API keys is also CORS-open.

**Recommendation:** Consider restricting `Access-Control-Allow-Origin` to known origins or removing CORS from authenticated endpoints.

---

### FINDING 2 — No Security Response Headers
**Severity: MEDIUM**
**File:** `worker/http.ts`, all response constructors

No security headers on any response:
- ❌ `Content-Security-Policy`
- ❌ `X-Content-Type-Options: nosniff`
- ❌ `X-Frame-Options` / `Frame-Options`
- ❌ `Strict-Transport-Security`
- ❌ `Referrer-Policy`
- ❌ `Permissions-Policy`

**Risk:** The SPA (`src/`) renders HTML with `innerHTML` from server-sourced markdown. Without CSP, any future injection would execute freely. `X-Content-Type-Options: nosniff` would prevent MIME-type confusion attacks.

**Recommendation:** Add at minimum `X-Content-Type-Options: nosniff` to all responses. Add CSP for the SPA frontend.

---

### FINDING 3 — SSRF via Image URL Fetching
**Severity: MEDIUM**
**File:** `worker/cursor.ts:500-519` — `fetchImageBytes()`

```ts
async function fetchImageBytes(url: string, deps: Deps): Promise<Uint8Array> {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new HttpError("Image URL is invalid.", ...);
  }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
    throw new HttpError("Image URL must use http or https.", ...);
  }
  const response = await deps.fetch(parsed.toString(), { method: "GET" });
  // ...
}
```

Image URLs from user-controlled `image_url` fields are fetched server-side with no allowlist, no blocklist, no IP-range restrictions, no redirect-following limits. While the protocol check (`http:`/`https:`) blocks `file://` and `data://`, it does **not** block:
- Internal Cloudflare metadata URLs (`http://169.254.169.254/...`)
- Private IP ranges (`http://10.0.0.1/...`, `http://127.0.0.1:8787/...`)
- DNS rebinding attacks

**Risk:** In Cloudflare Workers the attack surface is limited — Workers run in a sandboxed V8 isolate with no access to the host network stack. Internal IPs are typically blocked by Cloudflare's infrastructure. However, `http://` URLs (not just `https://`) are accepted, and an attacker could probe internal services if the Cloudflare Worker network allows intra-datacenter connections.

**Recommendation:** Block private IP ranges, `http://` protocol (require `https://` only), and add a redirect-following limit.

---

### FINDING 4 — Missing Request Body Size Limit
**Severity: MEDIUM**
**File:** `worker/http.ts:64-69` — `parseJsonBody()`

```ts
export function parseJsonBody<T = unknown>(request: Request): Promise<T> {
  const contentType = request.headers.get("content-type") || "";
  if (contentType && !contentType.toLowerCase().includes("application/json")) {
    throw new HttpError("Content-Type must be application/json", 415);
  }
  return request.json() as Promise<T>;
}
```

No size limit is enforced on the incoming request body. An attacker could send arbitrarily large JSON payloads to exhaust worker memory.

**Risk:** Cloudflare Workers have a 128 MiB memory limit per invocation. A large enough payload could cause OOM or trigger the worker execution timeout (30s for unbound, 10s for standard). In practice, the request itself would be limited by Cloudflare's 100 MiB request body cap, but there's no explicit limit in code.

**Recommendation:** Read body as `ArrayBuffer` first and check size before calling `.json()`.

---

### FINDING 5 — Client-Side API Key in localStorage
**Severity: LOW**
**File:** `src/chat.ts:66-68, 130-136, 996-1006`

```ts
const REMEMBERED_KEY = "cursor-chat.apiKey";
// ...
if (refs.keyRemember.checked) localStorage.setItem(REMEMBERED_KEY, value);
```

The chat UI optionally stores the user's Cursor API key in `localStorage`. This is readable by any JavaScript running on the same origin.

**Risk:** If the SPA is compromised (e.g., via XSS through the markdown renderer), the attacker can exfiltrate stored API keys. The key is stored in plaintext.

**Recommendation:** Consider `sessionStorage` instead, or at minimum document the tradeoff. The current implementation is acceptable for a dev tool but should be noted.

---

### FINDING 6 — Markdown Renderer Has Potential XSS Surface
**Severity: LOW**
**File:** `src/markdown.ts:204-216` — `renderInline()`

```ts
function renderInline(value: string): string {
  let text = escapeHtml(value);
  text = text.replace(/`([^`]+)`/g, "<code>$1</code>");
  text = text.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  text = text.replace(
    /\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g,
    (_match, label: string, href: string) =>
      `<a href="${escapeAttr(href)}" target="_blank" rel="noreferrer">${label}</a>`
  );
  // ...
}
```

The markdown renderer:
- ✅ Properly escapes HTML before inline processing (`escapeHtml(value)`)
- ✅ Regex captures only after escaping, so `<script>` becomes `&lt;script&gt;`
- ✅ External links get `target="_blank" rel="noreferrer"`
- ⚠️ Uses `innerHTML` to inject rendered content (multiple locations in `src/chat.ts`, `src/main.ts`)

The escaping order is correct — `escapeHtml` runs first, then inline regex replacements operate on escaped text. No XSS is possible through the markdown renderer as written.

**Risk:** Very low. The regex-based approach is brittle for edge cases (nested backticks, escaped characters in markdown), but the pre-escaping prevents injection.

**Recommendation:** No change needed. Note that future modifications to `renderInline` must preserve the escaping-first discipline.

---

### FINDING 7 — SDK Proxy Script Disables Sandboxing
**Severity: HIGH (local dev only)**
**File:** `scripts/cursor-sdk-responses-proxy.mjs:260,274`

```ts
local: { cwd: workspaceCwd, sandboxOptions: { enabled: false } }
```

The Cursor SDK proxy script explicitly disables the sandbox when creating/resuming agents. The agent runs with full filesystem access in the `workspaceCwd` directory.

**Risk:** This is a **local development tool** — it runs on the developer's machine. If a malicious LLM response triggers tool calls, the agent can read/write/execute files in the workspace without any sandbox protection. This is intentional design for the SDK proxy (it's meant to be a local dev proxy), but it should be documented as a security boundary.

**Recommendation:** Document this clearly in the README. Consider adding a warning banner in the proxy's startup output.

---

### FINDING 8 — SDK Proxy `.env` File Loading from Arbitrary Paths
**Severity: LOW (local dev only)**
**File:** `scripts/cursor-sdk-responses-proxy.mjs:674-684`

```ts
function loadEnvFile(file) {
  if (!existsSync(file)) return;
  const text = readFileSync(file, "utf8");
  for (const line of text.split(/\r?\n/)) {
    // ...
    process.env[key] = rawValue.replace(/^["']|["']$/g, "");
  }
}
```

Loads `.env` from repo root and `process.cwd()`. This is standard behavior but means the proxy inherits whatever env vars are in the current working directory's `.env`.

**Risk:** Low — this is a local dev script, not the production worker.

---

### FINDING 9 — No Rate Limiting
**Severity: MEDIUM**
**Files:** All worker endpoints

No rate limiting is implemented at the application level. The worker relies entirely on:
1. Cloudflare's built-in DDoS protection (network layer)
2. Cursor's own rate limiting (upstream)

**Risk:** An attacker with a valid API key could flood the proxy, incurring costs for the account owner. In the hosted-key (proxy) flow, an attacker who obtains a `cmp_...` key could exhaust the associated Cursor account's usage quota.

**Recommendation:** Add per-account rate limiting using Cloudflare KV or D1 counters.

---

### FINDING 10 — Hardcoded Cloudflare Account ID
**Severity: INFO**
**File:** `wrangler.jsonc:4`

```jsonc
"account_id": "fd9e24c9339e83e73661475690574340",
```

The Cloudflare account ID is committed to the repository. This is not a secret (it's a public identifier), but it reveals infrastructure details.

**Risk:** None — Cloudflare account IDs are not secrets. ✅

---

### FINDING 11 — Stale Asset Fallback Regex Allows Controlled Path Traversal
**Severity: LOW**
**File:** `worker/index.ts:48-54` — `staleViteAssetFallbackPath()`

```ts
function staleViteAssetFallbackPath(pathname: string): string | null {
  if (/^\/assets\/index-[A-Za-z0-9_-]+\.css$/.test(pathname)) return "/assets/index.css";
  if (/^\/assets\/index-[A-Za-z0-9_-]+\.js$/.test(pathname)) return "/assets/index.js";
  // ...
}
```

The regex validates the path pattern, and the return value is always a hardcoded safe path. This is correctly implemented — no traversal is possible because the matched input is discarded and a constant is returned. ✅

**Risk:** None. Well-designed pattern.

---

### FINDING 12 — Error Responses Leak Internal Details
**Severity: LOW**
**File:** `worker/http.ts:85-89` — `errorResponse()`

```ts
export function errorResponse(error: unknown): Response {
  if (error instanceof HttpError) {
    return openAiError(error.message, error.status, error.code, error.param);
  }
  const message = error instanceof Error ? error.message : "Unexpected error";
  return openAiError(message, 500, "internal_error");
}
```

Internal error messages (including `error.message` from caught exceptions) are returned to the client. This could leak internal Cursor API error messages, database errors, or stack traces.

**Risk:** Low in practice — most errors are `HttpError` with controlled messages. However, any unhandled exception's `.message` is returned directly.

**Recommendation:** Replace internal error messages with a generic "Internal server error" for 500 responses. Log details server-side only.

---

## 3. Positive Security Findings

Several security controls are well-implemented:

| Control | Status | Notes |
|---------|--------|-------|
| **API key encryption at rest** | ✅ Good | AES-GCM with random IV, SHA-256 key derivation, proper `crypto.subtle` usage |
| **Proxy key hashing** | ✅ Good | `cmp_` tokens stored as SHA-256 hashes, never plaintext |
| **Auth mode isolation** | ✅ Good | `cmp_` tokens resolved against D1 only; never forwarded to Cursor as raw keys |
| **Direct mode ephemeral** | ✅ Good | Direct Bearer mode writes nothing to D1 — no accounts, no keys, no logs |
| **Account scoping** | ✅ Good | Account-scoped routes (`/u/{accountId}/v1/...`) reject direct auth |
| **Parameterized SQL** | ✅ Good | All D1 queries use `.bind()` with parameterized values, no string interpolation |
| **Input validation** | ✅ Good | `expectRecord()`, `expectArray()` with explicit error messages |
| **No eval/exec/shell** | ✅ Good | Worker has zero calls to `eval()`, `exec()`, `spawn()`, or `Function()` |
| **No process.env in worker** | ✅ Good | Worker uses `env.*` binding, not `process.env` |
| **HTML escaping** | ✅ Good | `escapeHtml()` and `escapeAttr()` in UI code, proper escaping order |
| **Image size limits** | ✅ Good | 1MB cap on image uploads in both worker and client |
| **Protobuf frame parsing** | ✅ Good | Bounded buffer, proper length-prefix parsing, no unbounded accumulation |

---

## 4. Summary Table

| # | Finding | Severity | Component | Status |
|---|---------|----------|-----------|--------|
| 1 | Wildcard CORS on all API endpoints | MEDIUM | worker/http.ts | Needs fix |
| 2 | Missing security headers (CSP, X-Content-Type-Options, etc.) | MEDIUM | worker/http.ts | Needs fix |
| 3 | SSRF via image URL fetching (no IP/redirect restrictions) | MEDIUM | worker/cursor.ts | Needs fix |
| 4 | No request body size limit (DoS potential) | MEDIUM | worker/http.ts | Needs fix |
| 5 | Client-side API key stored in localStorage | LOW | src/chat.ts | Acknowledge |
| 6 | Markdown renderer — XSS-safe but regex-brittle | LOW | src/markdown.ts | Acceptable |
| 7 | SDK proxy script disables sandbox | HIGH | scripts/*.mjs | Dev-only, document |
| 8 | SDK proxy `.env` loading from cwd | LOW | scripts/*.mjs | Dev-only |
| 9 | No application-level rate limiting | MEDIUM | All endpoints | Needs enhancement |
| 10 | Cloudflare account ID in repo | INFO | wrangler.jsonc | Not a secret |
| 11 | Stale asset fallback path | LOW | worker/index.ts | ✅ Safe design |
| 12 | Internal error messages in responses | LOW | worker/http.ts | Minor fix |
| — | `tar` path traversal CVEs (build-time) | HIGH | Dependency | ✅ Build-only, no runtime impact |
| — | `undici` DoC/smuggling CVEs (build-time) | HIGH | Dependency | ✅ Build-only, no runtime impact |
| — | `ws` memory disclosure (dev-time) | MODERATE | Dependency | ✅ Dev-only, no runtime impact |
| — | `@cursor/sdk` transitive vulns (dev-time) | HIGH | Dependency | ✅ Dev-only, no runtime impact |

## 5. Priority Remediation

1. **Block `http://` in `fetchImageBytes()`** — require `https://` only (5-min fix, eliminates SSRF)
2. **Add `X-Content-Type-Options: nosniff`** to all responses (2-min fix)
3. **Add request body size cap** in `parseJsonBody()` (10-min fix)
4. **Genericize 500 error messages** (5-min fix)
5. **Restrict CORS** or document why `*` is acceptable (30-min design decision)
6. **Add rate limiting** for authenticated endpoints (significant work — requires KV/D1)
7. **Document SDK proxy sandbox warning** in README (2-min fix)
8. **Update `@cursor/sdk`** when upstream fixes transitive vulnerabilities (blocked on upstream)
