import { HttpError } from "./http";
import { parseSse } from "./sse";
import type { CursorCompletion, CursorImage, CursorMe, CursorPrompt, CursorToolCall, Deps, Env } from "./types";

interface CursorModelResponse {
  items?: Array<{ id: string; displayName?: string; aliases?: string[] }>;
}

interface CursorAccessTokenResponse {
  accessToken?: string;
}

interface ProtobufField {
  no: number;
  wt: number;
  value: number | Uint8Array;
}

const cursorIdentityCache = new Map<string, { identity: string; expiresAt: number }>();
const COMPOSER_CONTROL_TOKEN_PATTERN = /<\/think>|<\s*[|｜]\s*final\s*[|｜]\s*>/g;
const MAX_CURSOR_IMAGE_BYTES = 1024 * 1024;

interface EncodedCursorImage {
  data: Uint8Array;
  dimension?: { width: number; height: number };
  uuid: string;
}

export async function verifyCursorApiKey(env: Env, deps: Deps, apiKey: string): Promise<CursorMe> {
  return cursorPublicJson<CursorMe>(env, deps, apiKey, "/v1/me");
}

export async function listCursorModels(env: Env, deps: Deps, apiKey: string): Promise<CursorModelResponse> {
  return cursorPublicJson<CursorModelResponse>(env, deps, apiKey, "/v1/models");
}

export function resolveCursorModel(model: unknown): { id: string } | undefined {
  if (typeof model !== "string" || !model.trim()) return { id: "composer-2.5" };
  const normalized = model.trim().toLowerCase();
  if (normalized === "composer-2.5" || normalized === "composer-2-5" || normalized === "composer-2.5-sdk" || normalized === "composer-latest") {
    return { id: "composer-2.5" };
  }
  if (normalized === "composer-2.5-fast" || normalized === "composer-2-5-fast") {
    return { id: "composer-2.5-fast" };
  }
  if (normalized === "auto" || normalized === "default") return { id: "composer-2.5" };
  return { id: model.trim() };
}

export async function createCursorCompletion(
  env: Env,
  deps: Deps,
  apiKey: string,
  input: { prompt: CursorPrompt; model?: { id: string }; conversationKey?: string }
): Promise<CursorCompletion> {
  const images = await resolveCursorImages(input.prompt.images ?? [], deps);
  const cursorIdentity = await getCursorAccountIdentity(env, deps, apiKey);
  const accessToken = await exchangeCursorApiKey(env, deps, apiKey);
  const requestId = deps.randomUUID();
  const conversationId = input.conversationKey
    ? await stableUuid("composer-api-conversation", `${cursorIdentity}:${input.conversationKey}`)
    : deps.randomUUID();
  const requestBody = encodeConnectFrame(
    encodeCursorChatRequest({
      prompt: input.prompt,
      images,
      model: input.model?.id || "composer-2.5",
      requestId,
      conversationId,
      messageId: deps.randomUUID()
    })
  );
  const response = await cursorInternalRaw(env, deps, accessToken, cursorChatEndpoint(env), {
    method: "POST",
    headers: await cursorInternalHeaders(env, accessToken, cursorIdentity, requestId),
    body: requestBody.buffer as ArrayBuffer
  });
  return { requestId, conversationId, stream: response };
}

export const cursorTestExports = {
  encodeCursorChatRequest,
  parseComposerToolCalls,
  cursorIdentityCache,
  evictExpiredCacheEntries
};

export type CursorTextEvent =
  | { type: "text"; text: string }
  | { type: "tool_call"; toolCall: CursorToolCall }
  | { type: "done"; finalText: string; toolCalls: CursorToolCall[] };

export async function* streamCursorText(response: Response): AsyncGenerator<CursorTextEvent> {
  const contentType = response.headers.get("content-type") || "";
  if (!contentType.includes("application/connect+proto")) {
    yield* streamLegacyAgentText(response);
    return;
  }

  let text = "";
  const toolCalls: CursorToolCall[] = [];
  const thinking = new ThinkingTextExtractor();
  const output = new ComposerOutputFilter();
  const toolMarkers = new ComposerToolCallFilter();
  const emit = function* (value: string): Generator<CursorTextEvent> {
    for (const delta of output.push(value)) {
      for (const event of toolMarkers.push(delta)) {
        if (event.type === "text") {
          text += event.text;
          yield event;
        } else {
          toolCalls.push(event.toolCall);
          yield event;
        }
      }
    }
  };
  for await (const frame of parseConnectProtoFrames(response.body)) {
    const event = decodeCursorChatFrame(frame);
    if (event.type === "error") throw new HttpError(event.message, 502, "cursor_stream_error");
    if (event.type === "tool_call") {
      if (event.toolCall) {
        toolCalls.push(event.toolCall);
        yield { type: "tool_call", toolCall: event.toolCall };
      }
      continue;
    }
    if (event.type === "text" && event.text) {
      yield* emit(event.text);
    }
    if (event.type === "thinking" && event.text) {
      for (const delta of thinking.push(event.text)) {
        yield* emit(delta);
      }
    }
  }
  const flushed = thinking.flush();
  if (flushed) {
    yield* emit(flushed);
  }
  for (const delta of output.flush()) {
    for (const event of toolMarkers.push(delta)) {
      if (event.type === "text") {
        text += event.text;
        yield event;
      } else {
        toolCalls.push(event.toolCall);
        yield event;
      }
    }
  }
  for (const event of toolMarkers.flush()) {
    if (event.type === "text") {
      text += event.text;
      yield event;
    } else {
      toolCalls.push(event.toolCall);
      yield event;
    }
  }
  yield { type: "done", finalText: text, toolCalls };
}

async function* streamLegacyAgentText(response: Response): AsyncGenerator<CursorTextEvent> {
  let text = "";
  const toolCalls: CursorToolCall[] = [];
  let mode: "unknown" | "assistant" | "delta" = "unknown";
  const toolMarkers = new ComposerToolCallFilter();
  const emit = function* (value: string): Generator<CursorTextEvent> {
    for (const event of toolMarkers.push(value)) {
      if (event.type === "text") {
        text += event.text;
        yield event;
      } else {
        toolCalls.push(event.toolCall);
        yield event;
      }
    }
  };
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
        const delta = stripComposerControlTokens(payload.text);
        if (delta) yield* emit(delta);
      } else if (type === "summary" && typeof payload.summary === "string" && !text && mode === "unknown") {
        text = stripComposerControlTokens(payload.summary);
      }
      continue;
    }

    if (event.event === "assistant" && isRecord(payload) && typeof payload.text === "string" && mode !== "delta") {
      mode = "assistant";
      const delta = stripComposerControlTokens(payload.text);
      if (delta) yield* emit(delta);
      continue;
    }

    if (event.event === "result" && isRecord(payload)) {
      const rawResult = typeof payload.result === "string" ? payload.result : typeof payload.text === "string" ? payload.text : "";
      const result = stripComposerControlTokens(rawResult);
      if (!text && result) {
        for (const emitted of emit(result)) yield emitted;
      }
      for (const emitted of toolMarkers.flush()) {
        if (emitted.type === "text") {
          text += emitted.text;
          yield emitted;
        } else {
          toolCalls.push(emitted.toolCall);
          yield emitted;
        }
      }
      yield { type: "done", finalText: text, toolCalls };
      return;
    }

    if (event.event === "error" && isRecord(payload)) {
      const message = typeof payload.message === "string" ? payload.message : "Cursor stream failed";
      throw new HttpError(message, 502, "cursor_stream_error");
    }
  }
  for (const emitted of toolMarkers.flush()) {
    if (emitted.type === "text") {
      text += emitted.text;
      yield emitted;
    } else {
      toolCalls.push(emitted.toolCall);
      yield emitted;
    }
  }
  yield { type: "done", finalText: text, toolCalls };
}

export interface CursorCollectedOutput {
  text: string;
  toolCalls: CursorToolCall[];
}

export async function collectCursorOutput(response: Response): Promise<CursorCollectedOutput> {
  let text = "";
  let toolCalls: CursorToolCall[] = [];
  for await (const event of streamCursorText(response)) {
    if (event.type === "text" && event.text) text += event.text;
    if (event.type === "tool_call") toolCalls.push(event.toolCall);
    if (event.type === "done") {
      text = event.finalText;
      toolCalls = event.toolCalls;
    }
  }
  return { text, toolCalls };
}

export async function collectCursorText(response: Response): Promise<string> {
  return (await collectCursorOutput(response)).text;
}

export async function exchangeCursorApiKey(env: Env, deps: Deps, apiKey: string): Promise<string> {
  const response = await cursorInternalRaw(env, deps, apiKey, "/auth/exchange_user_api_key", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{}"
  });
  const payload = (await response.json()) as CursorAccessTokenResponse;
  if (!payload.accessToken) throw new HttpError("Cursor did not return an internal access token", 502, "cursor_bad_response");
  return payload.accessToken;
}

async function getCursorAccountIdentity(env: Env, deps: Deps, apiKey: string): Promise<string> {
  const apiKeyHash = await sha256Hex(apiKey);
  const now = deps.now().getTime();
  const cached = cursorIdentityCache.get(apiKeyHash);
  if (cached && cached.expiresAt > now) return cached.identity;
  // Lazy eviction: remove the expired entry so the cache stays bounded.
  if (cached) cursorIdentityCache.delete(apiKeyHash);

  const me = await verifyCursorApiKey(env, deps, apiKey);
  const identity =
    typeof me.userId === "number"
      ? `cursor-user:${me.userId}`
      : me.userEmail
        ? `cursor-email:${me.userEmail.trim().toLowerCase()}`
        : `cursor-key:${apiKeyHash}`;

  cursorIdentityCache.set(apiKeyHash, { identity, expiresAt: now + 60 * 60 * 1000 });
  // Periodic sweep: evict any other expired entries to prevent unbounded growth
  // from keys that are never looked up again.
  evictExpiredCacheEntries(now);
  return identity;
}

function evictExpiredCacheEntries(now: number): void {
  for (const [key, entry] of cursorIdentityCache.entries()) {
    if (entry.expiresAt <= now) cursorIdentityCache.delete(key);
  }
}

async function cursorPublicJson<T>(
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
  const response = await cursorPublicRaw(env, deps, apiKey, path, {
    method: init.method || "GET",
    headers,
    body: init.body === undefined ? undefined : JSON.stringify(init.body)
  });
  return response.json() as Promise<T>;
}

async function cursorPublicRaw(
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

async function cursorInternalRaw(
  env: Env,
  deps: Deps,
  token: string,
  path: string,
  init: RequestInit = {}
): Promise<Response> {
  const base = env.CURSOR_BACKEND_BASE_URL?.trim();
  if (!base) throw new HttpError("Cursor backend URL is not configured", 500, "cursor_missing_backend_url");
  const url = /^https?:\/\//.test(path) ? path : `${base.replace(/\/$/, "")}${path.startsWith("/") ? path : `/${path}`}`;
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${token}`);
  const response = await deps.fetch(url, { ...init, headers });
  if (!response.ok) {
    const text = await response.text().catch(() => "");
    const parsed = parseCursorError(text);
    const message =
      response.status === 401
        ? "Invalid Cursor API key"
        : parsed ||
          (response.status === 464
            ? "Cursor rejected the proxied chat request. The proxy request is valid, but Cursor refused this account/session."
            : `Cursor internal API request failed with status ${response.status}`);
    const status =
      response.status === 401 ? 401 : response.status === 429 ? 429 : response.status >= 500 || response.status === 464 ? 502 : 400;
    throw new HttpError(message, status, response.status === 401 ? "cursor_unauthorized" : "cursor_api_error");
  }
  return response;
}

function cursorChatEndpoint(env: Env): string {
  const endpoint = env.CURSOR_CHAT_ENDPOINT?.trim();
  if (!endpoint) throw new HttpError("Cursor chat endpoint is not configured", 500, "cursor_missing_endpoint");
  return endpoint;
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

async function cursorInternalHeaders(env: Env, accessToken: string, cursorIdentity: string, requestId: string): Promise<Record<string, string>> {
  return {
    "Content-Type": "application/connect+proto",
    "Connect-Protocol-Version": "1",
    "User-Agent": "connect-es/1.6.1",
    "x-amzn-trace-id": `Root=${requestId}`,
    "x-client-key": await sha256Hex(accessToken),
    "x-cursor-checksum": await cursorChecksum(env, cursorIdentity),
    "x-cursor-client-version": env.CURSOR_CLIENT_VERSION || "2.6.22",
    "x-cursor-client-type": "ide",
    "x-cursor-client-os": "linux",
    "x-cursor-client-arch": "x64",
    "x-cursor-client-os-version": "unknown",
    "x-cursor-client-device-type": "desktop",
    "x-cursor-config-version": await stableUuid("cursor-config", cursorIdentity),
    "x-cursor-timezone": "UTC",
    "x-ghost-mode": "false",
    "x-new-onboarding-completed": "false",
    "x-request-id": requestId,
    "x-session-id": await sessionId(accessToken)
  };
}

function encodeCursorChatRequest(input: {
  prompt: CursorPrompt;
  images?: EncodedCursorImage[];
  model: string;
  requestId: string;
  conversationId: string;
  messageId: string;
}): Uint8Array {
  const messageId = input.messageId;
  const composerMode = input.prompt.mode === "agent" ? "Agent" : "Ask";
  const imageFields = (input.images ?? []).map((image) => protoField(10, 2, encodeImageProto(image)));
  const userMessage = protoMessage([
    protoField(1, 2, input.prompt.text),
    protoField(2, 0, 1),
    ...imageFields,
    protoField(13, 2, messageId),
    protoField(47, 0, 1)
  ]);
  const model = protoMessage([protoField(1, 2, input.model), protoField(4, 2, new Uint8Array(0))]);
  const cursorSetting = protoMessage([
    protoField(1, 2, "cursor\\aisettings"),
    protoField(3, 2, new Uint8Array(0)),
    protoField(6, 2, protoMessage([protoField(1, 2, new Uint8Array(0)), protoField(2, 2, new Uint8Array(0))])),
    protoField(8, 0, 1),
    protoField(9, 0, 1)
  ]);
  const metadata = protoMessage([
    protoField(1, 2, "linux"),
    protoField(2, 2, "x64"),
    protoField(3, 2, "unknown"),
    protoField(4, 2, "composer-api"),
    protoField(5, 2, new Date().toISOString())
  ]);
  const messageIdRecord = protoMessage([protoField(1, 2, messageId), protoField(3, 0, 1)]);
  const request = protoMessage([
    protoField(1, 2, userMessage),
    protoField(2, 0, 1),
    protoField(3, 2, new Uint8Array(0)),
    protoField(4, 0, 1),
    protoField(5, 2, model),
    protoField(8, 2, ""),
    protoField(13, 0, 1),
    protoField(15, 2, cursorSetting),
    protoField(19, 0, 1),
    protoField(23, 2, input.conversationId),
    protoField(26, 2, metadata),
    protoField(27, 0, 0),
    protoField(30, 2, messageIdRecord),
    protoField(35, 0, 0),
    protoField(38, 0, 0),
    protoField(46, 0, 1),
    protoField(47, 2, ""),
    protoField(48, 0, 0),
    protoField(49, 0, 0),
    protoField(51, 0, 0),
    protoField(53, 0, 1),
    protoField(54, 2, composerMode)
  ]);
  return protoMessage([protoField(1, 2, request)]);
}

async function resolveCursorImages(images: CursorImage[], deps: Deps): Promise<EncodedCursorImage[]> {
  const encoded: EncodedCursorImage[] = [];
  for (const [index, image] of images.entries()) {
    const data = "data" in image ? decodeBase64(image.data) : await fetchImageBytes(image.url, deps);
    if (!data.length) throw new HttpError("Image input is empty.", 400, "invalid_request_error", "image");
    if (data.length > MAX_CURSOR_IMAGE_BYTES) {
      throw new HttpError(
        "Image input is too large. Resize images to 1024px or less and keep each image under 1MB.",
        400,
        "invalid_request_error",
        "image"
      );
    }
    encoded.push({
      data,
      uuid: image.uuid || stableImageId(index),
      ...("dimension" in image && image.dimension ? { dimension: image.dimension } : {})
    });
  }
  return encoded;
}

async function fetchImageBytes(url: string, deps: Deps): Promise<Uint8Array> {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new HttpError("Image URL is invalid.", 400, "invalid_request_error", "image_url");
  }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
    throw new HttpError("Image URL must use http or https.", 400, "invalid_request_error", "image_url");
  }
  const response = await deps.fetch(parsed.toString(), { method: "GET" });
  if (!response.ok) {
    throw new HttpError(`Could not fetch image URL (${response.status}).`, 400, "invalid_request_error", "image_url");
  }
  const contentType = response.headers.get("content-type") || "";
  if (contentType && !contentType.toLowerCase().startsWith("image/")) {
    throw new HttpError("Image URL did not return an image content type.", 400, "invalid_request_error", "image_url");
  }
  return new Uint8Array(await response.arrayBuffer());
}

function encodeImageProto(image: EncodedCursorImage): Uint8Array {
  const fields = [protoField(1, 2, image.data)];
  if (image.dimension) {
    fields.push(
      protoField(
        2,
        2,
        protoMessage([protoField(1, 0, image.dimension.width), protoField(2, 0, image.dimension.height)])
      )
    );
  }
  fields.push(protoField(3, 2, image.uuid));
  return protoMessage(fields);
}

function decodeBase64(value: string): Uint8Array {
  const normalized = value.replace(/\s/g, "");
  try {
    const binary = atob(normalized);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    throw new HttpError("Image data URL contains invalid base64 data.", 400, "invalid_request_error", "image_url");
  }
}

function stableImageId(index: number): string {
  return typeof crypto.randomUUID === "function" ? crypto.randomUUID() : `image-${Date.now()}-${index}`;
}

function encodeConnectFrame(payload: Uint8Array): Uint8Array {
  const frame = new Uint8Array(5 + payload.length);
  frame[0] = 0;
  new DataView(frame.buffer).setUint32(1, payload.length, false);
  frame.set(payload, 5);
  return frame;
}

async function* parseConnectProtoFrames(stream: ReadableStream<Uint8Array> | null): AsyncGenerator<Uint8Array> {
  if (!stream) return;
  const reader = stream.getReader();
  let buffer = new Uint8Array(0);
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      if (value) buffer = concatBytes(buffer, value);
      for (;;) {
        if (buffer.length < 5) break;
        const flags = buffer[0];
        const length = new DataView(buffer.buffer, buffer.byteOffset + 1, 4).getUint32(0, false);
        if (buffer.length < 5 + length) break;
        const payload = buffer.slice(5, 5 + length);
        buffer = buffer.slice(5 + length);
        if ((flags & 1) === 1) {
          throw new HttpError("Cursor returned a compressed Connect frame that this Worker cannot decode.", 502, "cursor_stream_error");
        }
        if ((flags & 2) === 2) {
          handleEndStreamFrame(payload);
          continue;
        }
        yield payload;
      }
    }
  } finally {
    reader.releaseLock();
  }
}

function handleEndStreamFrame(payload: Uint8Array) {
  if (!payload.length) return;
  const text = decodeUtf8(payload).trim();
  if (!text || text === "{}") return;
  try {
    const parsed = JSON.parse(text) as unknown;
    if (isRecord(parsed) && isRecord(parsed.error)) {
      const message = cursorStreamErrorMessage(parsed.error) || "Cursor stream failed";
      throw new HttpError(message, 502, "cursor_stream_error");
    }
  } catch (error) {
    if (error instanceof HttpError) throw error;
  }
}

function decodeCursorChatFrame(payload: Uint8Array):
  | { type: "text"; text: string }
  | { type: "thinking"; text: string }
  | { type: "tool_call"; toolCall?: CursorToolCall }
  | { type: "ignore" }
  | { type: "error"; message: string } {
  try {
    for (const field of decodeProtobufFields(payload)) {
      if (field.no === 1) {
        return { type: "tool_call", ...(field.value instanceof Uint8Array ? decodeBinaryToolCall(field.value) : {}) };
      }
      if (field.no !== 2 || field.wt !== 2 || !(field.value instanceof Uint8Array)) continue;
      let text = "";
      let thinking = "";
      for (const inner of decodeProtobufFields(field.value)) {
        if (inner.no === 1 && inner.wt === 2 && inner.value instanceof Uint8Array) text += decodeUtf8(inner.value);
        if (inner.no === 25 && inner.wt === 2 && inner.value instanceof Uint8Array) {
          for (const thinkingField of decodeProtobufFields(inner.value)) {
            if (thinkingField.no === 1 && thinkingField.wt === 2 && thinkingField.value instanceof Uint8Array) {
              thinking += decodeUtf8(thinkingField.value);
            }
          }
        }
      }
      if (text) return { type: "text", text };
      if (thinking) return { type: "thinking", text: thinking };
    }
    return { type: "ignore" };
  } catch (error) {
    return { type: "error", message: error instanceof Error ? error.message : "Failed to decode Cursor stream" };
  }
}

function findComposerControlToken(value: string): { index: number; length: number } | null {
  let found: { index: number; length: number } | null = null;
  const pattern = new RegExp(COMPOSER_CONTROL_TOKEN_PATTERN);
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(value))) {
    found = { index: match.index, length: match[0].length };
  }
  return found;
}

function stripComposerControlTokens(value: string): string {
  const marker = findComposerControlToken(value);
  if (!marker) return value;
  return value
    .slice(marker.index + marker.length)
    .replace(COMPOSER_CONTROL_TOKEN_PATTERN, "")
    .replace(/^\s+/, "");
}

type ComposerToolMarkerEvent = { type: "text"; text: string } | { type: "tool_call"; toolCall: CursorToolCall };

const TOOL_CALLS_BEGIN = "<|tool_calls_begin|>";
const TOOL_CALLS_END = "<|tool_calls_end|>";
const TOOL_CALL_BEGIN = "<|tool_call_begin|>";
const TOOL_CALL_END = "<|tool_call_end|>";
const TOOL_SEP = "<|tool_sep|>";
const TOOL_MARKER_CANDIDATES = [TOOL_CALLS_BEGIN, TOOL_CALLS_END, TOOL_CALL_BEGIN, TOOL_CALL_END, TOOL_SEP].flatMap((marker) => [
  marker,
  marker.replaceAll("|", "｜").replaceAll("_", "▁")
]);

class ComposerToolCallFilter {
  private buffer = "";

  push(delta: string): ComposerToolMarkerEvent[] {
    this.buffer += delta;
    return this.drain(false);
  }

  flush(): ComposerToolMarkerEvent[] {
    return this.drain(true);
  }

  private drain(force: boolean): ComposerToolMarkerEvent[] {
    const events: ComposerToolMarkerEvent[] = [];
    for (;;) {
      const begin = findComposerToolMarker(this.buffer, "tool_calls_begin");
      if (!begin) {
        if (!this.buffer.trim()) {
          if (force) this.buffer = "";
          break;
        }
        const prefixIndex = force ? -1 : toolMarkerPrefixIndex(this.buffer);
        if (prefixIndex !== -1) {
          const visible = this.buffer.slice(0, prefixIndex);
          if (visible.trim()) events.push({ type: "text", text: visible });
          this.buffer = this.buffer.slice(prefixIndex);
          break;
        }
        const visible = this.buffer;
        if (visible) events.push({ type: "text", text: visible });
        this.buffer = "";
        break;
      }

      if (begin.index > 0) {
        const before = this.buffer.slice(0, begin.index);
        if (before.trim()) events.push({ type: "text", text: before });
        this.buffer = this.buffer.slice(begin.index);
        continue;
      }

      const end = findComposerToolMarker(this.buffer.slice(begin.length), "tool_calls_end");
      if (!end) {
        if (force) {
          events.push({ type: "text", text: this.buffer });
          this.buffer = "";
        }
        break;
      }

      const blockEnd = begin.length + end.index + end.length;
      const block = this.buffer.slice(0, blockEnd);
      for (const toolCall of parseComposerToolCalls(block)) {
        events.push({ type: "tool_call", toolCall });
      }
      this.buffer = this.buffer.slice(blockEnd).replace(/^\s+/, "");
    }
    return events;
  }
}

function parseComposerToolCalls(value: string): CursorToolCall[] {
  const normalized = canonicalizeComposerToolMarkers(value);
  const beginIndex = normalized.indexOf(TOOL_CALLS_BEGIN);
  const endIndex = normalized.lastIndexOf(TOOL_CALLS_END);
  if (beginIndex === -1 || endIndex === -1 || endIndex <= beginIndex) return [];

  const body = normalized.slice(beginIndex + TOOL_CALLS_BEGIN.length, endIndex);
  const calls: CursorToolCall[] = [];
  let offset = 0;
  for (;;) {
    const start = body.indexOf(TOOL_CALL_BEGIN, offset);
    if (start === -1) break;
    const contentStart = start + TOOL_CALL_BEGIN.length;
    const end = body.indexOf(TOOL_CALL_END, contentStart);
    if (end === -1) break;
    const call = parseComposerToolCallBody(body.slice(contentStart, end));
    if (call) calls.push(call);
    offset = end + TOOL_CALL_END.length;
  }
  return calls;
}

function parseComposerToolCallBody(value: string): CursorToolCall | null {
  const trimmedBody = value.trim();
  const jsonBody = parseJsonToolCallBody(trimmedBody);
  if (jsonBody) return jsonBody;

  const parts = value.split(TOOL_SEP);
  const name = (parts.shift() || "").trim();
  if (!name) return null;

  if (!parts.length) {
    const inline = parseInlineToolCall(name);
    return inline ?? { name, arguments: {} };
  }

  const args: Record<string, unknown> = {};
  for (const part of parts) {
    const trimmed = part.replace(/^\s+/, "");
    if (!trimmed) continue;
    const match = /^([^\r\n]+)(?:\r?\n([\s\S]*))?$/.exec(trimmed);
    if (!match) continue;
    const key = match[1].trim();
    if (!key) continue;
    const rawValue = (match[2] || "").trim();
    args[key] = parseComposerToolArgument(rawValue);
  }

  return { name, arguments: args };
}

function parseJsonToolCallBody(value: string): CursorToolCall | null {
  if (!value.startsWith("{") || !value.endsWith("}")) return null;
  try {
    const parsed = JSON.parse(value) as unknown;
    if (!isRecord(parsed)) return null;
    const fn = isRecord(parsed.function) ? parsed.function : undefined;
    const name = firstString(parsed.name, parsed.tool, parsed.tool_name, parsed.toolName, fn?.name);
    if (!name) return null;
    const rawArguments =
      parsed.arguments ??
      parsed.args ??
      parsed.input ??
      parsed.parameters ??
      parsed.params ??
      fn?.arguments;
    return { name, arguments: recordFromToolArguments(rawArguments) ?? {} };
  } catch {
    return null;
  }
}

function firstString(...values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return null;
}

function recordFromToolArguments(value: unknown): Record<string, unknown> | null {
  if (isRecord(value)) return value;
  if (typeof value !== "string" || !value.trim()) return null;
  try {
    const decoded = JSON.parse(value) as unknown;
    return isRecord(decoded) ? decoded : null;
  } catch {
    return null;
  }
}

function parseInlineToolCall(value: string): CursorToolCall | null {
  const match = /^([A-Za-z0-9_.-]+)\s*(?:\(([\s\S]*)\)|\[([\s\S]*)\])?$/.exec(value.trim());
  if (!match) return null;
  const name = match[1].trim();
  const rawArgs = (match[2] ?? match[3] ?? "").trim();
  const args = rawArgs ? parseInlineToolArguments(rawArgs) : {};
  return { name, arguments: args };
}

function parseInlineToolArguments(value: string): Record<string, unknown> {
  const args: Record<string, unknown> = {};
  for (const part of splitInlineArguments(value)) {
    const match = /^([A-Za-z0-9_.-]+)\s*[:=]\s*([\s\S]*)$/.exec(part.trim());
    if (!match) continue;
    args[match[1]] = parseComposerToolArgument(match[2].trim());
  }
  return args;
}

function splitInlineArguments(value: string): string[] {
  const parts: string[] = [];
  let start = 0;
  let quote: string | null = null;
  let depth = 0;
  for (let i = 0; i < value.length; i += 1) {
    const char = value[i];
    if (quote) {
      if (char === quote && value[i - 1] !== "\\") quote = null;
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      continue;
    }
    if (char === "{" || char === "[") depth += 1;
    if (char === "}" || char === "]") depth = Math.max(0, depth - 1);
    if (char === "," && depth === 0) {
      parts.push(value.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(value.slice(start));
  return parts;
}

function parseComposerToolArgument(value: string): unknown {
  if (!value) return "";
  if (value === "true") return true;
  if (value === "false") return false;
  if (value === "null") return null;
  if (/^-?\d+(?:\.\d+)?$/.test(value)) return Number(value);
  if ((value.startsWith("{") && value.endsWith("}")) || (value.startsWith("[") && value.endsWith("]"))) {
    try {
      return JSON.parse(value) as unknown;
    } catch {
      return value;
    }
  }
  return value;
}

function canonicalizeComposerToolMarkers(value: string): string {
  return value.replace(
    /<\s*[|｜]\s*(tool[_▁]calls[_▁]begin|tool[_▁]calls[_▁]end|tool[_▁]call[_▁]begin|tool[_▁]call[_▁]end|tool[_▁]sep)\s*[|｜]\s*>/g,
    (_match, marker: string) => `<|${marker.replaceAll("▁", "_")}|>`
  );
}

function findComposerToolMarker(value: string, marker: string): { index: number; length: number } | null {
  const markerPattern = marker.replaceAll("_", "[_▁]");
  const pattern = new RegExp(`<\\s*[|｜]\\s*${markerPattern}\\s*[|｜]\\s*>`);
  const match = pattern.exec(value);
  return match ? { index: match.index, length: match[0].length } : null;
}

function toolMarkerPrefixIndex(value: string): number {
  const max = Math.min(value.length, Math.max(...TOOL_MARKER_CANDIDATES.map((candidate) => candidate.length)));
  for (let length = max; length >= 1; length -= 1) {
    const index = value.length - length;
    const suffix = value.slice(index);
    if (TOOL_MARKER_CANDIDATES.some((candidate) => candidate.startsWith(suffix))) return index;
  }
  return -1;
}

function decodeBinaryToolCall(_payload: Uint8Array): { toolCall: CursorToolCall } | Record<string, never> {
  return {};
}

class ThinkingTextExtractor {
  private buffer = "";
  private open = true;

  push(delta: string): string[] {
    if (!this.open) return [delta];
    this.buffer += delta;
    const marker = this.findFinalMarker();
    if (!marker) return [];
    this.open = false;
    const after = this.buffer.slice(marker.index + marker.length).replace(/^\s+/, "");
    this.buffer = "";
    return after ? [after] : [];
  }

  flush(): string {
    if (!this.open) return "";
    const marker = this.findFinalMarker();
    if (marker) {
      const after = this.buffer.slice(marker.index + marker.length).replace(/^\s+/, "");
      this.buffer = "";
      return after;
    }
    this.buffer = "";
    return "";
  }

  private findFinalMarker(): { index: number; length: number } | null {
    return findComposerControlToken(this.buffer);
  }
}

class ComposerOutputFilter {
  private buffer = "";

  push(delta: string): string[] {
    this.buffer += delta;
    const marker = findComposerControlToken(this.buffer);
    if (marker) {
      const after = this.buffer.slice(marker.index + marker.length).replace(/^\s+/, "");
      this.buffer = "";
      return after ? [after] : [];
    }

    const keep = controlTokenPrefixLength(this.buffer);
    if (keep === this.buffer.length) return [];
    const visible = this.buffer.slice(0, this.buffer.length - keep);
    this.buffer = this.buffer.slice(this.buffer.length - keep);
    return visible ? [visible] : [];
  }

  flush(): string[] {
    const marker = findComposerControlToken(this.buffer);
    const visible = marker
      ? this.buffer.slice(marker.index + marker.length).replace(/^\s+/, "")
      : this.buffer;
    this.buffer = "";
    return visible ? [visible] : [];
  }
}

function controlTokenPrefixLength(value: string): number {
  const candidates = ["</think>", "<|final|>", "<｜final｜>", "< | final | >"];
  let keep = 0;
  const max = Math.min(value.length, Math.max(...candidates.map((candidate) => candidate.length)));
  for (let length = 1; length <= max; length += 1) {
    const suffix = value.slice(value.length - length);
    if (candidates.some((candidate) => candidate.startsWith(suffix))) keep = length;
  }
  return keep;
}

function protoMessage(parts: Uint8Array[]): Uint8Array {
  return concatBytes(...parts);
}

function protoField(fieldNumber: number, wireType: 0 | 2, value: string | number | Uint8Array): Uint8Array {
  const tag = encodeVarint((fieldNumber << 3) | wireType);
  if (wireType === 0) return concatBytes(tag, encodeVarint(value as number));
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value instanceof Uint8Array ? value : encodeVarint(value);
  return concatBytes(tag, encodeVarint(bytes.length), bytes);
}

function encodeVarint(value: number): Uint8Array {
  const bytes: number[] = [];
  let current = value >>> 0;
  while (current >= 0x80) {
    bytes.push((current & 0x7f) | 0x80);
    current >>>= 7;
  }
  bytes.push(current);
  return new Uint8Array(bytes);
}

function decodeProtobufFields(bytes: Uint8Array): ProtobufField[] {
  const fields: ProtobufField[] = [];
  let offset = 0;
  while (offset < bytes.length) {
    const tag = readVarint(bytes, offset);
    offset = tag.offset;
    const no = tag.value >> 3;
    const wt = tag.value & 7;
    if (wt === 0) {
      const value = readVarint(bytes, offset);
      offset = value.offset;
      fields.push({ no, wt, value: value.value });
    } else if (wt === 2) {
      const length = readVarint(bytes, offset);
      offset = length.offset;
      fields.push({ no, wt, value: bytes.slice(offset, offset + length.value) });
      offset += length.value;
    } else if (wt === 1) {
      offset += 8;
    } else if (wt === 5) {
      offset += 4;
    } else {
      throw new Error(`Unsupported protobuf wire type ${wt}`);
    }
  }
  return fields;
}

function readVarint(bytes: Uint8Array, offset: number): { value: number; offset: number } {
  let value = 0;
  let shift = 0;
  while (offset < bytes.length) {
    const byte = bytes[offset++];
    value += (byte & 0x7f) * 2 ** shift;
    if ((byte & 0x80) === 0) return { value, offset };
    shift += 7;
  }
  throw new Error("Unexpected end of protobuf varint");
}

function concatBytes(...parts: Uint8Array<ArrayBufferLike>[]): Uint8Array<ArrayBuffer> {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const output = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.length;
  }
  return output;
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(bytes)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function cursorChecksum(env: Env, cursorIdentity: string): Promise<string> {
  const machineId = await sha256Hex(`${env.ENCRYPTION_KEY || "composer-api"}:cursor-machine:${cursorIdentity}`);
  const timestamp = BigInt(Math.floor(Date.now() / 1_000_000));
  const bytes = new Uint8Array([
    Number((timestamp >> 40n) & 255n),
    Number((timestamp >> 32n) & 255n),
    Number((timestamp >> 24n) & 255n),
    Number((timestamp >> 16n) & 255n),
    Number((timestamp >> 8n) & 255n),
    Number(timestamp & 255n)
  ]);
  let t = 165;
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = ((bytes[i] ^ t) + (i % 256)) & 255;
    t = bytes[i];
  }
  return `${base64Url(bytes)}${machineId}`;
}

async function stableUuid(namespace: string, value: string): Promise<string> {
  const hash = (await sha256Hex(`${namespace}:${value}`)).slice(0, 32);
  return `${hash.slice(0, 8)}-${hash.slice(8, 12)}-${hash.slice(12, 16)}-${hash.slice(16, 20)}-${hash.slice(20)}`;
}

async function sessionId(token: string): Promise<string> {
  const hash = (await sha256Hex(token)).slice(0, 32);
  return `${hash.slice(0, 8)}-${hash.slice(8, 12)}-${hash.slice(12, 16)}-${hash.slice(16, 20)}-${hash.slice(20)}`;
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function decodeUtf8(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

function cursorStreamErrorMessage(error: unknown): string | undefined {
  if (!isRecord(error)) return undefined;
  const titleAndDetail = detailFromCursorError(error);
  if (titleAndDetail) return titleAndDetail;
  return typeof error.message === "string" ? error.message : undefined;
}

function detailFromCursorError(error: Record<string, unknown>): string | undefined {
  const details = Array.isArray(error.details) ? error.details : [];
  for (const detail of details) {
    if (!isRecord(detail) || !isRecord(detail.debug)) continue;
    const debugDetails = isRecord(detail.debug.details) ? detail.debug.details : undefined;
    const title = typeof debugDetails?.title === "string" ? debugDetails.title : "";
    const body = typeof debugDetails?.detail === "string" ? debugDetails.detail : "";
    const message = [title, body].filter(Boolean).join(" ");
    if (message) return message;
  }
  return undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
