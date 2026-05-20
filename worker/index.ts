import { collectCursorText, createCursorRun, resolveCursorModel, streamCursorText, verifyCursorApiKey } from "./cursor";
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
  responseObject
} from "./openai";
import { submitWaitlist } from "./waitlist";
import type { AuthenticatedAccount, Deps, Env } from "./types";

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
      const body = (await parseJsonBody<Record<string, unknown>>(request).catch(() => ({}))) as Record<string, unknown>;
      const ok = await submitWaitlist(env, deps, {
        name: typeof body.name === "string" ? body.name : undefined,
        email: typeof body.email === "string" ? body.email : undefined,
        source: env.WAITLIST_SOURCE || "composer-api"
      });
      return json({ ok });
    }

    const route = matchOpenAiRoute(url.pathname);
    if (route) {
      return await handleOpenAiRoute(request, env, ctx, deps, route);
    }

    if (isDocumentRequest(request, url)) {
      return withCors(await env.ASSETS.fetch(request));
    }
    return withCors(await env.ASSETS.fetch(request));
  } catch (error) {
    return errorResponse(error);
  }
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
    const auth = await authenticate(request, env, route.accountId);
    if (!auth) return unauthorized();
    if (request.method !== "GET") return notFound();
    return json(modelList());
  }

  if (request.method !== "POST") return notFound();
  const auth = await authenticate(request, env, route.accountId);
  if (!auth) return unauthorized();

  const body = await parseJsonBody<unknown>(request);
  const requestedModel = typeof (body as { model?: unknown })?.model === "string" ? (body as { model: string }).model : "composer-2.5";
  const cursorModel = resolveCursorModel(requestedModel);
  const prepared =
    route.kind === "chat" ? prepareChatRequest(body, cursorModel) : prepareResponsesRequest(body, cursorModel);
  const id = `${route.kind === "chat" ? "chatcmpl" : "resp"}_${crypto.randomUUID().replaceAll("-", "")}`;
  const created = Math.floor(deps.now().getTime() / 1000);
  const logId = await createRequestLog(env, {
    accountId: auth.account.id,
    endpoint: route.kind,
    model: prepared.model,
    status: "running",
    promptChars: prepared.promptChars
  });

  try {
    const run = await createCursorRun(env, deps, auth.cursorApiKey, {
      prompt: prepared.prompt,
      model: prepared.cursorModel,
      idempotencyKey: request.headers.get("idempotency-key") || undefined
    });

    if (prepared.stream) {
      return streamOpenAiResponse(route.kind, run.stream, {
        id,
        created,
        model: prepared.model,
        promptChars: prepared.promptChars,
        metadata: prepared.responseMetadata,
        onDone: (text) =>
          completeRequestLog(env, logId, {
            status: "completed",
            completionChars: text.length,
            cursorAgentId: run.agentId,
            cursorRunId: run.runId
          }),
        onError: (error) =>
          completeRequestLog(env, logId, {
            status: "error",
            error: error instanceof Error ? error.message : String(error),
            cursorAgentId: run.agentId,
            cursorRunId: run.runId
          })
      }, ctx);
    }

    const text = await collectCursorText(run.stream);
    await completeRequestLog(env, logId, {
      status: "completed",
      completionChars: text.length,
      cursorAgentId: run.agentId,
      cursorRunId: run.runId
    });
    if (route.kind === "chat") {
      return json(
        chatCompletionResponse({
          id,
          created,
          model: prepared.model,
          text,
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
        text,
        promptChars: prepared.promptChars,
        metadata: prepared.responseMetadata
      })
    );
  } catch (error) {
    await completeRequestLog(env, logId, {
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
    onDone: (text: string) => Promise<void>;
    onError: (error: unknown) => Promise<void>;
  },
  ctx: ExecutionContext
): Response {
  const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
  const writer = writable.getWriter();
  const pump = async () => {
    let text = "";
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
        if (event.type === "done" && event.finalText !== undefined) {
          text = event.finalText;
        }
      }

      if (kind === "chat") {
        await writer.write(chatChunk({ id: input.id, created: input.created, model: input.model, finish: true }));
        await writer.write(doneChunk());
      } else {
        for (const event of responseDoneEvents({ ...input, text })) await writer.write(event);
      }
      await input.onDone(text);
    } catch (error) {
      await input.onError(error);
      const message = error instanceof Error ? error.message : "Stream failed";
      await writer.write(
        kind === "chat"
          ? chatChunk({ id: input.id, created: input.created, model: input.model, delta: `\n[composer-api error] ${message}` })
          : responseDeltaEvent({ id: input.id, delta: `\n[composer-api error] ${message}` })
      );
    } finally {
      await writer.close().catch(() => undefined);
    }
  };
  ctx.waitUntil(pump());
  return sseResponse(readable);
}

async function authenticate(request: Request, env: Env, pathAccountId?: string): Promise<AuthenticatedAccount | null> {
  const token = bearerToken(request);
  if (!token) return null;
  const auth = await authenticateProxyKey(env, token);
  if (!auth) return null;
  if (pathAccountId && pathAccountId !== auth.account.id) {
    throw new HttpError("API key does not belong to this account endpoint", 403, "forbidden");
  }
  return auth;
}

interface OpenAiRoute {
  kind: "chat" | "responses" | "models";
  accountId?: string;
}

function matchOpenAiRoute(pathname: string): OpenAiRoute | null {
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
