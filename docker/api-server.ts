import "./register-cloudflare-mock.mjs";
import http from "node:http";
import type { IncomingMessage, ServerResponse } from "node:http";
import { Readable } from "node:stream";
import { fileURLToPath } from "node:url";
import type { Env } from "../worker/types.js";

function parsePort(value: string | undefined, fallback: number): number {
  const parsed = Number.parseInt(value || "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

async function loadRuntime() {
  const [{ handleRequest, defaultDeps }, { FakeD1, fakeCtx }] = await Promise.all([
    import("../worker/index.ts"),
    import("../worker/test-helpers.ts")
  ]);
  return { handleRequest, defaultDeps, FakeD1, fakeCtx };
}

export function createSelfHostedEnv(FakeD1: typeof import("../worker/test-helpers.ts").FakeD1): Env {
  const bridgeUrl = process.env.CURSOR_SDK_BRIDGE_URL?.trim();
  if (!bridgeUrl) {
    throw new Error("CURSOR_SDK_BRIDGE_URL is required (for example http://bridge:8792/sdk)");
  }

  return {
    DB: new FakeD1() as unknown as D1Database,
    ASSETS: {
      fetch: async () => new Response("Not Found", { status: 404 })
    } as unknown as Fetcher,
    CURSOR_API_BASE: process.env.CURSOR_API_BASE?.trim() || "https://api.cursor.com",
    CURSOR_CLIENT_VERSION: process.env.CURSOR_CLIENT_VERSION?.trim() || "2.6.22",
    CURSOR_SDK_CLIENT_VERSION: process.env.CURSOR_SDK_CLIENT_VERSION?.trim() || "sdk-1.0.13",
    CURSOR_SDK_BRIDGE_URL: bridgeUrl,
    CURSOR_SDK_BRIDGE_TOKEN: process.env.CURSOR_SDK_BRIDGE_TOKEN,
    CURSOR_SDK_BRIDGE_TIMEOUT_MS: process.env.CURSOR_SDK_BRIDGE_TIMEOUT_MS
  };
}

function healthResponse(): Response {
  return Response.json({
    ok: true,
    service: "api-for-cursor-self-hosted",
    bridgeConfigured: Boolean(process.env.CURSOR_SDK_BRIDGE_URL?.trim())
  });
}

async function readRequestBody(request: IncomingMessage): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) {
    chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks);
}

function nodeRequestToWeb(request: IncomingMessage, body: Buffer, origin: string): Request {
  const url = new URL(request.url || "/", origin);
  const headers = new Headers();
  for (const [key, value] of Object.entries(request.headers)) {
    if (value === undefined) continue;
    if (Array.isArray(value)) {
      for (const item of value) headers.append(key, item);
    } else {
      headers.set(key, value);
    }
  }

  const method = request.method || "GET";
  const init: RequestInit = { method, headers };
  if (method !== "GET" && method !== "HEAD" && body.length > 0) {
    init.body = new Uint8Array(body);
  }

  return new Request(url.toString(), init);
}

async function writeWebResponse(response: Response, res: ServerResponse): Promise<void> {
  res.statusCode = response.status;
  response.headers.forEach((value, key) => {
    if (key.toLowerCase() === "transfer-encoding") return;
    res.setHeader(key, value);
  });

  if (!response.body) {
    res.end();
    return;
  }

  const nodeStream = Readable.fromWeb(response.body as ReadableStream<Uint8Array>);
  for await (const chunk of nodeStream) {
    res.write(chunk);
  }
  res.end();
}

export async function startApiServer(): Promise<http.Server> {
  const { handleRequest, defaultDeps, FakeD1, fakeCtx } = await loadRuntime();
  const env = createSelfHostedEnv(FakeD1);
  const ctx = fakeCtx();
  const host = process.env.CURSOR_API_HOST?.trim() || "0.0.0.0";
  const port = parsePort(process.env.CURSOR_API_PORT, 8787);
  const origin = `http://${host === "0.0.0.0" ? "127.0.0.1" : host}:${port}`;

  const server = http.createServer(async (req, res) => {
    try {
      const pathname = new URL(req.url || "/", origin).pathname;
      if (req.method === "GET" && pathname === "/health") {
        await writeWebResponse(healthResponse(), res);
        return;
      }

      const body = await readRequestBody(req);
      const webRequest = nodeRequestToWeb(req, body, origin);
      const webResponse = await handleRequest(webRequest, env, ctx, defaultDeps);
      await writeWebResponse(webResponse, res);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Internal Server Error";
      if (!res.headersSent) {
        res.statusCode = 500;
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ error: { message, type: "server_error" } }));
        return;
      }
      res.end();
    }
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, host, () => resolve());
  });

  console.log(`API for Cursor self-hosted server listening on http://${host}:${port}/v1`);
  return server;
}

const isMainModule = process.argv[1] === fileURLToPath(import.meta.url);
if (isMainModule) {
  startApiServer().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
