import { collectCursorOutput, createCursorCompletion, resolveCursorModel, streamCursorText, verifyCursorApiKey } from "./cursor";
import { collectCursorSdkOutput, createCursorSdkCompletion } from "./cursor-sdk";
import { sha256Hex } from "./crypto";
import { authenticateProxyKey, completeRequestLog, createRequestLog, saveSignup } from "./db";
import { bearerToken, errorResponse, HttpError, json, notFound, openAiError, optionsResponse, parseJsonBody, sseResponse, unauthorized, withCors } from "./http";
import {
  chatChunk,
  chatCompletionResponse,
  chatUsageChunk,
  completionCharsFromOutput,
  doneChunk,
  modelList,
  prepareChatRequest,
  prepareOpencodeSdkChatRequest,
  prepareResponsesRequest,
  responseCreatedEvents,
  responseDeltaEvent,
  responseDoneEvents,
  responseInputItemsObject,
  responseObject,
  responseTextStartEvents,
  responseToolCallEvents,
  toolCallRetryHint,
  toOpenAiToolCalls
} from "./openai";
import { submitWaitlist } from "./waitlist";
import { encodeSse } from "./sse";
import type { Deps, Env } from "./types";
import type { CursorTextEvent } from "./cursor";
import type { ToolCallContext } from "./openai";
import type { OpenAiToolSpec } from "./openai";

export { CursorSdkBridgeContainer } from "./sdk-bridge-container";

/**
 * The two ways a `/v1/...` request can be authenticated:
 * - `proxy`: a stored `cmp_...` key resolved against D1 (hosted-key flow).
 * - `direct`: a Cursor API key passed straight through; nothing is stored.
 */
type AuthResult =
  | { mode: "proxy"; accountId: string; cursorApiKey: string }
  | { mode: "direct"; cursorApiKey: string };

interface StoredResponseState {
  ownerKey: string;
  id: string;
  response?: Record<string, unknown>;
  inputItems: unknown[];
  outputItems: unknown[];
  updatedAt: number;
}

const responseState = new Map<string, StoredResponseState>();
const RESPONSE_STATE_LIMIT = 512;

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
    return json(modelList({ opencode: route.surface === "opencode" || route.surface === "opencodev2", sdk: route.surface === "opencodev2" }));
  }

  if (route.kind === "response" || route.kind === "responseInputItems" || route.kind === "responseCancel") {
    const auth = await authenticate(request, env, route);
    if (!auth) return unauthorized();
    return handleResponseStateRoute(request, auth, route);
  }

  if (request.method !== "POST") return notFound();
  const auth = await authenticate(request, env, route);
  if (!auth) return unauthorized();

  const body = await parseJsonBody<unknown>(request);
  const requestedModel = typeof (body as { model?: unknown })?.model === "string" ? (body as { model: string }).model : "composer-2.5";
  const cursorModel = resolveCursorModel(requestedModel);
  if (route.surface === "opencodev2" && route.kind === "chat") {
    return handleOpenCodeSdkChatRoute(request, env, ctx, deps, auth, body, cursorModel);
  }

  const responseOwner = route.kind === "responses" ? await responseOwnerKey(auth) : undefined;
  const previousResponseId = route.kind === "responses" ? previousResponseIdFromBody(body) : undefined;
  const previousState = previousResponseId && responseOwner ? getResponseState(responseOwner, previousResponseId) : undefined;
  if (previousResponseId && !previousState) throw new HttpError("Response not found", 404, "not_found");
  const prepared =
    route.kind === "chat"
      ? prepareChatRequest(body, cursorModel, { forceAgentMode: route.surface === "opencode" })
      : prepareResponsesRequest(body, cursorModel, {
          previousOutput: previousState?.outputItems,
          previousInputItems: previousState?.inputItems
        });
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
      model: prepared.cursorModel,
      conversationKey: route.surface === "opencode" ? sessionAffinity(request) : undefined
    });

    if (prepared.stream) {
      return streamOpenAiResponse(route.kind, completion.stream, {
        id,
        created,
        model: prepared.model,
        promptChars: prepared.promptChars,
        includeUsage: prepared.includeUsage,
        metadata: prepared.responseMetadata,
        tools: prepared.tools,
        context: prepared.toolContext,
        onDone: async (text, completionChars, toolCalls) => {
          if (route.kind === "responses" && responseOwner) {
            const completed = responseObject({
              id,
              created,
              model: prepared.model,
              text,
              toolCalls,
              promptChars: prepared.promptChars,
              metadata: prepared.responseMetadata
            });
            storeResponseState(responseOwner, {
              id,
              response: completed,
              inputItems: prepared.responseInputItems ?? [],
              outputItems: (completed.output as unknown[]) ?? [],
              store: prepared.storeResponse !== false,
              now: deps.now().getTime()
            });
          }
          return finishLog({
            status: "completed",
            completionChars
          });
        },
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
      responseId: id,
      context: prepared.toolContext
    });
    const completionChars = completionCharsFromOutput(output.text, toolCalls);
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
    const response = responseObject({
        id,
        created,
        model: prepared.model,
        text: output.text,
        toolCalls,
        promptChars: prepared.promptChars,
        metadata: prepared.responseMetadata
      });
    if (responseOwner) {
      storeResponseState(responseOwner, {
        id,
        response,
        inputItems: prepared.responseInputItems ?? [],
        outputItems: (response.output as unknown[]) ?? [],
        store: prepared.storeResponse !== false,
        now: deps.now().getTime()
      });
    }
    return json(response);
  } catch (error) {
    await finishLog({
      status: "error",
      error: error instanceof Error ? error.message : String(error)
    }).catch(() => undefined);
    throw error;
  }
}

async function handleOpenCodeSdkChatRoute(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  deps: Deps,
  auth: AuthResult,
  body: unknown,
  cursorModel: { id: string } | undefined
): Promise<Response> {
  const prepared = prepareOpencodeSdkChatRequest(body, cursorModel);
  const id = `chatcmpl_${crypto.randomUUID().replaceAll("-", "")}`;
  const created = Math.floor(deps.now().getTime() / 1000);
  const logId =
    auth.mode === "proxy"
      ? await createRequestLog(env, {
          accountId: auth.accountId,
          endpoint: "chat",
          model: prepared.model,
          status: "running",
          promptChars: prepared.promptChars
        })
      : null;
  const finishLog = (input: Parameters<typeof completeRequestLog>[2]): Promise<void> =>
    logId ? completeRequestLog(env, logId, input) : Promise.resolve();

  try {
    const completion = await createCursorSdkCompletion(env, deps, auth.cursorApiKey, {
      prompt: prepared.prompt,
      model: prepared.cursorModel,
      sessionKey: sessionAffinity(request),
      sessionOwnerKey: sdkSessionOwner(auth),
      workingDirectory: prepared.toolContext?.workingDirectory,
      clientTools: prepared.tools,
      requiresLocalTool: prepared.requiresLocalTool,
      allowToolCall: (toolCall) => {
        const toolCalls = toOpenAiToolCalls({
          toolCalls: [toolCall],
          tools: prepared.tools,
          responseId: "probe",
          context: prepared.toolContext
        });
        return toolCalls.length > 0
          || toolCallRetryHint({ toolCall, tools: prepared.tools, context: prepared.toolContext });
      }
    });

    if (prepared.stream) {
      return streamOpenAiEvents("chat", completion.stream, {
        id,
        created,
        model: prepared.model,
        promptChars: prepared.promptChars,
        includeUsage: prepared.includeUsage,
        metadata: prepared.responseMetadata,
        tools: prepared.tools,
        context: prepared.toolContext,
        onDone: (_text, completionChars) =>
          finishLog({
            status: "completed",
            completionChars,
            cursorAgentId: completion.agentId,
            cursorRunId: completion.runId
          }),
        onError: (error) =>
          finishLog({
            status: "error",
            error: error instanceof Error ? error.message : String(error),
            cursorAgentId: completion.agentId,
            cursorRunId: completion.runId
          })
      }, ctx);
    }

    const output = await collectCursorSdkOutput(completion.stream);
    const toolCalls = toOpenAiToolCalls({
      toolCalls: output.toolCalls,
      tools: prepared.tools,
      responseId: id,
      context: prepared.toolContext
    });
    const completionChars = completionCharsFromOutput(output.text, toolCalls);
    await finishLog({
      status: "completed",
      completionChars,
      cursorAgentId: completion.agentId,
      cursorRunId: completion.runId
    });
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
    includeUsage: boolean;
    metadata?: Record<string, unknown>;
    tools: OpenAiToolSpec[];
    context?: ToolCallContext;
    onDone: (text: string, completionChars: number, toolCalls: ReturnType<typeof toOpenAiToolCalls>) => Promise<void>;
    onError: (error: unknown) => Promise<void>;
  },
  ctx: ExecutionContext
): Response {
  return streamOpenAiEvents(kind, streamCursorText(cursorStream), input, ctx);
}

function streamOpenAiEvents(
  kind: "chat" | "responses",
  cursorEvents: AsyncIterable<CursorTextEvent>,
  input: {
    id: string;
    created: number;
    model: string;
    promptChars: number;
    includeUsage: boolean;
    metadata?: Record<string, unknown>;
    tools: OpenAiToolSpec[];
    context?: ToolCallContext;
    onDone: (text: string, completionChars: number, toolCalls: ReturnType<typeof toOpenAiToolCalls>) => Promise<void>;
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
    let responseNextOutputIndex = 0;
    let responseTextOutputIndex: number | null = null;
    try {
      if (kind === "chat") {
        await writer.write(chatChunk({ id: input.id, created: input.created, model: input.model, role: "assistant" }));
      } else {
        for (const event of responseCreatedEvents(input)) await writer.write(event);
      }

      for await (const event of cursorEvents) {
        if (event.type === "text" && event.text) {
          text += event.text;
          if (kind === "chat") await writer.write(chatChunk({ id: input.id, created: input.created, model: input.model, delta: event.text }));
          else {
            if (responseTextOutputIndex === null) {
              responseTextOutputIndex = responseNextOutputIndex;
              responseNextOutputIndex += 1;
              for (const chunk of responseTextStartEvents({ id: input.id, outputIndex: responseTextOutputIndex })) await writer.write(chunk);
            }
            await writer.write(responseDeltaEvent({ id: input.id, delta: event.text, outputIndex: responseTextOutputIndex }));
          }
        }
        if (event.type === "tool_call") {
          const [toolCall] = toOpenAiToolCalls({
            toolCalls: [event.toolCall],
            tools: input.tools,
            responseId: input.id,
            startIndex: toolCallCount,
            context: input.context
          });
          if (!toolCall) continue;
          finishReason = "tool_calls";
          streamedToolCalls.push(toolCall);
          if (kind === "chat") {
            await writer.write(chatChunk({ id: input.id, created: input.created, model: input.model, toolCall: { index: toolCallCount, value: toolCall } }));
          } else {
            for (const chunk of responseToolCallEvents({ id: input.id, toolCall, outputIndex: responseNextOutputIndex })) await writer.write(chunk);
            responseNextOutputIndex += 1;
          }
          toolCallCount += 1;
        }
        if (event.type === "done") {
          text = event.finalText;
        }
      }

      if (kind === "chat") {
        const completionChars = completionCharsFromOutput(text, streamedToolCalls);
        await writer.write(chatChunk({ id: input.id, created: input.created, model: input.model, finish: true, finishReason }));
        if (input.includeUsage) {
          await writer.write(
            chatUsageChunk({
              id: input.id,
              created: input.created,
              model: input.model,
              promptChars: input.promptChars,
              completionChars
            })
          );
        }
        await writer.write(doneChunk());
      } else {
        if (responseTextOutputIndex === null && !streamedToolCalls.length) {
          responseTextOutputIndex = responseNextOutputIndex;
          responseNextOutputIndex += 1;
          for (const chunk of responseTextStartEvents({ id: input.id, outputIndex: responseTextOutputIndex })) await writer.write(chunk);
        }
        for (const event of responseDoneEvents({
          ...input,
          text,
          toolCalls: streamedToolCalls,
          textStarted: responseTextOutputIndex !== null,
          textOutputIndex: responseTextOutputIndex ?? 0
        })) await writer.write(event);
      }
      await input.onDone(text, completionCharsFromOutput(text, streamedToolCalls), streamedToolCalls);
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

function sessionAffinity(request: Request): string | undefined {
  return (
    request.headers.get("x-session-affinity") ||
    request.headers.get("x-opencode-session-id") ||
    request.headers.get("x-opencode-session")
  )?.trim() || undefined;
}

function sdkSessionOwner(auth: AuthResult): string | undefined {
  return auth.mode === "proxy" ? `account:${auth.accountId}` : undefined;
}

async function handleResponseStateRoute(request: Request, auth: AuthResult, route: OpenAiRoute): Promise<Response> {
  if (!route.responseId) return notFound();
  const ownerKey = await responseOwnerKey(auth);
  const state = getResponseState(ownerKey, route.responseId);
  if (!state) throw new HttpError("Response not found", 404, "not_found");

  if (route.kind === "response") {
    if (request.method === "GET" || request.method === "HEAD") {
      if (!state.response) throw new HttpError("Response not found", 404, "not_found");
      return json(state.response);
    }
    if (request.method === "DELETE") {
      responseState.delete(responseStateKey(ownerKey, route.responseId));
      return json({ id: route.responseId, object: "response", deleted: true });
    }
    return notFound();
  }

  if (route.kind === "responseInputItems") {
    if (request.method !== "GET" && request.method !== "HEAD") return notFound();
    if (!state.response) throw new HttpError("Response not found", 404, "not_found");
    return json(responseInputItemsObject(state.inputItems));
  }

  if (route.kind === "responseCancel") {
    if (request.method !== "POST") return notFound();
    throw new HttpError("Only background responses can be cancelled. API for Cursor runs responses synchronously.", 400, "invalid_request_error");
  }

  return notFound();
}

function previousResponseIdFromBody(body: unknown): string | undefined {
  if (!isRecordLike(body)) return undefined;
  const value = body.previous_response_id;
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

async function responseOwnerKey(auth: AuthResult): Promise<string> {
  if (auth.mode === "proxy") return `account:${auth.accountId}`;
  return `direct:${(await sha256Hex(auth.cursorApiKey)).slice(0, 24)}`;
}

function getResponseState(ownerKey: string, responseId: string): StoredResponseState | undefined {
  return responseState.get(responseStateKey(ownerKey, responseId));
}

function storeResponseState(
  ownerKey: string,
  input: {
    id: string;
    response: Record<string, unknown>;
    inputItems: unknown[];
    outputItems: unknown[];
    store: boolean;
    now: number;
  }
) {
  const key = responseStateKey(ownerKey, input.id);
  responseState.set(key, {
    ownerKey,
    id: input.id,
    response: input.store ? input.response : undefined,
    inputItems: input.store ? input.inputItems : [],
    outputItems: input.outputItems,
    updatedAt: input.now
  });
  pruneResponseState();
}

function responseStateKey(ownerKey: string, responseId: string): string {
  return `${ownerKey}:${responseId}`;
}

function pruneResponseState() {
  if (responseState.size <= RESPONSE_STATE_LIMIT) return;
  const entries = [...responseState.entries()].sort((a, b) => a[1].updatedAt - b[1].updatedAt);
  for (const [key] of entries.slice(0, responseState.size - RESPONSE_STATE_LIMIT)) {
    responseState.delete(key);
  }
}

function isRecordLike(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
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
  kind: "chat" | "responses" | "models" | "response" | "responseInputItems" | "responseCancel";
  accountId?: string;
  responseId?: string;
  surface?: "standard" | "opencode" | "opencodev2";
}

function matchOpenAiRoute(pathname: string): OpenAiRoute | null {
  const opencodePath = pathname.startsWith("/opencode/v1/") ? pathname.slice("/opencode/v1".length) : "";
  if (opencodePath === "/chat/completions") return { kind: "chat", surface: "opencode" };
  if (opencodePath === "/models") return { kind: "models", surface: "opencode" };
  const opencodeV2Path = pathname.startsWith("/opencodev2/v1/") ? pathname.slice("/opencodev2/v1".length) : "";
  if (opencodeV2Path === "/chat/completions") return { kind: "chat", surface: "opencodev2" };
  if (opencodeV2Path === "/models") return { kind: "models", surface: "opencodev2" };

  const accountMatch = /^\/u\/([^/]+)\/v1\/(.+)$/.exec(pathname);
  const accountId = accountMatch?.[1];
  const path = accountMatch ? `/${accountMatch[2]}` : pathname.startsWith("/v1/") ? pathname.slice(3) : "";
  if (path === "/chat/completions") return { kind: "chat", accountId };
  if (path === "/responses") return { kind: "responses", accountId };
  const responseInputItemsMatch = /^\/responses\/([^/]+)\/input_items\/?$/.exec(path);
  if (responseInputItemsMatch) return { kind: "responseInputItems", accountId, responseId: responseInputItemsMatch[1] };
  const responseCancelMatch = /^\/responses\/([^/]+)\/cancel\/?$/.exec(path);
  if (responseCancelMatch) return { kind: "responseCancel", accountId, responseId: responseCancelMatch[1] };
  const responseMatch = /^\/responses\/([^/]+)\/?$/.exec(path);
  if (responseMatch) return { kind: "response", accountId, responseId: responseMatch[1] };
  if (path === "/models") return { kind: "models", accountId };
  return null;
}

function isDocumentRequest(request: Request, url: URL): boolean {
  if (request.method !== "GET" && request.method !== "HEAD") return false;
  const accept = request.headers.get("accept") || "";
  return url.pathname === "/" || accept.includes("text/html");
}
