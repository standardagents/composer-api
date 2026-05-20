import { HttpError } from "./http";
import { parseSse } from "./sse";
import type { CursorMe, CursorPrompt, CursorRun, Deps, Env } from "./types";

interface CursorCreateAgentResponse {
  agent: {
    id: string;
    latestRunId?: string;
  };
  run: {
    id: string;
    status: string;
    result?: string;
  };
}

interface CursorModelResponse {
  items?: Array<{ id: string; displayName?: string; aliases?: string[] }>;
}

export async function verifyCursorApiKey(env: Env, deps: Deps, apiKey: string): Promise<CursorMe> {
  return cursorJson<CursorMe>(env, deps, apiKey, "/v1/me");
}

export async function listCursorModels(env: Env, deps: Deps, apiKey: string): Promise<CursorModelResponse> {
  return cursorJson<CursorModelResponse>(env, deps, apiKey, "/v1/models");
}

export function resolveCursorModel(model: unknown): { id: string } | undefined {
  if (typeof model !== "string" || !model.trim()) return { id: "composer-latest" };
  const normalized = model.trim().toLowerCase();
  if (normalized === "composer-2.5" || normalized === "composer-2-5" || normalized === "composer-latest") {
    return { id: "composer-latest" };
  }
  if (normalized === "composer-2.5-fast" || normalized === "composer-2-5-fast") {
    return { id: "composer-latest" };
  }
  if (normalized === "auto") return undefined;
  return { id: model.trim() };
}

export async function createCursorRun(
  env: Env,
  deps: Deps,
  apiKey: string,
  input: { prompt: CursorPrompt; model?: { id: string }; idempotencyKey?: string }
): Promise<CursorRun> {
  const agentId = `bc-${deps.randomUUID()}`;
  const body = {
    agentId,
    prompt: input.prompt,
    ...(input.model ? { model: input.model } : {}),
    name: "Composer API request",
    mcpServers: []
  };
  const created = await cursorJson<CursorCreateAgentResponse>(env, deps, apiKey, "/v1/agents", {
    method: "POST",
    body,
    idempotencyKey: input.idempotencyKey
  });
  const resolvedAgentId = created.agent?.id || agentId;
  const runId = created.run?.id || created.agent?.latestRunId;
  if (!runId) throw new HttpError("Cursor did not return a run id", 502, "cursor_bad_response");

  const streamPath = `/v1/agents/${encodeURIComponent(resolvedAgentId)}/runs/${encodeURIComponent(runId)}/stream`;
  const stream = await cursorRaw(env, deps, apiKey, streamPath, {
    headers: {
      Accept: "text/event-stream",
      "x-cursor-streaming": "true"
    }
  });
  return { agentId: resolvedAgentId, runId, stream };
}

export interface CursorTextEvent {
  type: "text" | "done";
  text?: string;
  finalText?: string;
}

export async function* streamCursorText(response: Response): AsyncGenerator<CursorTextEvent> {
  let text = "";
  let mode: "unknown" | "assistant" | "delta" = "unknown";
  for await (const event of parseSse(response.body)) {
    if (event.event === "done") break;
    if (!event.data) continue;
    let payload: unknown;
    try {
      payload = JSON.parse(event.data);
    } catch {
      continue;
    }

    if (event.event === "interaction_update" && isRecord(payload)) {
      const type = payload.type;
      if (type === "text-delta" && typeof payload.text === "string" && mode !== "assistant") {
        mode = "delta";
        text += payload.text;
        yield { type: "text", text: payload.text };
      } else if (type === "summary" && typeof payload.summary === "string" && !text && mode === "unknown") {
        text = payload.summary;
      }
      continue;
    }

    if (event.event === "assistant" && isRecord(payload) && typeof payload.text === "string" && mode !== "delta") {
      mode = "assistant";
      text += payload.text;
      yield { type: "text", text: payload.text };
      continue;
    }

    if (event.event === "result" && isRecord(payload)) {
      const result = typeof payload.result === "string" ? payload.result : typeof payload.text === "string" ? payload.text : "";
      if (!text && result) text = result;
      yield { type: "done", finalText: text };
      return;
    }

    if (event.event === "error" && isRecord(payload)) {
      const message = typeof payload.message === "string" ? payload.message : "Cursor stream failed";
      throw new HttpError(message, 502, "cursor_stream_error");
    }
  }
  yield { type: "done", finalText: text };
}

export async function collectCursorText(response: Response): Promise<string> {
  let finalText = "";
  for await (const event of streamCursorText(response)) {
    if (event.type === "text" && event.text) finalText += event.text;
    if (event.type === "done" && event.finalText !== undefined) finalText = event.finalText;
  }
  return finalText;
}

async function cursorJson<T>(
  env: Env,
  deps: Deps,
  apiKey: string,
  path: string,
  init: { method?: string; body?: unknown; idempotencyKey?: string } = {}
): Promise<T> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...(init.idempotencyKey ? { "Idempotency-Key": init.idempotencyKey } : {})
  };
  const response = await cursorRaw(env, deps, apiKey, path, {
    method: init.method || "GET",
    headers,
    body: init.body === undefined ? undefined : JSON.stringify(init.body)
  });
  return response.json() as Promise<T>;
}

async function cursorRaw(
  env: Env,
  deps: Deps,
  apiKey: string,
  path: string,
  init: RequestInit = {}
): Promise<Response> {
  const base = env.CURSOR_API_BASE || "https://api.cursor.com";
  const url = `${base.replace(/\/$/, "")}${path}`;
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${apiKey}`);
  headers.set("x-cursor-client-type", "sdk");
  headers.set("x-cursor-client-version", "composer-api-0.1.0");
  headers.set("x-ghost-mode", "true");
  const response = await deps.fetch(url, { ...init, headers });
  if (!response.ok) {
    const text = await response.text().catch(() => "");
    const message =
      response.status === 401
        ? "Invalid Cursor API key"
        : parseCursorError(text) || `Cursor API request failed with status ${response.status}`;
    const status = response.status === 401 ? 401 : response.status === 429 ? 429 : response.status >= 500 ? 502 : 400;
    throw new HttpError(message, status, response.status === 401 ? "cursor_unauthorized" : "cursor_api_error");
  }
  return response;
}

function parseCursorError(text: string): string | undefined {
  try {
    const payload = JSON.parse(text) as unknown;
    if (isRecord(payload)) {
      const error = isRecord(payload.error) ? payload.error : payload;
      if (typeof error.message === "string") return error.message;
    }
  } catch {
    // Ignore JSON parse failures.
  }
  return text || undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
