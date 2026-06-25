#!/usr/bin/env node
import { Agent, Cursor } from "@cursor/sdk";
import crypto from "node:crypto";
import events from "node:events";
import { existsSync, readFileSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const encoder = new TextEncoder();
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");

events.defaultMaxListeners = Math.max(events.defaultMaxListeners, 64);

loadEnvFile(path.join(repoRoot, ".env"));
loadEnvFile(path.join(process.cwd(), ".env"));

const workspaceCwd = path.resolve(process.env.CURSOR_SDK_PROXY_CWD || process.cwd());
const port = parseInteger(process.env.CURSOR_SDK_PROXY_PORT, 8791);
const host = process.env.CURSOR_SDK_PROXY_HOST || "127.0.0.1";
const stateRoot =
  process.env.CURSOR_SDK_PROXY_STATE_ROOT ||
  path.join(os.homedir(), ".local", "share", "standardagents", "cursor-sdk-responses");
const workspaceHash = crypto.createHash("sha256").update(workspaceCwd).digest("hex").slice(0, 24);
const stateDir = path.join(stateRoot, workspaceHash);
const statePath = path.join(stateDir, "state.json");
const defaultModel = process.env.CURSOR_SDK_PROXY_MODEL || "composer-2.5";

process.chdir(workspaceCwd);
await mkdir(stateDir, { recursive: true });

let state = await readState();
const agentCache = new Map();
let modelCache;

const server = http.createServer((request, response) => {
  handleRequest(request, response).catch((error) => {
    if (response.headersSent) {
      writeSse(response, "response.failed", {
        type: "response.failed",
        response: responseObject({
          id: `resp_${randomId()}`,
          created: nowSeconds(),
          model: defaultModel,
          text: "",
          status: "failed",
          error: normalizeError(error)
        })
      });
      response.end();
      return;
    }
    writeJson(response, openAiError(error), statusFromError(error));
  });
});

server.listen(port, host, () => {
  console.log(`Cursor SDK Responses proxy listening on http://${host}:${port}/sdk/v1`);
  console.log(`Workspace: ${workspaceCwd}`);
});

process.on("SIGINT", () => closeAndExit(0));
process.on("SIGTERM", () => closeAndExit(0));

async function handleRequest(request, response) {
  const url = new URL(request.url || "/", `http://${request.headers.host || `${host}:${port}`}`);
  const apiPath = normalizeApiPath(url.pathname);

  if (request.method === "OPTIONS") {
    writeCors(response, 204);
    response.end();
    return;
  }

  if (request.method === "GET" && apiPath === "/health") {
    writeJson(response, { ok: true, cwd: workspaceCwd });
    return;
  }

  if (request.method === "GET" && apiPath === "/models") {
    const apiKey = getApiKey(request);
    writeJson(response, await modelList(apiKey));
    return;
  }

  const responseMatch = /^\/responses\/([^/]+)$/.exec(apiPath);
  if (request.method === "GET" && responseMatch) {
    const record = state.responses?.[responseMatch[1]];
    if (!record?.response) {
      writeJson(response, openAiError(new HttpError("Response not found", 404, "not_found")), 404);
      return;
    }
    writeJson(response, record.response);
    return;
  }

  if (request.method === "POST" && apiPath === "/responses") {
    await handleCreateResponse(request, response);
    return;
  }

  writeJson(response, openAiError(new HttpError("Not found", 404, "not_found")), 404);
}

function normalizeApiPath(pathname) {
  if (pathname.startsWith("/sdk/v1/")) return pathname.slice("/sdk/v1".length);
  if (pathname === "/sdk/v1") return "/";
  if (pathname.startsWith("/v1/")) return pathname.slice("/v1".length);
  if (pathname === "/v1") return "/";
  return pathname;
}

async function handleCreateResponse(request, response) {
  const body = await readJsonBody(request);
  const apiKey = getApiKey(request);
  if (!apiKey) {
    writeJson(response, openAiError(new HttpError("Missing Cursor API key", 401, "unauthorized")), 401);
    return;
  }

  const created = nowSeconds();
  const responseId = `resp_${randomId()}`;
  const model = normalizeModel(body.model);
  const previousResponseId = typeof body.previous_response_id === "string" ? body.previous_response_id : null;
  const previous = previousResponseId ? state.responses?.[previousResponseId] : undefined;
  const parsed = parseResponseInput(body);
  const prompt = buildPrompt({
    instructions: typeof body.instructions === "string" ? body.instructions : "",
    inputText: parsed.text,
    previous,
    cwd: workspaceCwd
  });

  if (body.stream === true) {
    writeSseHeaders(response);
    for (const event of responseStartedEvents({ id: responseId, created, model, previousResponseId })) {
      response.write(event);
    }

    try {
      const { text, agentId, runId } = await runSdkAgent({
        apiKey,
        model,
        previous,
        message: parsed.images.length ? { text: prompt, images: parsed.images } : prompt,
        responseId,
        response
      });
      const output = text || "Done.";
      const responsePayload = responseObject({
        id: responseId,
        created,
        model,
        text: output,
        previousResponseId,
        agentId,
        runId
      });
      for (const event of responseCompletedEvents(responsePayload, output)) response.write(event);
      await saveResponseRecord(responseId, {
        response: responsePayload,
        agentId,
        runId,
        model,
        cwd: workspaceCwd,
        previousResponseId,
        history: [...(previous?.history ?? []), { role: "user", text: parsed.text }, { role: "assistant", text: output }],
        createdAt: new Date().toISOString()
      });
    } catch (error) {
      const payload = responseObject({
        id: responseId,
        created,
        model,
        text: "",
        previousResponseId,
        status: "failed",
        error: normalizeError(error)
      });
      writeSse(response, "response.failed", { type: "response.failed", response: payload });
    } finally {
      response.end();
    }
    return;
  }

  const { text, agentId, runId } = await runSdkAgent({
    apiKey,
    model,
    previous,
    message: parsed.images.length ? { text: prompt, images: parsed.images } : prompt,
    responseId
  });
  const output = text || "Done.";
  const responsePayload = responseObject({
    id: responseId,
    created,
    model,
    text: output,
    previousResponseId,
    agentId,
    runId
  });
  await saveResponseRecord(responseId, {
    response: responsePayload,
    agentId,
    runId,
    model,
    cwd: workspaceCwd,
    previousResponseId,
    history: [...(previous?.history ?? []), { role: "user", text: parsed.text }, { role: "assistant", text: output }],
    createdAt: new Date().toISOString()
  });
  writeJson(response, responsePayload);
}

async function runSdkAgent({ apiKey, model, previous, message, response, responseId }) {
  const agent = await getAgent({ apiKey, model, previous });
  const run = await agent.send(message, {
    model: { id: model },
    idempotencyKey: crypto.randomUUID()
  });
  let text = "";

  for await (const event of run.stream()) {
    if (event.type === "assistant") {
      for (const block of event.message.content ?? []) {
        if (block.type === "text" && block.text) {
          text += block.text;
          if (response) writeSse(response, "response.output_text.delta", outputTextDelta(responseId, block.text));
        }
      }
    }
  }

  const result = await run.wait();
  if (!text && result.result) {
    text = result.result;
    if (response) writeSse(response, "response.output_text.delta", outputTextDelta(responseId, text));
  }
  if (result.status === "error") {
    throw new HttpError("Cursor SDK run failed", 502, "cursor_sdk_error");
  }

  return { text: stripFinalMarker(text), agentId: agent.agentId, runId: run.id };
}

async function getAgent({ apiKey, model, previous }) {
  const previousAgentId = previous?.agentId;
  if (previousAgentId && agentCache.has(previousAgentId)) return agentCache.get(previousAgentId);

  if (previousAgentId) {
    try {
      const resumed = await Agent.resume(previousAgentId, {
        apiKey,
        model: { id: model },
        local: { cwd: workspaceCwd }
      });
      agentCache.set(resumed.agentId, resumed);
      return resumed;
    } catch {
      // Fall through to a new local agent. The proxy still carries the prior
      // transcript in the next prompt, so Responses state remains intact.
    }
  }

  const created = await Agent.create({
    apiKey,
    model: { id: model },
    name: "Standard Agents Responses proxy",
    local: { cwd: workspaceCwd }
  });
  agentCache.set(created.agentId, created);
  return created;
}

function buildPrompt({ instructions, inputText, previous, cwd }) {
  const parts = [
    "You are running in agent mode with local workspace tools available.",
    `Project directory: ${cwd}`,
    "When the request asks for project work, inspect, create, edit, and run files directly in that project.",
    "Do not tell the user to switch modes. Do not ask the user to paste files manually."
  ];

  if (instructions.trim()) {
    parts.push(`Instructions:\n${instructions.trim()}`);
  }

  const history = previous?.history ?? [];
  if (history.length) {
    const recent = history.slice(-16).map((item) => `${item.role.toUpperCase()}: ${item.text || "[empty]"}`);
    parts.push(`Prior conversation:\n${recent.join("\n")}`);
  }

  parts.push(`Current request:\n${inputText || "[empty]"}`);
  return parts.join("\n\n");
}

function parseResponseInput(body) {
  const input = body.input;
  const images = [];
  const lines = [];

  if (typeof input === "string") {
    lines.push(input);
  } else if (Array.isArray(input)) {
    for (const item of input) {
      parseInputItem(item, lines, images);
    }
  } else if (input && typeof input === "object") {
    parseInputItem(input, lines, images);
  }

  if (!lines.length && typeof body.prompt === "string") lines.push(body.prompt);
  return { text: lines.join("\n").trim(), images };
}

function parseInputItem(item, lines, images) {
  if (!item || typeof item !== "object") return;
  const role = typeof item.role === "string" ? item.role : typeof item.type === "string" ? item.type : "input";

  if (item.type === "function_call_output") {
    lines.push(`TOOL RESULT ${item.call_id || ""}: ${stringifyContent(item.output)}`);
    return;
  }
  if (item.type === "function_call") {
    lines.push(`TOOL CALL ${item.name || ""}: ${stringifyContent(item.arguments)}`);
    return;
  }
  if (item.type === "message" && item.content !== undefined) {
    appendContent(role, item.content, lines, images);
    return;
  }
  if (item.content !== undefined) {
    appendContent(role, item.content, lines, images);
    return;
  }
  if (typeof item.text === "string") {
    lines.push(`${role.toUpperCase()}: ${item.text}`);
  }
}

function appendContent(role, content, lines, images) {
  if (typeof content === "string") {
    lines.push(`${role.toUpperCase()}: ${content}`);
    return;
  }
  if (!Array.isArray(content)) {
    lines.push(`${role.toUpperCase()}: ${stringifyContent(content)}`);
    return;
  }

  const text = [];
  for (const part of content) {
    if (!part || typeof part !== "object") continue;
    if (typeof part.text === "string") text.push(part.text);
    if (part.type === "input_text" && typeof part.text === "string") text.push(part.text);
    if (part.type === "output_text" && typeof part.text === "string") text.push(part.text);
    if (part.type === "input_image") {
      const image = parseImage(part.image_url ?? part);
      if (image) images.push(image);
    }
  }
  lines.push(`${role.toUpperCase()}: ${text.join("\n") || "[non-text input]"}`);
}

function parseImage(value) {
  const source = typeof value === "string" ? value : value && typeof value === "object" ? value.url : undefined;
  if (!source || typeof source !== "string") return null;
  const dimension =
    value && typeof value === "object" && Number.isFinite(value.width) && Number.isFinite(value.height)
      ? { width: value.width, height: value.height }
      : undefined;

  if (source.startsWith("data:")) {
    const match = /^data:([^;,]+);base64,(.*)$/s.exec(source);
    if (!match) return null;
    return { mimeType: match[1], data: match[2], ...(dimension ? { dimension } : {}) };
  }
  return { url: source, ...(dimension ? { dimension } : {}) };
}

async function modelList(apiKey) {
  const now = Date.now();
  if (modelCache && modelCache.expiresAt > now) return modelCache.value;

  let models = fallbackModels();
  if (apiKey) {
    try {
      const sdkModels = await Cursor.models.list({ apiKey });
      if (sdkModels.length) {
        models = sdkModels.map((model) => ({
          id: model.id,
          object: "model",
          created: 1779148800,
          owned_by: "cursor",
          name: model.displayName || model.id,
          aliases: model.aliases || []
        }));
      }
    } catch {
      models = fallbackModels();
    }
  }

  const value = { object: "list", data: models };
  modelCache = { value, expiresAt: now + 10 * 60 * 1000 };
  return value;
}

function fallbackModels() {
  return [
    modelItem("composer-2.5", "Cursor Composer 2.5"),
    modelItem("composer-2.5-fast", "Cursor Composer 2.5 Fast"),
    modelItem("composer-latest", "Cursor Composer latest alias"),
    modelItem("gpt-5.5", "GPT-5.5"),
    modelItem("gpt-5.3-codex", "Codex 5.3"),
    modelItem("gpt-5.2-codex", "Codex 5.2"),
    modelItem("gpt-5.1", "GPT-5.1"),
    modelItem("gpt-5-mini", "GPT-5 Mini")
  ];
}

function modelItem(id, name) {
  return { id, object: "model", created: 1779148800, owned_by: "cursor", name };
}

function responseStartedEvents({ id, created, model, previousResponseId }) {
  const response = responseObject({ id, created, model, text: "", previousResponseId, status: "in_progress" });
  const item = messageItem(id, "", "in_progress");
  return [
    sse("response.created", { type: "response.created", response }),
    sse("response.in_progress", { type: "response.in_progress", response }),
    sse("response.output_item.added", { type: "response.output_item.added", output_index: 0, item }),
    sse("response.content_part.added", {
      type: "response.content_part.added",
      item_id: item.id,
      output_index: 0,
      content_index: 0,
      part: { type: "output_text", text: "", annotations: [] }
    })
  ];
}

function outputTextDelta(responseId, delta) {
  return {
    type: "response.output_text.delta",
    item_id: messageItem(responseId, "", "in_progress").id,
    output_index: 0,
    content_index: 0,
    delta
  };
}

function responseCompletedEvents(response, text) {
  const item = messageItem(response.id, text, "completed");
  return [
    sse("response.output_text.done", {
      type: "response.output_text.done",
      item_id: item.id,
      output_index: 0,
      content_index: 0,
      text
    }),
    sse("response.content_part.done", {
      type: "response.content_part.done",
      item_id: item.id,
      output_index: 0,
      content_index: 0,
      part: item.content[0]
    }),
    sse("response.output_item.done", { type: "response.output_item.done", output_index: 0, item }),
    sse("response.completed", { type: "response.completed", response })
  ];
}

function responseObject({
  id,
  created,
  model,
  text,
  previousResponseId = null,
  agentId,
  runId,
  status = "completed",
  error = null
}) {
  return {
    id,
    object: "response",
    created_at: created,
    status,
    completed_at: status === "completed" ? Math.max(created, nowSeconds()) : null,
    error,
    incomplete_details: null,
    model,
    output: status === "failed" ? [] : [messageItem(id, text, status === "completed" ? "completed" : "in_progress")],
    output_text: text,
    parallel_tool_calls: true,
    previous_response_id: previousResponseId,
    reasoning: { effort: null, summary: null },
    store: true,
    tool_choice: "auto",
    tools: [],
    truncation: "disabled",
    usage: {
      input_tokens: 0,
      output_tokens: approximateTokens(text),
      total_tokens: approximateTokens(text),
      input_tokens_details: { cached_tokens: 0 },
      output_tokens_details: { reasoning_tokens: 0 }
    },
    user: null,
    metadata: {
      ...(agentId ? { cursor_agent_id: agentId } : {}),
      ...(runId ? { cursor_run_id: runId } : {})
    }
  };
}

function messageItem(responseId, text, status) {
  const suffix = responseId.replace(/^resp_/, "").slice(0, 32);
  return {
    id: `msg_${suffix}`,
    type: "message",
    status,
    role: "assistant",
    content: [{ type: "output_text", text, annotations: [] }]
  };
}

async function saveResponseRecord(id, record) {
  state = {
    version: 1,
    responses: {
      ...(state.responses ?? {}),
      [id]: record
    }
  };
  await writeFile(statePath, JSON.stringify(state, null, 2));
}

async function readState() {
  if (!existsSync(statePath)) return { version: 1, responses: {} };
  try {
    return JSON.parse(await readFile(statePath, "utf8"));
  } catch {
    return { version: 1, responses: {} };
  }
}

async function readJsonBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString("utf8");
  if (!raw.trim()) return {};
  try {
    return JSON.parse(raw);
  } catch {
    throw new HttpError("Invalid JSON request body", 400, "invalid_json");
  }
}

function getApiKey(request) {
  const authorization = request.headers.authorization || "";
  const match = /^Bearer\s+(.+)$/i.exec(authorization);
  const token = match?.[1]?.trim();
  if (token && token !== "local" && token !== "dummy") return token;
  if (process.env.CURSOR_API_KEY) return process.env.CURSOR_API_KEY;
  return "";
}

function normalizeModel(model) {
  if (typeof model !== "string" || !model.trim()) return defaultModel;
  if (model === "default" || model === "auto") return defaultModel;
  return model.trim();
}

function writeJson(response, payload, status = 200) {
  writeCors(response, status, { "Content-Type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(payload, null, 2));
}

function writeCors(response, status, headers = {}) {
  response.writeHead(status, {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, content-type, openai-beta",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    ...headers
  });
}

function writeSseHeaders(response) {
  writeCors(response, 200, {
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no"
  });
}

function sse(event, data) {
  return encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

function writeSse(response, event, data) {
  response.write(sse(event, data));
}

function openAiError(error) {
  const normalized = normalizeError(error);
  return {
    error: {
      message: normalized.message,
      type: "cursor_sdk_error",
      code: normalized.code || "cursor_sdk_error"
    }
  };
}

function normalizeError(error) {
  if (error instanceof HttpError) return { message: error.message, code: error.code };
  if (error && typeof error === "object" && "message" in error) {
    return { message: String(error.message), code: typeof error.code === "string" ? error.code : "cursor_sdk_error" };
  }
  return { message: String(error || "Cursor SDK request failed"), code: "cursor_sdk_error" };
}

function statusFromError(error) {
  return error instanceof HttpError ? error.status : 502;
}

class HttpError extends Error {
  constructor(message, status, code) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function stringifyContent(value) {
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

function stripFinalMarker(text) {
  return text.replace(/<\s*[|｜]\s*final\s*[|｜]\s*>/g, "").trim();
}

function approximateTokens(text) {
  return Math.max(0, Math.ceil((text || "").length / 4));
}

function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

function randomId() {
  return crypto.randomUUID().replaceAll("-", "");
}

function parseInteger(value, fallback) {
  const parsed = Number.parseInt(value || "", 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function loadEnvFile(file) {
  if (!existsSync(file)) return;
  const text = readFileSync(file, "utf8");
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const match = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(trimmed);
    if (!match) continue;
    const [, key, rawValue] = match;
    if (process.env[key] !== undefined) continue;
    process.env[key] = rawValue.replace(/^["']|["']$/g, "");
  }
}

async function closeAndExit(code) {
  for (const agent of agentCache.values()) {
    try {
      await agent[Symbol.asyncDispose]?.();
    } catch {
      // Ignore shutdown cleanup failures.
    }
  }
  server.close(() => process.exit(code));
  setTimeout(() => process.exit(code), 1000).unref();
}
