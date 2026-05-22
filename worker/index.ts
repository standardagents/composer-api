import { collectCursorOutput, createCursorCompletion, resolveCursorModel, streamCursorText, verifyCursorApiKey } from "./cursor";
import { authenticateProxyKey, completeRequestLog, createRequestLog, saveSignup } from "./db";
import { bearerToken, errorResponse, HttpError, json, notFound, openAiError, optionsResponse, parseJsonBody, sseResponse, unauthorized, withCors } from "./http";
import {
  chatChunk,
  chatCompletionResponse,
  doneChunk,
  modelList,
  prepareChatRequest,
  prepareResponsesRequest,
  responseCreatedEvents,
  responseDeltaEvent,
  responseDoneEvents,
  responseObject,
  toOpenAiToolCalls
} from "./openai";
import { submitWaitlist } from "./waitlist";
import { encodeSse } from "./sse";
import type { Deps, Env } from "./types";
import type { OpenAiToolSpec } from "./openai";

/**
 * The two ways a `/v1/...` request can be authenticated:
 * - `proxy`: a stored `cmp_...` key resolved against D1 (hosted-key flow).
 * - `direct`: a Cursor API key passed straight through; nothing is stored.
 */
type AuthResult =
  | { mode: "proxy"; accountId: string; cursorApiKey: string }
  | { mode: "direct"; cursorApiKey: string };

const defaultDeps: Deps = {
  fetch: (input, init) => fetch(input, init),
  now: () => new Date(),
  randomUUID: () => crypto.randomUUID()
};

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    return handleRequest(request, env, ctx, defaultDeps);
  }
};

export async function handleRequest(request: Request, env: Env, ctx: ExecutionContext, deps: Deps = defaultDeps): Promise<Response> {
  if (request.method === "OPTIONS") return optionsResponse();
  const url = new URL(request.url);

  try {
    if (url.pathname === "/api/signup" && request.method === "POST") {
      return await handleSignup(request, env, ctx, deps);
    }
    if (url.pathname === "/api/early-access" && request.method === "POST") {
      return await handleEarlyAccess(request, env, deps);
    }

    const route = matchOpenAiRoute(url.pathname);
    if (route) {
      return await handleOpenAiRoute(request, env, ctx, deps, route);
    }

    const staleAssetFallback = staleViteAssetFallbackPath(url.pathname);
    if (staleAssetFallback) {
      const response = await fetchAsset(env, request, staleAssetFallback);
      if (response.status !== 404) return withCors(response);
    }

    // Client-side routes (e.g. `/chat`) have no matching asset; serve the SPA
    // shell so the front-end router can take over.
    if (isDocumentRequest(request, url) && url.pathname !== "/") {
      const indexRequest = new Request(new URL("/", url).toString(), {
        method: "GET",
        headers: request.headers
      });
      return withCors(await env.ASSETS.fetch(indexRequest));
    }
    return withCors(await env.ASSETS.fetch(request));
  } catch (error) {
    return errorResponse(error);
  }
}

function staleViteAssetFallbackPath(pathname: string): string | null {
  if (/^\/assets\/index-[A-Za-z0-9_-]+\.css$/.test(pathname)) return "/assets/index.css";
  if (/^\/assets\/index-[A-Za-z0-9_-]+\.js$/.test(pathname)) return "/assets/index.js";
  if (/^\/assets\/index-[A-Za-z0-9_-]+\.js\.map$/.test(pathname)) return "/assets/index.js.map";
  if (/^\/assets\/chat-[A-Za-z0-9_-]+\.js$/.test(pathname)) return "/assets/chat.js";
  if (/^\/assets\/chat-[A-Za-z0-9_-]+\.js\.map$/.test(pathname)) return "/assets/chat.js.map";
  return null;
}

function fetchAsset(env: Env, request: Request, pathname: string): Promise<Response> {
  const url = new URL(request.url);
  url.pathname = pathname;
  url.search = "";
  return env.ASSETS.fetch(
    new Request(url.toString(), {
      method: "GET",
      headers: request.headers
    })
  );
}

const EMAIL_PATTERN = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

/**
 * Standard Agents early-access capture. The upstream waitlist token
 * (`WAITLIST_API_TOKEN`) lives only in worker env and is never exposed to the
 * browser; the client posts here and we forward server-side.
 */
async function handleEarlyAccess(request: Request, env: Env, deps: Deps): Promise<Response> {
  const body = (await parseJsonBody<Record<string, unknown>>(request).catch(() => ({}))) as Record<string, unknown>;
  const name = typeof body.name === "string" ? body.name.trim() : "";
  const email = typeof body.email === "string" ? body.email.trim() : "";

  if (!name) return openAiError("Your name is required.", 400, "invalid_request_error", "name");
  if (!email) return openAiError("Your email is required.", 400, "invalid_request_error", "email");
  if (!EMAIL_PATTERN.test(email)) {
    return openAiError("Enter a valid email address.", 400, "invalid_request_error", "email");
  }

  const ok = await submitWaitlist(env, deps, {
    name,
    email,
    source: env.WAITLIST_SOURCE || "cursor-api"
  });
  if (!ok) {
    return json({ ok: false, error: "Could not reach the early access list. Please try again shortly." }, { status: 502 });
  }
  return json({ ok: true });
}

async function handleSignup(request: Request, env: Env, ctx: ExecutionContext, deps: Deps): Promise<Response> {
  const body = await parseJsonBody<Record<string, unknown>>(request);
  const cursorApiKey = typeof body.cursorApiKey === "string" ? body.cursorApiKey.trim() : "";
  if (!cursorApiKey) throw new HttpError("Cursor API key is required", 400, "invalid_request_error", "cursorApiKey");

  const me = await verifyCursorApiKey(env, deps, cursorApiKey);
  const name = typeof body.name === "string" ? body.name.trim() : "";
  const email = typeof body.email === "string" ? body.email.trim() : me.userEmail || "";
  const joinWaitlist = body.joinWaitlist === true;
  const signup = await saveSignup(env, cursorApiKey, me, { joinWaitlist });
  if (joinWaitlist) {
    ctx.waitUntil(
      submitWaitlist(env, deps, {
        name: name || [me.userFirstName, me.userLastName].filter(Boolean).join(" ") || me.apiKeyName,
        email,
        source: env.WAITLIST_SOURCE || "composer-api"
      })
    );
  }

  const origin = new URL(request.url).origin;
  const accountBaseUrl = `${origin}/u/${signup.account.id}/v1`;
  return json({
    account: {
      id: signup.account.id,
      cursorEmail: signup.account.cursor_email,
      cursorName: signup.account.cursor_name,
      cursorApiKeyHint: signup.account.cursor_api_key_hint
    },
    apiKey: signup.proxyApiKey,
    endpoints: {
      baseUrl: `${origin}/v1`,
      accountBaseUrl,
      chatCompletions: `${accountBaseUrl}/chat/completions`,
      responses: `${accountBaseUrl}/responses`
    }
  });
}

async function handleOpenAiRoute(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  deps: Deps,
  route: OpenAiRoute
): Promise<Response> {
  if (route.kind === "models") {
    const auth = await authenticate(request, env, route);
    if (!auth) return unauthorized();
    if (request.method !== "GET") return notFound();
    return json(modelList({ opencode: route.surface === "opencode" }));
  }

  if (request.method !== "POST") return notFound();
  const auth = await authenticate(request, env, route);
  if (!auth) return unauthorized();

  const body = await parseJsonBody<unknown>(request);
  const requestedModel = typeof (body as { model?: unknown })?.model === "string" ? (body as { model: string }).model : "composer-2.5";
  const cursorModel = resolveCursorModel(requestedModel);
  const prepared =
    route.kind === "chat" ? prepareChatRequest(body, cursorModel) : prepareResponsesRequest(body, cursorModel);
  const id = `${route.kind === "chat" ? "chatcmpl" : "resp"}_${crypto.randomUUID().replaceAll("-", "")}`;
  const created = Math.floor(deps.now().getTime() / 1000);

  // Direct bearer mode never touches D1; no request logs are created.
  const logId =
    auth.mode === "proxy"
      ? await createRequestLog(env, {
          accountId: auth.accountId,
          endpoint: route.kind,
          model: prepared.model,
          status: "running",
          promptChars: prepared.promptChars
        })
      : null;
  const finishLog = (input: Parameters<typeof completeRequestLog>[2]): Promise<void> =>
    logId ? completeRequestLog(env, logId, input) : Promise.resolve();

  try {
    const completion = await createCursorCompletion(env, deps, auth.cursorApiKey, {
      prompt: prepared.prompt,
      model: prepared.cursorModel
    });

    if (prepared.stream) {
      return streamOpenAiResponse(route.kind, completion.stream, {
        id,
        created,
        model: prepared.model,
        promptChars: prepared.promptChars,
        metadata: prepared.responseMetadata,
        tools: prepared.tools,
        onDone: (text) =>
          finishLog({
            status: "completed",
            completionChars: text.length
          }),
        onError: (error) =>
          finishLog({
            status: "error",
            error: error instanceof Error ? error.message : String(error)
          })
      }, ctx);
    }

    const output = await collectCursorOutput(completion.stream);
    const toolCalls = toOpenAiToolCalls({
      toolCalls: output.toolCalls,
      tools: prepared.tools,
      responseId: id
    });
    const completionChars = output.text.length + toolCalls.reduce((sum, toolCall) => sum + toolCall.function.arguments.length, 0);
    await finishLog({
      status: "completed",
      completionChars
    });
    if (route.kind === "chat") {
      return json(
        chatCompletionResponse({
          id,
          created,
          model: prepared.model,
          text: output.text,
          toolCalls,
          promptChars: prepared.promptChars,
          metadata: prepared.responseMetadata
        })
      );
    }
    return json(
      responseObject({
        id,
        created,
        model: prepared.model,
        text: output.text,
        toolCalls,
        promptChars: prepared.promptChars,
        metadata: prepared.responseMetadata
      })
    );
  } catch (error) {
    await finishLog({
      status: "error",
      error: error instanceof Error ? error.message : String(error)
    }).catch(() => undefined);
    throw error;
  }
}

function streamOpenAiResponse(
  kind: "chat" | "responses",
  cursorStream: Response,
  input: {
    id: string;
    created: number;
    model: string;
    promptChars: number;
    metadata?: Record<string, unknown>;
    tools: OpenAiToolSpec[];
    onDone: (text: string) => Promise<void>;
    onError: (error: unknown) => Promise<void>;
  },
  ctx: ExecutionContext
): Response {
  const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
  const writer = writable.getWriter();
  const pump = async () => {
    let text = "";
    let toolCallCount = 0;
    let finishReason: "stop" | "tool_calls" = "stop";
    const streamedToolCalls: ReturnType<typeof toOpenAiToolCalls> = [];
    try {
      if (kind === "chat") {
        await writer.write(chatChunk({ id: input.id, created: input.created, model: input.model, role: "assistant" }));
      } else {
        for (const event of responseCreatedEvents(input)) await writer.write(event);
      }

      for await (const event of streamCursorText(cursorStream)) {
        if (event.type === "text" && event.text) {
          text += event.text;
          if (kind === "chat") await writer.write(chatChunk({ id: input.id, created: input.created, model: input.model, delta: event.text }));
          else await writer.write(responseDeltaEvent({ id: input.id, delta: event.text }));
        }
        if (event.type === "tool_call") {
          finishReason = "tool_calls";
          const [toolCall] = toOpenAiToolCalls({
            toolCalls: [event.toolCall],
            tools: input.tools,
            responseId: input.id,
            startIndex: toolCallCount
          });
          if (toolCall) streamedToolCalls.push(toolCall);
          if (kind === "chat" && toolCall) {
            await writer.write(chatChunk({ id: input.id, created: input.created, model: input.model, toolCall: { index: toolCallCount, value: toolCall } }));
          }
          toolCallCount += 1;
        }
        if (event.type === "done") {
          text = event.finalText;
        }
      }

      if (kind === "chat") {
        await writer.write(chatChunk({ id: input.id, created: input.created, model: input.model, finish: true, finishReason }));
        await writer.write(doneChunk());
      } else {
        for (const event of responseDoneEvents({ ...input, text, toolCalls: streamedToolCalls })) await writer.write(event);
      }
      await input.onDone(text);
    } catch (error) {
      await input.onError(error);
      const message = error instanceof Error ? error.message : "Stream failed";
      await writer.write(encodeSse({ error: { message, type: "cursor_error", code: "cursor_stream_error" } }, "error"));
    } finally {
      await writer.close().catch(() => undefined);
    }
  };
  ctx.waitUntil(pump());
  return sseResponse(readable);
}

async function authenticate(request: Request, env: Env, route: OpenAiRoute): Promise<AuthResult | null> {
  const token = bearerToken(request);
  if (!token) return null;

  // A `cmp_` token is always a stored proxy key. Authenticate it against D1 and
  // never forward it to Cursor as if it were a Cursor key; fail closed instead.
  if (token.startsWith("cmp_")) {
    const auth = await authenticateProxyKey(env, token);
    if (!auth) return null;
    if (route.accountId && route.accountId !== auth.account.id) {
      throw new HttpError("API key does not belong to this account endpoint", 403, "forbidden");
    }
    return { mode: "proxy", accountId: auth.account.id, cursorApiKey: auth.cursorApiKey };
  }

  // Account-scoped `/u/{accountId}/v1/...` endpoints only accept stored proxy keys.
  if (route.accountId) return null;

  // Bare `/v1/...` request with a non-`cmp_` token: treat it as the caller's own
  // Cursor API key and pass it straight through without storing anything.
  return { mode: "direct", cursorApiKey: token };
}

interface OpenAiRoute {
  kind: "chat" | "responses" | "models";
  accountId?: string;
  surface?: "standard" | "opencode";
}

function matchOpenAiRoute(pathname: string): OpenAiRoute | null {
  const opencodePath = pathname.startsWith("/opencode/v1/") ? pathname.slice("/opencode/v1".length) : "";
  if (opencodePath === "/chat/completions") return { kind: "chat", surface: "opencode" };
  if (opencodePath === "/models") return { kind: "models", surface: "opencode" };

  const accountMatch = /^\/u\/([^/]+)\/v1\/(.+)$/.exec(pathname);
  const accountId = accountMatch?.[1];
  const path = accountMatch ? `/${accountMatch[2]}` : pathname.startsWith("/v1/") ? pathname.slice(3) : "";
  if (path === "/chat/completions") return { kind: "chat", accountId };
  if (path === "/responses") return { kind: "responses", accountId };
  if (path === "/models") return { kind: "models", accountId };
  return null;
}

function isDocumentRequest(request: Request, url: URL): boolean {
  if (request.method !== "GET" && request.method !== "HEAD") return false;
  const accept = request.headers.get("accept") || "";
  return url.pathname === "/" || accept.includes("text/html");
}
