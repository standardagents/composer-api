import { sha256Hex } from "./crypto";
import { exchangeCursorApiKey } from "./cursor";
import { HttpError } from "./http";
import type { CursorCollectedOutput, CursorTextEvent } from "./cursor";
import type { CursorImage, CursorToolCall, Deps, Env } from "./types";

interface CursorSdkSession {
  agentId: string;
  updatedAt: number;
}

interface CursorSdkCompletion {
  agentId: string;
  runId: string;
  stream: AsyncGenerator<CursorTextEvent>;
}

interface ProtobufField {
  no: number;
  wt: number;
  value: number | Uint8Array;
}

type LocalSdkDecodedEvent =
  | { type: "text"; text: string }
  | { type: "tool_call"; id: string; toolCall: CursorToolCall }
  | { type: "request_context"; id: number; execId?: string }
  | { type: "done" }
  | { type: "ignore" };

type ArgsKind =
  | "delete"
  | "edit"
  | "glob"
  | "grep"
  | "ls"
  | "mcp"
  | "readExec"
  | "readLints"
  | "readTool"
  | "semSearch"
  | "shell"
  | "write";

interface ToolSpec {
  name: string;
  argsKind: ArgsKind;
}

const sdkSessions = new Map<string, CursorSdkSession>();
const SDK_SESSION_TTL_MS = 6 * 60 * 60 * 1000;
const AGENT_MODE_AGENT = 1;
const DEFAULT_SDK_CLIENT_VERSION = "sdk-1.0.13";
const SDK_STREAM_START_TIMEOUT_MS = 25_000;

const TOOL_CALL_SPECS: Record<number, ToolSpec> = {
  1: { name: "shell", argsKind: "shell" },
  3: { name: "delete", argsKind: "delete" },
  4: { name: "glob", argsKind: "glob" },
  5: { name: "grep", argsKind: "grep" },
  8: { name: "read", argsKind: "readTool" },
  12: { name: "edit", argsKind: "edit" },
  13: { name: "ls", argsKind: "ls" },
  14: { name: "readLints", argsKind: "readLints" },
  15: { name: "mcp", argsKind: "mcp" },
  16: { name: "semSearch", argsKind: "semSearch" }
};

const EXEC_TOOL_SPECS: Record<number, ToolSpec> = {
  2: { name: "shell", argsKind: "shell" },
  3: { name: "write", argsKind: "write" },
  4: { name: "delete", argsKind: "delete" },
  5: { name: "grep", argsKind: "grep" },
  7: { name: "read", argsKind: "readExec" },
  8: { name: "ls", argsKind: "ls" },
  9: { name: "readLints", argsKind: "readLints" },
  11: { name: "mcp", argsKind: "mcp" },
  14: { name: "shell", argsKind: "shell" }
};

export async function createCursorSdkCompletion(
  env: Env,
  deps: Deps,
  apiKey: string,
  input: {
    prompt: { text: string; images?: CursorImage[] };
    model?: { id: string };
    sessionKey?: string;
    sessionOwnerKey?: string;
    workingDirectory?: string;
    requiresLocalTool?: boolean;
    allowToolCall?: (toolCall: CursorToolCall) => boolean;
  }
): Promise<CursorSdkCompletion> {
  const accessToken = await exchangeCursorApiKey(env, deps, apiKey);
  const now = deps.now();
  pruneSessions(now.getTime());
  const sessionIdentity = await sdkSessionIdentity(apiKey, input.sessionKey || "default", input.sessionOwnerKey);
  const session = sdkSessions.get(sessionIdentity.id) ?? (await readPersistedSdkSession(env, sessionIdentity.id, now.getTime()));
  const agentId = session?.agentId || newLocalSdkAgentId(deps.randomUUID());
  const runId = newLocalSdkRunId(deps.randomUUID());
  const updatedAt = deps.now();

  sdkSessions.set(sessionIdentity.id, { agentId, updatedAt: updatedAt.getTime() });
  await savePersistedSdkSession(env, sessionIdentity, agentId, updatedAt);

  return {
    agentId,
    runId,
    stream: streamCursorLocalSdkRunWithRetry(env, deps, accessToken, {
      agentId,
      runId,
      prompt: sdkPrompt(input.prompt),
      modelId: input.model?.id || "composer-2.5",
      workingDirectory: input.workingDirectory,
      requiresLocalTool: input.requiresLocalTool === true,
      allowToolCall: input.allowToolCall
    })
  };
}

export async function collectCursorSdkOutput(stream: AsyncIterable<CursorTextEvent>): Promise<CursorCollectedOutput> {
  let text = "";
  let toolCalls: CursorToolCall[] = [];
  for await (const event of stream) {
    if (event.type === "text" && event.text) text += event.text;
    if (event.type === "tool_call") toolCalls.push(event.toolCall);
    if (event.type === "done") {
      text = event.finalText;
      toolCalls = event.toolCalls;
    }
  }
  return { text, toolCalls };
}

export function resetCursorSdkSessionCacheForTest() {
  sdkSessions.clear();
}

export const cursorSdkTestExports = {
  decodeLocalAgentServerFrame,
  encodeAgentClientRequestContextResult,
  encodeAgentClientRunRequest,
  isEmittableSdkToolCall,
  normalizeSdkToolCallForOpenCode,
  retryPromptAfterMissingTool,
  retryPromptAfterUnsupportedTool
};

async function* streamCursorLocalSdkRun(
  env: Env,
  deps: Deps,
  accessToken: string,
  input: {
    agentId: string;
    runId: string;
    prompt: string;
    modelId: string;
    workingDirectory?: string;
    allowToolCall?: (toolCall: CursorToolCall) => boolean;
  }
): AsyncGenerator<CursorTextEvent> {
  let text = "";
  const toolCalls: CursorToolCall[] = [];
  const emittedToolCallIds = new Set<string>();
  const requestId = deps.randomUUID();
  const requestBody = encodeConnectFrame(
    encodeAgentClientRunRequest({
      agentId: input.agentId,
      messageId: input.runId,
      modelId: input.modelId,
      prompt: input.prompt
    })
  );
  const runAbort = new AbortController();
  const bridgeBinding = env.CURSOR_SDK_BRIDGE_CONTAINER;
  const bridgeUrl = env.CURSOR_SDK_BRIDGE_URL?.trim();
  const useBridge = Boolean(bridgeBinding || bridgeUrl);
  const upload = useBridge ? undefined : new TransformStream<Uint8Array, Uint8Array>();
  const uploadWriter = upload?.writable.getWriter();
  const runResponsePromise = (
    bridgeBinding
      ? cursorLocalSdkContainerBridgeRaw(env, bridgeBinding, accessToken, requestId, requestBody, input.workingDirectory, runAbort.signal)
      : bridgeUrl
        ? cursorLocalSdkUrlBridgeRaw(env, deps, bridgeUrl, accessToken, requestId, requestBody, input.workingDirectory, runAbort.signal)
        : cursorLocalSdkRaw(env, deps, cursorLocalSdkEndpoint(env), accessToken, requestId, upload!.readable, runAbort.signal)
  ).then((response) => ({
    source: "run" as const,
    response
  }));
  let uploadOpen = false;
  if (uploadWriter) {
    await writeSdkUpload(uploadWriter, requestBody);
    uploadOpen = true;
  }

  const selected = await withSdkStartTimeout(runResponsePromise);
  const response = selected.response;

  try {
    for await (const frame of parseConnectProtoFrames(response.body)) {
      for (const event of decodeLocalAgentServerFrame(frame)) {
        if (event.type === "text" && event.text) {
          text += event.text;
          yield { type: "text", text: event.text };
        } else if (event.type === "tool_call") {
          if (!isEmittableSdkToolCall(event.toolCall)) {
            continue;
          }
          if (input.allowToolCall && !input.allowToolCall(event.toolCall)) {
            yield { type: "rejected_tool_call", toolCall: event.toolCall };
            yield { type: "done", finalText: text, toolCalls };
            return;
          }
          if (!emittedToolCallIds.has(event.id)) {
            emittedToolCallIds.add(event.id);
            toolCalls.push(event.toolCall);
            yield { type: "tool_call", toolCall: event.toolCall };
            yield { type: "done", finalText: text, toolCalls };
            return;
          }
        } else if (event.type === "request_context") {
          if (uploadOpen && uploadWriter) {
            await writeSdkUpload(uploadWriter, encodeConnectFrame(encodeAgentClientRequestContextResult(event, { workingDirectory: input.workingDirectory })));
          }
        } else if (event.type === "done") {
          yield { type: "done", finalText: text, toolCalls };
          return;
        }
      }
    }
  } finally {
    if (uploadOpen && uploadWriter) await closeSdkUpload(uploadWriter);
    runAbort.abort("opencode_sdk_run_finished");
  }

  yield { type: "done", finalText: text, toolCalls };
}

async function* streamCursorLocalSdkRunWithRetry(
  env: Env,
  deps: Deps,
  accessToken: string,
  input: {
    agentId: string;
    runId: string;
    prompt: string;
    modelId: string;
    workingDirectory?: string;
    requiresLocalTool: boolean;
    allowToolCall?: (toolCall: CursorToolCall) => boolean;
  }
): AsyncGenerator<CursorTextEvent> {
  if (!input.requiresLocalTool) {
    yield* streamCursorLocalSdkRun(env, deps, accessToken, input);
    return;
  }

  const firstEvents: CursorTextEvent[] = [];
  let sawToolCall = false;
  let rejectedToolCall: CursorToolCall | undefined;
  for await (const event of streamCursorLocalSdkRun(env, deps, accessToken, input)) {
    firstEvents.push(event);
    if (event.type === "tool_call") sawToolCall = true;
    if (event.type === "rejected_tool_call") rejectedToolCall = event.toolCall;
  }
  if (sawToolCall) {
    for (const event of firstEvents) yield event;
    return;
  }

  yield* streamCursorLocalSdkRun(env, deps, accessToken, {
    ...input,
    runId: newLocalSdkRunId(deps.randomUUID()),
    prompt: rejectedToolCall
      ? retryPromptAfterUnsupportedTool(input.prompt, rejectedToolCall)
      : retryPromptAfterMissingTool(input.prompt)
  });
}

function retryPromptAfterMissingTool(prompt: string): string {
  return [
    prompt,
    "",
    "TOOL CALL RETRY:",
    "Your previous SDK response did not emit a local tool call, but the latest user request requires local OpenCode execution.",
    "Do not answer in prose. Emit exactly one SDK tool call now using the allowed OpenCode tool inventory above, then wait for the local tool result.",
    "If a specific client tool was named in the request, use that exact tool mapping and do not substitute shell, glob, or prose."
  ].join("\n");
}

function retryPromptAfterUnsupportedTool(prompt: string, toolCall: CursorToolCall): string {
  return [
    prompt,
    "",
    "TOOL CALL RETRY:",
    `Your previous SDK response requested ${toolCall.name}, but that tool could not be mapped to the allowed OpenCode tool inventory above.`,
    "Do not answer in prose. Emit exactly one SDK tool call that maps to an allowed client tool.",
    "For filesystem mutations, prefer SDK write with path and fileText or SDK shell with command when those capabilities are present.",
    "For OpenCode MCP/server tools exposed as provider_tool names, use SDK mcp with providerIdentifier, toolName, and args."
  ].join("\n");
}

async function cursorLocalSdkRaw(
  env: Env,
  deps: Deps,
  endpoint: string,
  accessToken: string,
  requestId: string,
  body: BodyInit,
  signal?: AbortSignal
): Promise<Response> {
  const base = env.CURSOR_BACKEND_BASE_URL?.trim();
  if (!base) throw new HttpError("Cursor backend URL is not configured", 500, "cursor_missing_backend_url");
  const url = /^https?:\/\//.test(endpoint) ? endpoint : `${base.replace(/\/$/, "")}${endpoint.startsWith("/") ? endpoint : `/${endpoint}`}`;
  const headers = new Headers({
    Authorization: `Bearer ${accessToken}`,
    "Connect-Protocol-Version": "1",
    "Content-Type": "application/connect+proto",
    "User-Agent": "connect-es/1.6.1",
    "x-cursor-client-type": "sdk",
    "x-cursor-client-version": env.CURSOR_SDK_CLIENT_VERSION || DEFAULT_SDK_CLIENT_VERSION,
    "x-ghost-mode": "true",
    "x-original-request-id": requestId,
    "x-request-id": requestId
  });
  const init: RequestInit & { duplex?: "half" } = { method: "POST", headers, body, signal };
  if (body instanceof ReadableStream) init.duplex = "half";
  const response = await deps.fetch(url, init);
  if (!response.ok) {
    const text = await response.text().catch(() => "");
    const parsed = parseCursorSdkError(text);
    const message = response.status === 401 ? "Invalid Cursor API key" : parsed.message || `Cursor local SDK request failed with status ${response.status}`;
    const status = response.status === 401 ? 401 : response.status === 429 ? 429 : response.status >= 500 ? 502 : 400;
    throw new HttpError(message, status, response.status === 401 ? "cursor_unauthorized" : parsed.code || "cursor_sdk_error");
  }
  return response;
}

async function cursorLocalSdkUrlBridgeRaw(
  env: Env,
  deps: Deps,
  bridgeUrl: string,
  accessToken: string,
  requestId: string,
  runFrame: Uint8Array,
  workingDirectory?: string,
  signal?: AbortSignal
): Promise<Response> {
  const response = await deps.fetch(bridgeUrl, {
    method: "POST",
    headers: cursorLocalSdkBridgeHeaders(env),
    signal,
    body: JSON.stringify(cursorLocalSdkBridgePayload(env, accessToken, requestId, runFrame, workingDirectory))
  });
  return assertCursorLocalSdkBridgeResponse(response);
}

async function cursorLocalSdkContainerBridgeRaw(
  env: Env,
  bridgeBinding: DurableObjectNamespace,
  accessToken: string,
  requestId: string,
  runFrame: Uint8Array,
  workingDirectory?: string,
  signal?: AbortSignal
): Promise<Response> {
  const bridgeId = bridgeBinding.idFromName("shared");
  const bridge = bridgeBinding.get(bridgeId);
  const response = await bridge.fetch("http://cursor-sdk-bridge.local/sdk", {
    method: "POST",
    headers: cursorLocalSdkBridgeHeaders(env),
    signal,
    body: JSON.stringify(cursorLocalSdkBridgePayload(env, accessToken, requestId, runFrame, workingDirectory))
  });
  return assertCursorLocalSdkBridgeResponse(response);
}

function cursorLocalSdkBridgeHeaders(env: Env): Headers {
  const headers = new Headers({
    "Content-Type": "application/json"
  });
  if (env.CURSOR_SDK_BRIDGE_TOKEN?.trim()) {
    headers.set("Authorization", `Bearer ${env.CURSOR_SDK_BRIDGE_TOKEN.trim()}`);
  }
  return headers;
}

function cursorLocalSdkBridgePayload(
  env: Env,
  accessToken: string,
  requestId: string,
  runFrame: Uint8Array,
  workingDirectory?: string
): Record<string, string> {
  const backendBaseUrl = env.CURSOR_BACKEND_BASE_URL?.trim();
  if (!backendBaseUrl) throw new HttpError("Cursor backend URL is not configured", 500, "cursor_missing_backend_url");
  const sdkCwd = sdkWorkingDirectory(workingDirectory);
  return {
    accessToken,
    requestId,
    backendBaseUrl,
    localAgentEndpoint: cursorLocalSdkEndpoint(env),
    clientVersion: env.CURSOR_SDK_CLIENT_VERSION || DEFAULT_SDK_CLIENT_VERSION,
    runFrame: bytesToBase64(runFrame),
    ...(sdkCwd !== "." ? { workingDirectory: sdkCwd } : {})
  };
}

async function assertCursorLocalSdkBridgeResponse(response: Response): Promise<Response> {
  if (!response.ok) {
    const text = await response.text().catch(() => "");
    const parsed = parseCursorSdkError(text);
    const message = response.status === 401 ? "Cursor SDK bridge rejected the request" : parsed.message || `Cursor SDK bridge failed with status ${response.status}`;
    const status = response.status === 401 ? 502 : response.status === 429 ? 429 : response.status >= 500 ? 502 : 400;
    throw new HttpError(message, status, parsed.code || "cursor_sdk_bridge_error");
  }
  return response;
}

async function writeSdkUpload(writer: WritableStreamDefaultWriter<Uint8Array>, frame: Uint8Array): Promise<void> {
  await writer.write(frame).catch((error) => {
    throw error instanceof Error ? error : new Error(String(error));
  });
}

async function closeSdkUpload(writer: WritableStreamDefaultWriter<Uint8Array>): Promise<void> {
  await writer.close().catch(() => undefined);
  writer.releaseLock();
}

function withSdkStartTimeout<T>(promise: Promise<T>): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new HttpError("Cursor local SDK stream did not start.", 504, "cursor_sdk_stream_timeout"));
    }, SDK_STREAM_START_TIMEOUT_MS);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      }
    );
  });
}

function cursorLocalSdkEndpoint(env: Env): string {
  const endpoint = env.CURSOR_LOCAL_AGENT_ENDPOINT?.trim();
  if (!endpoint) throw new HttpError("Cursor local SDK endpoint is not configured", 500, "cursor_missing_endpoint");
  return endpoint;
}

function encodeAgentClientRunRequest(input: { agentId: string; messageId: string; modelId: string; prompt: string }): Uint8Array {
  const userMessage = protoMessage([
    protoStringField(1, input.prompt),
    protoStringField(2, input.messageId),
    protoVarintField(4, AGENT_MODE_AGENT)
  ]);
  const userMessageAction = protoMessage([protoMessageField(1, userMessage)]);
  const conversationAction = protoMessage([protoMessageField(1, userMessageAction)]);
  const modelDetails = protoMessage([
    protoStringField(1, input.modelId),
    protoStringField(3, input.modelId),
    protoStringField(4, input.modelId)
  ]);
  const requestedModel = protoMessage([protoStringField(1, input.modelId)]);
  const runRequest = protoMessage([
    protoMessageField(1, protoMessage([])),
    protoMessageField(2, conversationAction),
    protoMessageField(3, modelDetails),
    protoMessageField(4, protoMessage([])),
    protoStringField(5, input.agentId),
    protoStringField(13, "sdk"),
    protoMessageField(9, requestedModel),
    protoVarintField(19, 1)
  ]);
  return protoMessage([protoMessageField(1, runRequest)]);
}

function encodeAgentClientRequestContextResult(input: { id: number; execId?: string }, options: { workingDirectory?: string } = {}): Uint8Array {
  const workingDirectory = sdkWorkingDirectory(options.workingDirectory);
  const env = protoMessage([
    protoStringField(1, "Cloudflare Worker"),
    protoStringField(2, workingDirectory),
    protoStringField(3, "sh"),
    protoVarintField(5, false),
    protoStringField(10, "UTC"),
    protoStringField(11, workingDirectory),
    protoStringField(21, workingDirectory)
  ]);
  const requestContext = protoMessage([
    protoMessageField(4, env),
    protoVarintField(17, false),
    protoVarintField(24, false),
    protoVarintField(32, true),
    protoVarintField(33, true),
    protoVarintField(35, false),
    protoVarintField(36, true),
    protoVarintField(39, true),
    protoVarintField(40, true),
    protoVarintField(41, true),
    protoVarintField(42, true),
    protoVarintField(43, true),
    protoVarintField(44, true),
    protoVarintField(45, true)
  ]);
  const success = protoMessage([protoMessageField(1, requestContext)]);
  const result = protoMessage([protoMessageField(1, success)]);
  const execClientMessage = protoMessage([
    protoVarintField(1, input.id),
    protoStringField(15, input.execId),
    protoMessageField(10, result)
  ]);
  return protoMessage([protoMessageField(2, execClientMessage)]);
}

function sdkWorkingDirectory(value: string | undefined): string {
  const trimmed = value?.trim();
  if (!trimmed || trimmed.toLowerCase() === "undefined" || trimmed.toLowerCase() === "null") return ".";
  return trimmed;
}

function decodeLocalAgentServerFrame(payload: Uint8Array): LocalSdkDecodedEvent[] {
  const output: LocalSdkDecodedEvent[] = [];
  try {
    for (const field of decodeProtobufFields(payload)) {
      if (field.no === 1 && field.value instanceof Uint8Array) {
        output.push(...decodeInteractionUpdate(field.value));
      } else if (field.no === 2 && field.value instanceof Uint8Array) {
        const event = decodeExecServerMessage(field.value);
        if (event) output.push(event);
      }
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "Could not decode Cursor local SDK stream";
    throw new HttpError(message, 502, "cursor_stream_error");
  }
  return output.length ? output : [{ type: "ignore" }];
}

function decodeExecServerMessage(payload: Uint8Array): LocalSdkDecodedEvent | null {
  const fields = decodeProtobufFields(payload);
  if (fields.some((field) => field.no === 10 && field.value instanceof Uint8Array)) {
    return {
      type: "request_context",
      id: numberField(fields, 1) || 0,
      execId: stringField(fields, 15)
    };
  }
  return decodeExecServerToolCall(payload, fields);
}

function decodeInteractionUpdate(payload: Uint8Array): LocalSdkDecodedEvent[] {
  const output: LocalSdkDecodedEvent[] = [];
  for (const field of decodeProtobufFields(payload)) {
    if (!(field.value instanceof Uint8Array)) continue;
    if (field.no === 1) {
      const text = stringField(decodeProtobufFields(field.value), 1);
      if (text) output.push({ type: "text", text });
    } else if (field.no === 2 || field.no === 3 || field.no === 7) {
      const event = decodeToolCallUpdate(field.value, field.no === 3);
      if (event) output.push(event);
    } else if (field.no === 14) {
      output.push({ type: "done" });
    }
  }
  return output;
}

function decodeToolCallUpdate(payload: Uint8Array, completed: boolean): LocalSdkDecodedEvent | null {
  const fields = decodeProtobufFields(payload);
  const callId = stringField(fields, 1) || stableToolCallId(payload);
  const toolCallBytes = bytesField(fields, 2);
  if (!toolCallBytes) return null;
  const decoded = decodeSdkToolCall(toolCallBytes);
  if (!decoded || (completed && decoded.hasResult)) return null;
  return { type: "tool_call", id: callId, toolCall: normalizeSdkToolCallForOpenCode(decoded.toolCall) };
}

function decodeSdkToolCall(payload: Uint8Array): { toolCall: CursorToolCall; hasResult: boolean } | null {
  for (const field of decodeProtobufFields(payload)) {
    if (!(field.value instanceof Uint8Array)) continue;
    const spec = TOOL_CALL_SPECS[field.no];
    if (!spec) continue;
    const toolFields = decodeProtobufFields(field.value);
    const args = bytesField(toolFields, 1);
    const hasResult = toolFields.some((item) => item.no === 2);
    return {
      hasResult,
      toolCall: {
        name: spec.name,
        arguments: args ? decodeToolArgs(spec.argsKind, args) : {}
      }
    };
  }
  return null;
}

function decodeExecServerToolCall(payload: Uint8Array, fields = decodeProtobufFields(payload)): LocalSdkDecodedEvent | null {
  const id = numberField(fields, 1);
  const execId = stringField(fields, 15);
  for (const field of fields) {
    if (!(field.value instanceof Uint8Array)) continue;
    const spec = EXEC_TOOL_SPECS[field.no];
    if (!spec) continue;
    const args = decodeToolArgs(spec.argsKind, field.value);
    const toolCallId = stringArg(args, "toolCallId") || execId || `exec_${id ?? stableToolCallId(payload)}`;
    delete args.toolCallId;
    return {
      type: "tool_call",
      id: toolCallId,
      toolCall: normalizeSdkToolCallForOpenCode({ name: spec.name, arguments: args })
    };
  }
  return null;
}

function normalizeSdkToolCallForOpenCode(toolCall: CursorToolCall): CursorToolCall {
  if (toolCall.name.toLowerCase() !== "edit") return toolCall;
  const path = stringArg(toolCall.arguments, "path");
  const streamContent = stringArgAllowEmpty(toolCall.arguments, "streamContent", "stream_content");
  if (!path || streamContent === undefined) return toolCall;
  return {
    name: "write",
    arguments: {
      path,
      fileText: streamContent
    }
  };
}

function decodeToolArgs(kind: ArgsKind, payload: Uint8Array): Record<string, unknown> {
  const fields = decodeProtobufFields(payload);
  switch (kind) {
    case "shell":
      return compactRecord({
        command: stringField(fields, 1),
        workingDirectory: stringField(fields, 2),
        timeout: numberField(fields, 3),
        toolCallId: stringField(fields, 4)
      });
    case "write":
      return compactRecord({
        path: stringField(fields, 1),
        fileText: stringField(fields, 2),
        toolCallId: stringField(fields, 3),
        returnFileContentAfterWrite: booleanField(fields, 4)
      });
    case "delete":
      return compactRecord({ path: stringField(fields, 1), toolCallId: stringField(fields, 2) });
    case "glob":
      return compactRecord({ targetDirectory: stringField(fields, 1), globPattern: stringField(fields, 2) });
    case "grep":
      return compactRecord({
        pattern: stringField(fields, 1),
        path: stringField(fields, 2),
        glob: stringField(fields, 3),
        outputMode: stringField(fields, 4),
        contextBefore: numberField(fields, 5),
        contextAfter: numberField(fields, 6),
        context: numberField(fields, 7),
        caseInsensitive: booleanField(fields, 8),
        type: stringField(fields, 9),
        headLimit: numberField(fields, 10),
        multiline: booleanField(fields, 11),
        sort: stringField(fields, 12),
        sortAscending: booleanField(fields, 13),
        toolCallId: stringField(fields, 14),
        offset: numberField(fields, 16)
      });
    case "readTool":
      return compactRecord({
        path: stringField(fields, 1),
        offset: numberField(fields, 2),
        limit: numberField(fields, 3),
        includeLineNumbers: booleanField(fields, 5)
      });
    case "readExec":
      return compactRecord({
        path: stringField(fields, 1),
        toolCallId: stringField(fields, 2),
        offset: numberField(fields, 4),
        limit: numberField(fields, 5)
      });
    case "edit":
      return compactRecord({ path: stringField(fields, 1), streamContent: stringField(fields, 6) });
    case "ls":
      return compactRecord({ path: stringField(fields, 1), ignore: stringFields(fields, 2), toolCallId: stringField(fields, 3) });
    case "readLints":
      return compactRecord({ paths: stringFields(fields, 1) });
    case "mcp":
      return compactRecord({
        name: stringField(fields, 1),
        args: protoValueMap(fields, 2),
        toolCallId: stringField(fields, 3),
        providerIdentifier: stringField(fields, 4),
        toolName: stringField(fields, 5)
      });
    case "semSearch":
      return compactRecord({
        query: stringField(fields, 1),
        targetDirectories: stringFields(fields, 2),
        explanation: stringField(fields, 3)
      });
  }
}

function isEmittableSdkToolCall(toolCall: CursorToolCall): boolean {
  const name = toolCall.name.toLowerCase();
  const args = toolCall.arguments ?? {};
  if (name === "glob") return hasGlobRequest(args);
  if (name === "ls") return true;
  if (name === "shell") return hasAnyStringArg(args, "command", "cmd", "script");
  if (name === "write") {
    return hasAnyStringArg(args, "path", "filePath", "file_path", "targetFile", "target_file") &&
      hasAnyStringArgAllowEmpty(args, "fileText", "file_text", "content", "contents", "text", "fileContent", "file_content", "streamContent", "stream_content");
  }
  if (name === "edit") {
    const hasCompleteReplacement =
      hasAnyStringArgAllowEmpty(args, "oldText", "old_text", "oldString", "old_string", "old_str", "old", "search", "searchString", "search_string") &&
      hasAnyStringArgAllowEmpty(args, "newText", "new_text", "newString", "new_string", "new_str", "replacement", "replace", "content");
    return (
      hasAnyStringArg(args, "path", "filePath", "file_path", "targetFile", "target_file") &&
      (hasAnyStringArgAllowEmpty(args, "patchContent", "patch_content", "patch", "diff", "unifiedDiff", "unified_diff") ||
        hasAnyStringArgAllowEmpty(args, "streamContent", "stream_content") ||
        hasCompleteReplacement)
    );
  }
  if (name === "read" || name === "delete") return hasAnyStringArg(args, "path", "filePath", "file_path", "targetFile", "target_file");
  if (name === "grep") return hasAnyStringArg(args, "pattern", "query", "regex", "search");
  if (name === "semSearch") return hasAnyStringArg(args, "query", "pattern", "search");
  if (name === "readLints") return Array.isArray(args.paths) && args.paths.some((item) => typeof item === "string" && item.trim());
  if (name === "mcp") return hasAnyStringArg(args, "toolName", "tool_name", "name");
  return Object.keys(args).length > 0;
}

function hasStringArg(args: Record<string, unknown>, key: string): boolean {
  return typeof args[key] === "string" && args[key].trim().length > 0;
}

function hasAnyStringArg(args: Record<string, unknown>, ...keys: string[]): boolean {
  return keys.some((key) => hasStringArg(args, key));
}

function hasAnyStringArgAllowEmpty(args: Record<string, unknown>, ...keys: string[]): boolean {
  return keys.some((key) => typeof args[key] === "string");
}

function hasGlobRequest(args: Record<string, unknown>): boolean {
  if (hasAnyStringArg(args, "globPattern", "glob_pattern", "filePattern", "file_pattern", "pattern", "glob", "query", "include", "includeGlob", "include_glob")) {
    return true;
  }
  const target = stringArg(args, "targetDirectory") || stringArg(args, "target_directory") || stringArg(args, "targeting") || stringArg(args, "path");
  return target !== undefined;
}

function stringArgAllowEmpty(args: Record<string, unknown>, ...keys: string[]): string | undefined {
  for (const key of keys) {
    const value = args[key];
    if (typeof value === "string") return value;
  }
  return undefined;
}

function sdkPrompt(prompt: { text: string; images?: CursorImage[] }): string {
  if (!prompt.images?.length) return prompt.text;
  return `${prompt.text}\n\n[${prompt.images.length} image input${prompt.images.length === 1 ? "" : "s"} attached by the OpenAI-compatible client.]`;
}

function parseCursorSdkError(text: string): { message?: string; code?: string } {
  try {
    const payload = JSON.parse(text) as unknown;
    if (isRecord(payload)) {
      const error = isRecord(payload.error) ? payload.error : payload;
      return {
        message: typeof error.message === "string" ? error.message : undefined,
        code: typeof error.code === "string" ? error.code : undefined
      };
    }
  } catch {
    // Ignore JSON parse failures.
  }
  return { message: text || undefined };
}

async function sdkSessionIdentity(
  apiKey: string,
  sessionKey: string,
  sessionOwnerKey?: string
): Promise<{ id: string; ownerHash: string; sessionHash: string }> {
  const ownerHash = await sha256Hex(sessionOwnerKey || `cursor-key:${await sha256Hex(apiKey)}`);
  const sessionHash = await sha256Hex(sessionKey);
  return {
    id: await sha256Hex(`${ownerHash}\n${sessionHash}`),
    ownerHash,
    sessionHash
  };
}

function pruneSessions(now: number) {
  for (const [key, session] of sdkSessions) {
    if (session.updatedAt + SDK_SESSION_TTL_MS < now) sdkSessions.delete(key);
  }
}

function newLocalSdkAgentId(uuid: string): string {
  return uuid.startsWith("agent-") ? uuid : `agent-${uuid}`;
}

function newLocalSdkRunId(uuid: string): string {
  return uuid.startsWith("run-") ? uuid : `run-${uuid}`;
}

async function readPersistedSdkSession(env: Env, id: string, now: number): Promise<CursorSdkSession | undefined> {
  try {
    const row = await env.DB.prepare(`SELECT agent_id, updated_at FROM sdk_sessions WHERE id = ? LIMIT 1`)
      .bind(id)
      .first<{ agent_id: string; updated_at: string }>();
    if (!row?.agent_id) return undefined;
    const updatedAt = Date.parse(row.updated_at);
    if (!Number.isFinite(updatedAt) || updatedAt + SDK_SESSION_TTL_MS < now) {
      await deletePersistedSdkSession(env, id);
      return undefined;
    }
    const session = { agentId: row.agent_id, updatedAt };
    sdkSessions.set(id, session);
    return session;
  } catch {
    return undefined;
  }
}

async function savePersistedSdkSession(
  env: Env,
  identity: { id: string; ownerHash: string; sessionHash: string },
  agentId: string,
  updatedAt: Date
): Promise<void> {
  try {
    const timestamp = updatedAt.toISOString();
    await env.DB.prepare(
      `INSERT INTO sdk_sessions (id, owner_hash, session_hash, agent_id, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         agent_id = excluded.agent_id,
         updated_at = excluded.updated_at`
    )
      .bind(identity.id, identity.ownerHash, identity.sessionHash, agentId, timestamp, timestamp)
      .run();
  } catch {
    // D1 persistence is best-effort so local development without migrations still works.
  }
}

async function deletePersistedSdkSession(env: Env, id: string): Promise<void> {
  try {
    await env.DB.prepare(`DELETE FROM sdk_sessions WHERE id = ?`).bind(id).run();
  } catch {
    // Ignore missing table or transient persistence failures.
  }
}

function protoMessage(parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const output = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.length;
  }
  return output;
}

function protoMessageField(fieldNumber: number, value: Uint8Array): Uint8Array {
  return protoLengthDelimitedField(fieldNumber, value);
}

function protoStringField(fieldNumber: number, value: string | undefined): Uint8Array {
  if (value === undefined) return new Uint8Array(0);
  return protoLengthDelimitedField(fieldNumber, new TextEncoder().encode(value));
}

function protoLengthDelimitedField(fieldNumber: number, value: Uint8Array): Uint8Array {
  return protoMessage([varint((fieldNumber << 3) | 2), varint(value.length), value]);
}

function protoVarintField(fieldNumber: number, value: number | boolean | undefined): Uint8Array {
  if (value === undefined) return new Uint8Array(0);
  return protoMessage([varint(fieldNumber << 3), varint(value === true ? 1 : value === false ? 0 : value)]);
}

function varint(value: number): Uint8Array {
  const bytes: number[] = [];
  let current = value >>> 0;
  while (current >= 0x80) {
    bytes.push((current & 0x7f) | 0x80);
    current >>>= 7;
  }
  bytes.push(current);
  return new Uint8Array(bytes);
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
          throw new HttpError("Cursor returned a compressed SDK frame that this Worker cannot decode.", 502, "cursor_stream_error");
        }
        if ((flags & 2) === 2) {
          handleEndStreamFrame(payload);
          continue;
        }
        yield payload;
      }
    }
  } finally {
    await reader.cancel().catch(() => undefined);
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
      const message = typeof parsed.error.message === "string" ? parsed.error.message : "Cursor local SDK stream failed";
      throw new HttpError(message, 502, "cursor_stream_error");
    }
  } catch (error) {
    if (error instanceof HttpError) throw error;
  }
}

function decodeProtobufFields(bytes: Uint8Array): ProtobufField[] {
  const fields: ProtobufField[] = [];
  let offset = 0;
  while (offset < bytes.length) {
    const key = readVarint(bytes, offset);
    offset = key.offset;
    const fieldNumber = key.value >> 3;
    const wireType = key.value & 7;
    if (wireType === 0) {
      const value = readVarint(bytes, offset);
      offset = value.offset;
      fields.push({ no: fieldNumber, wt: wireType, value: value.value });
    } else if (wireType === 1) {
      const end = offset + 8;
      if (end > bytes.length) break;
      const view = new DataView(bytes.buffer, bytes.byteOffset + offset, 8);
      fields.push({ no: fieldNumber, wt: wireType, value: view.getFloat64(0, true) });
      offset = end;
    } else if (wireType === 2) {
      const length = readVarint(bytes, offset);
      offset = length.offset;
      const end = offset + length.value;
      if (end > bytes.length) break;
      fields.push({ no: fieldNumber, wt: wireType, value: bytes.slice(offset, end) });
      offset = end;
    } else if (wireType === 5) {
      const end = offset + 4;
      if (end > bytes.length) break;
      const view = new DataView(bytes.buffer, bytes.byteOffset + offset, 4);
      fields.push({ no: fieldNumber, wt: wireType, value: view.getUint32(0, true) });
      offset = end;
    } else {
      break;
    }
  }
  return fields;
}

function readVarint(bytes: Uint8Array, offset: number): { value: number; offset: number } {
  let value = 0;
  let shift = 0;
  let cursor = offset;
  while (cursor < bytes.length) {
    const byte = bytes[cursor++];
    value |= (byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) return { value, offset: cursor };
    shift += 7;
  }
  return { value, offset: cursor };
}

function bytesField(fields: ProtobufField[], fieldNumber: number): Uint8Array | undefined {
  const field = fields.find((item) => item.no === fieldNumber && item.value instanceof Uint8Array);
  return field?.value instanceof Uint8Array ? field.value : undefined;
}

function stringField(fields: ProtobufField[], fieldNumber: number): string | undefined {
  const bytes = bytesField(fields, fieldNumber);
  return bytes ? decodeUtf8(bytes) : undefined;
}

function stringFields(fields: ProtobufField[], fieldNumber: number): string[] | undefined {
  const values = fields
    .filter((item) => item.no === fieldNumber && item.value instanceof Uint8Array)
    .map((item) => decodeUtf8(item.value as Uint8Array));
  return values.length ? values : undefined;
}

function numberField(fields: ProtobufField[], fieldNumber: number): number | undefined {
  const field = fields.find((item) => item.no === fieldNumber && typeof item.value === "number");
  return typeof field?.value === "number" ? field.value : undefined;
}

function booleanField(fields: ProtobufField[], fieldNumber: number): boolean | undefined {
  const value = numberField(fields, fieldNumber);
  return value === undefined ? undefined : value !== 0;
}

function protoValueMap(fields: ProtobufField[], fieldNumber: number): Record<string, unknown> | undefined {
  const output: Record<string, unknown> = {};
  for (const field of fields) {
    if (field.no !== fieldNumber || !(field.value instanceof Uint8Array)) continue;
    const entryFields = decodeProtobufFields(field.value);
    const key = stringField(entryFields, 1);
    const valueBytes = bytesField(entryFields, 2);
    const value = valueBytes ? protoValue(valueBytes) : undefined;
    if (key && value !== undefined) output[key] = value;
  }
  return Object.keys(output).length ? output : undefined;
}

function protoValue(bytes: Uint8Array): unknown {
  const fields = decodeProtobufFields(bytes);
  if (fields.some((field) => field.no === 1)) return null;
  const numberValue = numberField(fields, 2);
  if (numberValue !== undefined) return numberValue;
  const stringValue = stringField(fields, 3);
  if (stringValue !== undefined) return stringValue;
  const boolValue = booleanField(fields, 4);
  if (boolValue !== undefined) return boolValue;
  const structValue = bytesField(fields, 5);
  if (structValue) return protoStruct(structValue);
  const listValue = bytesField(fields, 6);
  if (listValue) return protoList(listValue);
  return undefined;
}

function protoStruct(bytes: Uint8Array): Record<string, unknown> {
  return protoValueMap(decodeProtobufFields(bytes), 1) ?? {};
}

function protoList(bytes: Uint8Array): unknown[] {
  const output: unknown[] = [];
  for (const field of decodeProtobufFields(bytes)) {
    if (field.no !== 1 || !(field.value instanceof Uint8Array)) continue;
    const value = protoValue(field.value);
    if (value !== undefined) output.push(value);
  }
  return output;
}

function stringArg(args: Record<string, unknown>, key: string): string | undefined {
  const value = args[key];
  return typeof value === "string" && value ? value : undefined;
}

function compactRecord(input: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(input).filter(([, value]) => value !== undefined && (!Array.isArray(value) || value.length > 0))
  );
}

function stableToolCallId(value: Uint8Array): string {
  let hash = 0;
  for (const byte of value.slice(0, 64)) hash = (hash * 31 + byte) >>> 0;
  return `tool_${hash.toString(16)}`;
}

function concatBytes(a: Uint8Array<ArrayBufferLike>, b: Uint8Array<ArrayBufferLike>): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(a.length + b.length) as Uint8Array<ArrayBuffer>;
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

function decodeUtf8(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
