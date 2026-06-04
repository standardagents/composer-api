#!/usr/bin/env node
import { Agent } from "@cursor/sdk";
import crypto from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import http from "node:http";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");

loadEnvFile(path.join(repoRoot, ".env"));
loadEnvFile(path.join(process.cwd(), ".env"));

const host = process.env.CURSOR_SDK_BRIDGE_HOST || "127.0.0.1";
const port = parseInteger(process.env.CURSOR_SDK_BRIDGE_PORT, 8792);
const bridgeToken = process.env.CURSOR_SDK_BRIDGE_TOKEN || "";
const maxJsonBytes = parseInteger(process.env.CURSOR_SDK_BRIDGE_MAX_JSON_BYTES, 1024 * 1024);
const maxAgents = parseInteger(process.env.CURSOR_SDK_BRIDGE_MAX_AGENTS, 128);
const runTimeoutMs = parseInteger(process.env.CURSOR_SDK_BRIDGE_RUN_TIMEOUT_MS, 180 * 1000);
const maxRunRetries = parseInteger(process.env.CURSOR_SDK_BRIDGE_MAX_RUN_RETRIES, 3);
const retryBaseDelayMs = parseInteger(process.env.CURSOR_SDK_BRIDGE_RETRY_BASE_DELAY_MS, 500);
const defaultCwd = process.env.CURSOR_SDK_WORKING_DIRECTORY || process.cwd();
const clientMcpServerName = "client";
const clientMcpServerMode = "--client-mcp-server";
const clientToolCallbackPath = "/client-tool-call";

const agentCache = new Map();
const agentRunQueues = new Map();
const activeClientToolCaptures = new Map();
const forceNextRunAgentKeys = new Set();
let server = null;

if (isMainModule()) {
  installBridgeProcessHandlers();
  if (process.argv.includes(clientMcpServerMode)) {
    await runClientForwardingMcpServerFromEnvironment();
  } else {
    startServer();
    process.on("SIGINT", () => closeAndExit(0));
    process.on("SIGTERM", () => closeAndExit(0));
  }
}

export {
  bridgePrompt,
  clientMcpToolDefinitions,
  clientForwardingMcpServerSource,
  localAgentCreateOptions,
  localAgentSendOptions,
  isForwardableSDKToolCall,
  isRetryableSDKRunError,
  normalizeSDKToolCall,
  normalizeModel,
  openAiError,
  runExclusiveForAgent,
  sdkRunFailureSummary,
  statusFromError,
  startServer,
  validateClientMcpToolCall,
  toolCallFromDelta
};

function startServer() {
  if (server) return server;
  server = http.createServer((request, response) => {
    handleRequest(request, response).catch((error) => {
      writeJson(response, openAiError(error), statusFromError(error));
    });
  });
  server.listen(port, host, () => {
    console.log(`Cursor SDK local-agent bridge listening on http://${host}:${port}/sdk`);
  });
  return server;
}

async function handleRequest(request, response) {
  const url = new URL(request.url || "/", `http://${request.headers.host || `${host}:${port}`}`);

  if (request.method === "GET" && url.pathname === "/health") {
    writeJson(response, { ok: true, agents: agentCache.size });
    return;
  }

  if (request.method === "POST" && url.pathname === clientToolCallbackPath) {
    await handleClientToolCallback(request, response);
    return;
  }

  if (request.method !== "POST" || url.pathname !== "/sdk") {
    writeJson(response, openAiError(new HttpError("Not found", 404, "not_found")), 404);
    return;
  }

  if (bridgeToken && bearerToken(request) !== bridgeToken) {
    writeJson(response, openAiError(new HttpError("Invalid bridge token", 401, "unauthorized")), 401);
    return;
  }

  const body = await readJsonBody(request);
  const apiKey = requiredString(body.apiKey, "apiKey");
  const prompt = requiredString(body.prompt, "prompt");
  const incrementalPrompt = typeof body.incrementalPrompt === "string" && body.incrementalPrompt.trim()
    ? body.incrementalPrompt
    : prompt;
  const promptAlreadyPrepared = body.promptAlreadyPrepared === true;
  const model = normalizeModel(typeof body.model === "string" ? body.model : "");
  const sessionKey = typeof body.sessionKey === "string" && body.sessionKey ? body.sessionKey : crypto.randomUUID();
  const workingDirectory = sdkWorkingDirectory(body.workingDirectory);
  const requestId = typeof body.requestId === "string" && body.requestId ? body.requestId : crypto.randomUUID();
  const clientTools = parseClientTools(body.tools);
  const streamEvents = body.streamEvents === true;

  const input = {
    apiKey,
    model,
    prompt: promptAlreadyPrepared ? prompt : bridgePrompt(prompt, clientTools),
    incrementalPrompt: promptAlreadyPrepared ? incrementalPrompt : bridgePrompt(incrementalPrompt, clientTools),
    sessionKey,
    workingDirectory,
    requestId,
    clientTools
  };

  if (streamEvents) {
    await streamLocalAgent(input, response);
    return;
  }

  const output = await runLocalAgent(input);
  writeJson(response, output);
}

async function handleClientToolCallback(request, response) {
  if (bridgeToken && bearerToken(request) !== bridgeToken) {
    writeJson(response, openAiError(new HttpError("Invalid bridge token", 401, "unauthorized")), 401);
    return;
  }

  const body = await readJsonBody(request);
  const cacheKey = requiredString(body.cacheKey, "cacheKey");
  const toolName = requiredString(body.toolName, "toolName");
  const args = isRecord(body.arguments) ? body.arguments : {};
  const accepted = await captureActiveClientToolCall(cacheKey, { type: toolName, args });
  writeJson(response, { ok: true, accepted });
}

async function streamLocalAgent(input, response) {
  let closed = false;
  const markClosed = () => {
    closed = true;
  };
  const socket = response.socket;
  response.on("close", markClosed);
  response.on("error", markClosed);
  socket?.on?.("error", markClosed);
  response.writeHead(200, {
    "Content-Type": "application/x-ndjson; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    "Access-Control-Allow-Origin": "*"
  });
  const emit = (event) => {
    if (closed) return false;
    const wrote = writeNdjson(response, event);
    if (!wrote) closed = true;
    return wrote;
  };
  try {
    const output = await runLocalAgent(input, emit);
    emit({ type: "done", output });
  } catch (error) {
    emit({ type: "error", error: openAiError(error).error });
  } finally {
    response.off("close", markClosed);
    response.off("error", markClosed);
    socket?.off?.("error", markClosed);
    if (!response.writableEnded && !response.destroyed) {
      response.end();
    }
  }
}

async function runLocalAgent(input, onEvent) {
  return runExclusiveForAgent(input, () => runLocalAgentUnlocked(input, onEvent));
}

async function runLocalAgentUnlocked(input, onEvent) {
  for (let attempt = 0; ; attempt += 1) {
    let activeRun = null;
    let emittedEvent = false;
    let timer = null;
    const emit = onEvent
      ? (event) => {
          emittedEvent = true;
          return onEvent(event);
        }
      : undefined;
    const work = runLocalAgentBody(input, (run) => {
      activeRun = run;
    }, emit);
    const timeout = new Promise((_resolve, reject) => {
      timer = setTimeout(() => {
        const error = new HttpError("Cursor SDK bridge run timed out.", 504, "cursor_sdk_timeout");
        reject(error);
        if (activeRun) {
          activeRun.cancel().catch(() => {});
        }
      }, runTimeoutMs);
    });

    try {
      return await Promise.race([work, timeout]);
    } catch (error) {
      work.catch(() => {});
      const shouldRetry = attempt < maxRunRetries && !emittedEvent && isRetryableSDKRunError(error);
      if (!shouldRetry) throw error;
      if (activeRun) activeRun.cancel().catch(() => {});
      evictCachedAgent(input);
      console.warn(`Retrying Cursor SDK run after retryable upstream error (${attempt + 1}/${maxRunRetries}).`);
      await sleep(retryDelayMs(attempt));
    } finally {
      if (timer) clearTimeout(timer);
    }
  }
}

async function runExclusiveForAgent(input, work) {
  const cacheKey = agentCacheKey(input);
  const previous = agentRunQueues.get(cacheKey) ?? Promise.resolve();
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  const current = previous.catch(() => {}).then(() => gate);
  agentRunQueues.set(cacheKey, current);

  try {
    await previous.catch(() => {});
    return await work();
  } finally {
    release();
    if (agentRunQueues.get(cacheKey) === current) {
      agentRunQueues.delete(cacheKey);
    }
  }
}

async function runLocalAgentBody(input, onRun, onEvent) {
  const cacheKey = agentCacheKey(input);
  let agentEntry = null;
  let run;
  let capturedToolCall = null;
  let cancelRequested = false;
  let text = "";

  const captureToolCall = async (toolCall, options = {}) => {
    if (capturedToolCall || !toolCall) return;
    const normalized = normalizeSDKToolCall(toolCall, input.clientTools);
    if (!normalized || !isForwardableSDKToolCall(normalized, input.clientTools)) return;
    capturedToolCall = normalized;
    if (onEvent) onEvent({ type: "tool_call", toolCall: capturedToolCall });
    cancelRequested = true;
    if (run) {
      const cancellation = run.cancel().catch(() => {
        // The SDK may already be finishing the local run. The captured model
        // tool call is still the response we need to return to the client.
      });
      if (options.waitForCancel === true) {
        await cancellation;
      }
    }
  };

  const unregisterCapture = registerActiveClientToolCapture(cacheKey, async (toolCall) => {
    await captureToolCall(toolCall, { waitForCancel: false });
    return capturedToolCall !== null;
  });
  try {
    agentEntry = await getAgent(input);
    const agent = agentEntry.agent;
    const prompt = agentEntry.cached && input.incrementalPrompt ? input.incrementalPrompt : input.prompt;
    const force = forceNextRunAgentKeys.delete(cacheKey);

    run = await agent.send(prompt, {
      ...localAgentSendOptions(input, { force }),
      idempotencyKey: input.requestId,
      onDelta: async ({ update }) => {
        const toolCall = toolCallFromDelta(update);
        if (toolCall) await captureToolCall(toolCall);
      }
    });
    onRun(run);

    if (cancelRequested) {
      run.cancel().catch(() => {});
    }

    if (!capturedToolCall) {
      for await (const event of run.stream()) {
        if (event.type === "assistant") {
          for (const block of event.message?.content ?? []) {
            if (block?.type === "text" && typeof block.text === "string") {
              text += block.text;
              if (onEvent && block.text) onEvent({ type: "text", text: block.text });
            }
          }
          continue;
        }
        if (event.type === "tool_call") {
          if (event.status && event.status !== "running") continue;
          await captureToolCall({ type: event.name, args: event.args }, { waitForCancel: false });
          if (capturedToolCall) break;
        }
      }
    }
  } catch (error) {
    if (!capturedToolCall && !(cancelRequested && isBenignCancellationError(error))) {
      throw error;
    }
  } finally {
    unregisterCapture();
  }

  if (capturedToolCall) {
    if (agentEntry) forceNextRunAgentKeys.add(agentEntry.cacheKey);
    return {
      text: "",
      toolCalls: [capturedToolCall],
      agentID: agentEntry?.agent.agentId || "",
      runID: run?.id || input.requestId,
      status: "tool_call"
    };
  }

  const result = await run.wait();
  if (result.status === "error") {
    if (agentEntry) evictAgent(agentEntry.cacheKey, agentEntry.agent);
    throw sdkRunFailureError(result);
  }
  if (!text && typeof result.result === "string") text = result.result;
  return {
    text: stripFinalMarker(text),
    toolCalls: [],
    agentID: agentEntry?.agent.agentId || "",
    runID: run.id,
    status: result.status
  };
}

async function getAgent(input) {
  const cacheKey = agentCacheKey(input);
  const cached = agentCache.get(cacheKey);
  if (cached) {
    cached.touchedAt = Date.now();
    return { agent: cached.agent, cacheKey, cached: true };
  }

  const agent = await Agent.create(localAgentCreateOptions(input));
  agentCache.set(cacheKey, { agent, touchedAt: Date.now() });
  evictAgents();
  return { agent, cacheKey, cached: false };
}

function evictAgent(cacheKey, agent) {
  const cached = agentCache.get(cacheKey);
  if (cached?.agent === agent) {
    agentCache.delete(cacheKey);
  }
  forceNextRunAgentKeys.delete(cacheKey);
  try {
    agent.close();
  } catch {}
}

function evictCachedAgent(input) {
  const cacheKey = agentCacheKey(input);
  const cached = agentCache.get(cacheKey);
  if (cached) evictAgent(cacheKey, cached.agent);
}

function registerActiveClientToolCapture(cacheKey, handler) {
  if (!activeClientToolCaptures.has(cacheKey)) {
    activeClientToolCaptures.set(cacheKey, new Set());
  }
  const handlers = activeClientToolCaptures.get(cacheKey);
  handlers.add(handler);
  return () => {
    handlers.delete(handler);
    if (handlers.size === 0) activeClientToolCaptures.delete(cacheKey);
  };
}

async function captureActiveClientToolCall(cacheKey, toolCall) {
  const handlers = activeClientToolCaptures.get(cacheKey);
  if (!handlers || handlers.size === 0) return false;
  for (const handler of [...handlers]) {
    if (await handler(toolCall)) return true;
  }
  return false;
}

function localAgentCreateOptions(input) {
  return {
    apiKey: input.apiKey,
    model: sdkModelSelection(input.model),
    name: "API for Cursor local bridge",
    local: {
      cwd: input.workingDirectory
    }
  };
}

function localAgentSendOptions(input, optionsInput = {}) {
  const options = {
    model: sdkModelSelection(input.model)
  };
  if (optionsInput.force === true) {
    options.local = { force: true };
  }
  if (input.clientTools.length > 0) {
    options.mcpServers = clientForwardingMcpServers(input.clientTools, agentCacheKey(input));
  }
  return options;
}

function clientToolsNeedingMcp(clientTools = []) {
  return clientTools.filter((tool) => tool?.name);
}

function clientForwardingMcpServers(clientTools = [], cacheKey = "") {
  return {
    [clientMcpServerName]: {
      type: "stdio",
      command: process.execPath,
      args: [fileURLToPath(import.meta.url), clientMcpServerMode],
      env: {
        CURSOR_SDK_BRIDGE_CALLBACK_URL: `http://${host}:${port}${clientToolCallbackPath}`,
        CURSOR_SDK_BRIDGE_CALLBACK_TOKEN: bridgeToken,
        CURSOR_SDK_BRIDGE_AGENT_CACHE_KEY: cacheKey,
        CURSOR_SDK_BRIDGE_CLIENT_TOOLS_JSON: JSON.stringify(clientMcpToolDefinitions(clientTools))
      }
    }
  };
}

async function runClientForwardingMcpServerFromEnvironment() {
  await runClientForwardingMcpServer({
    tools: parseClientMcpToolsJSON(process.env.CURSOR_SDK_BRIDGE_CLIENT_TOOLS_JSON),
    callbackUrl: process.env.CURSOR_SDK_BRIDGE_CALLBACK_URL || "",
    callbackToken: process.env.CURSOR_SDK_BRIDGE_CALLBACK_TOKEN || "",
    callbackCacheKey: process.env.CURSOR_SDK_BRIDGE_AGENT_CACHE_KEY || ""
  });
}

function parseClientMcpToolsJSON(value) {
  if (typeof value !== "string" || !value.trim()) return clientMcpToolDefinitions([]);
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed : clientMcpToolDefinitions([]);
  } catch {
    return clientMcpToolDefinitions([]);
  }
}

async function runClientForwardingMcpServer({
  tools,
  callbackUrl,
  callbackToken,
  callbackCacheKey,
  input = process.stdin,
  output = process.stdout
}) {
  const rl = readline.createInterface({ input });
  let outputClosed = false;
  const writeOutput = (payload) => {
    if (outputClosed) return false;
    try {
      return output.write(payload);
    } catch (error) {
      if (!isBenignPipeError(error)) throw error;
      outputClosed = true;
      return false;
    }
  };
  output.on?.("error", (error) => {
    outputClosed = true;
    if (!isBenignPipeError(error)) process.exitCode = 1;
  });
  const send = (id, result) => {
    if (id === undefined || id === null) return;
    writeOutput(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
  };
  const sendError = (id, message) => {
    if (id === undefined || id === null) return;
    writeOutput(`${JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32000, message } })}\n`);
  };
  const pending = new Set();

  const handleLine = async (line) => {
    if (!line.trim()) return;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    if (!message.id && String(message.method || "").startsWith("notifications/")) return;
    if (message.method === "initialize") {
      send(message.id, {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "api-for-cursor-client-tools", version: "0.1.0" }
      });
      return;
    }
    if (message.method === "tools/list") {
      send(message.id, { tools });
      return;
    }
    if (message.method === "tools/call") {
      const params = message.params || {};
      const toolName = params.name || params.toolName;
      const toolInput = params.arguments || params.input || {};
      const validationError = validateClientMcpToolCall(tools, toolName, toolInput);
      if (validationError) {
        sendError(message.id, validationError);
        return;
      }
      const accepted = await notifyParentToolCall({ callbackUrl, callbackToken, callbackCacheKey, toolName, input: toolInput });
      if (!accepted) {
        sendError(message.id, "Outer client callback unavailable for forwarded tool call.");
        return;
      }
      send(message.id, {
        content: [{ type: "text", text: "FORWARDED_TO_OUTER_CLIENT" }],
        isError: false
      });
      return;
    }
    sendError(message.id, `Unsupported MCP method: ${message.method}`);
  };

  await new Promise((resolve) => {
    rl.on("line", (line) => {
      const task = handleLine(line)
        .catch((error) => {
          if (!isBenignPipeError(error)) process.exitCode = 1;
        })
        .finally(() => {
          pending.delete(task);
        });
      pending.add(task);
    });
    rl.on("close", async () => {
      await Promise.allSettled([...pending]);
      resolve();
    });
  });
}

async function notifyParentToolCall({ callbackUrl, callbackToken, callbackCacheKey, toolName, input }) {
  if (!callbackUrl || !callbackCacheKey) return true;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 1500);
  try {
    const headers = { "Content-Type": "application/json" };
    if (callbackToken) headers.Authorization = `Bearer ${callbackToken}`;
    const response = await fetch(callbackUrl, {
      method: "POST",
      headers,
      body: JSON.stringify({
        cacheKey: callbackCacheKey,
        toolName,
        arguments: input && typeof input === "object" && !Array.isArray(input) ? input : {}
      }),
      signal: controller.signal
    });
    if (!response.ok) return false;
    const body = await response.json().catch(() => ({}));
    return body && body.accepted === true;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

function clientForwardingMcpServerSource(clientTools = []) {
  const tools = JSON.stringify(clientMcpToolDefinitions(clientTools));
  return `
const readline = require("node:readline");
const tools = ${tools};
const callbackUrl = process.env.CURSOR_SDK_BRIDGE_CALLBACK_URL || "";
const callbackToken = process.env.CURSOR_SDK_BRIDGE_CALLBACK_TOKEN || "";
const callbackCacheKey = process.env.CURSOR_SDK_BRIDGE_AGENT_CACHE_KEY || "";
const validateClientMcpToolCall = ${validateClientMcpToolCall.toString()};
const validateJsonSchemaValue = ${validateJsonSchemaValue.toString()};
const canonicalJsonSchema = ${canonicalJsonSchema.toString()};
const schemaHasStructuralKeyword = ${schemaHasStructuralKeyword.toString()};
const schemaReferenceTarget = ${schemaReferenceTarget.toString()};
const jsonPointerTarget = ${jsonPointerTarget.toString()};
const decodeJsonPointerSegment = ${decodeJsonPointerSegment.toString()};
const schemaTypes = ${schemaTypes.toString()};
const schemaAllowsNull = ${schemaAllowsNull.toString()};
const validateStringConstraints = ${validateStringConstraints.toString()};
const validateNumberConstraints = ${validateNumberConstraints.toString()};
const patternPropertySchemasForKey = ${patternPropertySchemasForKey.toString()};
const schemaEvaluatesObjectProperty = ${schemaEvaluatesObjectProperty.toString()};
const jsonValueMatchesType = ${jsonValueMatchesType.toString()};
const jsonValuesEqual = ${jsonValuesEqual.toString()};
const isRecord = ${isRecord.toString()};
const stableJson = ${stableJson.toString()};
const sortJson = ${sortJson.toString()};
const rl = readline.createInterface({ input: process.stdin });
let stdoutClosed = false;
function isBenignPipeError(error) {
  return error?.code === "EPIPE" || error?.code === "ERR_STREAM_DESTROYED";
}
function writeStdout(payload) {
  if (stdoutClosed) return false;
  try {
    return process.stdout.write(payload);
  } catch (error) {
    if (!isBenignPipeError(error)) throw error;
    stdoutClosed = true;
    return false;
  }
}
process.stdout.on("error", (error) => {
  stdoutClosed = true;
  if (isBenignPipeError(error)) process.exit(0);
  process.exitCode = 1;
});
function send(id, result) {
  if (id === undefined || id === null) return;
  writeStdout(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n");
}
function sendError(id, message) {
  if (id === undefined || id === null) return;
  writeStdout(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32000, message } }) + "\\n");
}
async function notifyParentToolCall(toolName, input) {
  if (!callbackUrl || !callbackCacheKey) return true;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 1500);
  try {
    const headers = { "Content-Type": "application/json" };
    if (callbackToken) headers.Authorization = "Bearer " + callbackToken;
    const response = await fetch(callbackUrl, {
      method: "POST",
      headers,
      body: JSON.stringify({
        cacheKey: callbackCacheKey,
        toolName,
        arguments: input && typeof input === "object" && !Array.isArray(input) ? input : {}
      }),
      signal: controller.signal
    });
    if (!response.ok) return false;
    const body = await response.json().catch(() => ({}));
    return body && body.accepted === true;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}
rl.on("line", async (line) => {
  if (!line.trim()) return;
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  if (!message.id && String(message.method || "").startsWith("notifications/")) return;
  if (message.method === "initialize") {
    send(message.id, {
      protocolVersion: "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "api-for-cursor-client-tools", version: "0.1.0" }
    });
  } else if (message.method === "tools/list") {
    send(message.id, { tools });
  } else if (message.method === "tools/call") {
    const params = message.params || {};
    const toolName = params.name || params.toolName;
    const input = params.arguments || params.input || {};
    const validationError = validateClientMcpToolCall(tools, toolName, input);
    if (validationError) {
      sendError(message.id, validationError);
      return;
    }
    const accepted = await notifyParentToolCall(toolName, input);
    if (!accepted) {
      sendError(message.id, "Outer client callback unavailable for forwarded tool call.");
      return;
    }
    send(message.id, {
      content: [{ type: "text", text: "FORWARDED_TO_OUTER_CLIENT" }],
      isError: false
    });
  } else {
    sendError(message.id, "Unsupported MCP method: " + message.method);
  }
});
`;
}

function validateClientMcpToolCall(tools, toolName, input = {}) {
  if (typeof toolName !== "string" || !toolName.trim()) {
    return "Missing MCP tool name.";
  }
  const tool = Array.isArray(tools) ? tools.find((candidate) => candidate && candidate.name === toolName) : null;
  if (!tool) {
    return `Unknown client MCP forwarding tool: ${toolName}`;
  }
  const schema = canonicalJsonSchema(tool.inputSchema && typeof tool.inputSchema === "object" ? tool.inputSchema : {});
  const args = input && typeof input === "object" && !Array.isArray(input) ? input : {};
  return validateJsonSchemaValue(args, schema, toolName, schema);
}

function validateJsonSchemaValue(value, schema, path, rootSchema = schema, seenRefs = new Set()) {
  if (schema === true) return null;
  if (schema === false) return `Invalid value for ${path}: schema disallows value`;
  schema = canonicalJsonSchema(schema);
  const root = canonicalJsonSchema(rootSchema || schema);
  if (schema === true) return null;
  if (schema === false) return `Invalid value for ${path}: schema disallows value`;
  if (!schema || typeof schema !== "object" || Array.isArray(schema)) return null;
  const reference = schemaReferenceTarget(schema, root, seenRefs);
  if (reference) return validateJsonSchemaValue(value, reference.schema, path, root, reference.seenRefs);

  if (Object.prototype.hasOwnProperty.call(schema, "const") && !jsonValuesEqual(value, schema.const)) {
    return `Invalid value for ${path}: expected constant ${JSON.stringify(schema.const)}`;
  }
  if (Array.isArray(schema.enum) && !schema.enum.some((candidate) => jsonValuesEqual(candidate, value))) {
    return `Invalid value for ${path}: expected one of ${schema.enum.map((item) => JSON.stringify(item)).join(", ")}`;
  }

  const anyOf = Array.isArray(schema.anyOf) ? schema.anyOf : [];
  if (anyOf.length && !anyOf.some((candidate) => validateJsonSchemaValue(value, candidate, path, root, new Set(seenRefs)) === null)) {
    return `Invalid value for ${path}: did not match any allowed schema`;
  }
  const oneOf = Array.isArray(schema.oneOf) ? schema.oneOf : [];
  if (oneOf.length) {
    const matches = oneOf.filter((candidate) => validateJsonSchemaValue(value, candidate, path, root, new Set(seenRefs)) === null).length;
    if (matches === 0) {
      return `Invalid value for ${path}: did not match any allowed schema`;
    }
    if (matches > 1) {
      return `Invalid value for ${path}: matched more than one allowed schema`;
    }
  }
  const allOf = Array.isArray(schema.allOf) ? schema.allOf : [];
  for (const candidate of allOf) {
    const error = validateJsonSchemaValue(value, candidate, path, root, new Set(seenRefs));
    if (error) return error;
  }
  if ((isRecord(schema.not) || typeof schema.not === "boolean")
      && validateJsonSchemaValue(value, schema.not, path, root, new Set(seenRefs)) === null) {
    return `Invalid value for ${path}: matched disallowed schema`;
  }
  if (isRecord(schema.if) || typeof schema.if === "boolean") {
    const matchesIf = validateJsonSchemaValue(value, schema.if, path, root, new Set(seenRefs)) === null;
    if (matchesIf && (isRecord(schema.then) || typeof schema.then === "boolean")) {
      const error = validateJsonSchemaValue(value, schema.then, path, root, new Set(seenRefs));
      if (error) return error;
    }
    if (!matchesIf && (isRecord(schema.else) || typeof schema.else === "boolean")) {
      const error = validateJsonSchemaValue(value, schema.else, path, root, new Set(seenRefs));
      if (error) return error;
    }
  }

  if (value === null && schemaAllowsNull(schema, root, seenRefs)) return null;

  const types = schemaTypes(schema);
  if (types.length && !types.some((type) => jsonValueMatchesType(value, type))) {
    return `Invalid value for ${path}: expected ${types.join(" or ")}`;
  }
  const stringConstraintError = validateStringConstraints(value, schema, path);
  if (stringConstraintError) return stringConstraintError;
  const numberConstraintError = validateNumberConstraints(value, schema, path);
  if (numberConstraintError) return numberConstraintError;

  const objectLike = schema.properties
    || schema.patternProperties
    || schema.propertyNames
    || schema.required
    || schema.dependentRequired
    || schema.dependentSchemas
    || schema.minProperties !== undefined
    || schema.maxProperties !== undefined
    || schema.additionalProperties !== undefined
    || schema.unevaluatedProperties !== undefined
    || types.includes("object");
  if (objectLike) {
    if (!isRecord(value)) return `Invalid value for ${path}: expected object`;
    const properties = isRecord(schema.properties) ? schema.properties : {};
    const required = Array.isArray(schema.required) ? schema.required.filter((key) => typeof key === "string" && key.trim()) : [];
    const entries = Object.entries(value);
    if (Number.isInteger(schema.minProperties) && entries.length < schema.minProperties) {
      return `Invalid value for ${path}: expected at least ${schema.minProperties} propert${schema.minProperties === 1 ? "y" : "ies"}`;
    }
    if (Number.isInteger(schema.maxProperties) && entries.length > schema.maxProperties) {
      return `Invalid value for ${path}: expected at most ${schema.maxProperties} propert${schema.maxProperties === 1 ? "y" : "ies"}`;
    }
    for (const key of required) {
      if (!(key in value) || value[key] === undefined || value[key] === null) {
        return `Missing required argument for ${path}: ${key}`;
      }
    }
    if (isRecord(schema.dependentRequired)) {
      for (const [key, dependencies] of Object.entries(schema.dependentRequired)) {
        if (!Object.prototype.hasOwnProperty.call(value, key)) continue;
        if (!Array.isArray(dependencies)) continue;
        for (const dependency of dependencies) {
          if (typeof dependency !== "string" || !dependency.trim()) continue;
          if (!(dependency in value) || value[dependency] === undefined || value[dependency] === null) {
            return `Missing dependent argument for ${path}: ${dependency}`;
          }
        }
      }
    }
    if (isRecord(schema.dependentSchemas)) {
      for (const [key, dependentSchema] of Object.entries(schema.dependentSchemas)) {
        if (!Object.prototype.hasOwnProperty.call(value, key)) continue;
        const error = validateJsonSchemaValue(value, dependentSchema, path, root, new Set(seenRefs));
        if (error) return error;
      }
    }
    for (const [key, nestedValue] of entries) {
      if (isRecord(schema.propertyNames) || typeof schema.propertyNames === "boolean") {
        const error = validateJsonSchemaValue(key, schema.propertyNames, `${path} property name ${key}`, root, new Set(seenRefs));
        if (error) return error;
      }
      let validated = false;
      if (Object.prototype.hasOwnProperty.call(properties, key)) {
        const error = validateJsonSchemaValue(nestedValue, properties[key], `${path}.${key}`, root, new Set(seenRefs));
        if (error) return error;
        validated = true;
      }
      const patternSchemas = patternPropertySchemasForKey(schema, key);
      for (const patternSchema of patternSchemas) {
        const error = validateJsonSchemaValue(nestedValue, patternSchema, `${path}.${key}`, root, new Set(seenRefs));
        if (error) return error;
        validated = true;
      }
      const evaluatedByComposedSchema = schemaEvaluatesObjectProperty(schema, key, root, value, new Set(seenRefs));
      if (!validated && !evaluatedByComposedSchema && schema.additionalProperties === false) {
        return `Unexpected argument for ${path}: ${key}`;
      } else if (!validated && schema.additionalProperties === true) {
        validated = true;
      } else if (!validated && isRecord(schema.additionalProperties)) {
        const error = validateJsonSchemaValue(nestedValue, schema.additionalProperties, `${path}.${key}`, root, new Set(seenRefs));
        if (error) return error;
        validated = true;
      }
      if (!validated && !evaluatedByComposedSchema && schema.unevaluatedProperties === false) {
        return `Unexpected argument for ${path}: ${key}`;
      } else if (!validated && !evaluatedByComposedSchema && isRecord(schema.unevaluatedProperties)) {
        const error = validateJsonSchemaValue(nestedValue, schema.unevaluatedProperties, `${path}.${key}`, root, new Set(seenRefs));
        if (error) return error;
      }
    }
  }

  const arrayLike = schema.items
    || schema.prefixItems
    || schema.additionalItems !== undefined
    || schema.contains !== undefined
    || schema.minItems !== undefined
    || schema.maxItems !== undefined
    || schema.minContains !== undefined
    || schema.maxContains !== undefined
    || schema.unevaluatedItems !== undefined
    || schema.uniqueItems !== undefined
    || types.includes("array");
  if (arrayLike) {
    if (!Array.isArray(value)) return `Invalid value for ${path}: expected array`;
    if (Number.isInteger(schema.minItems) && value.length < schema.minItems) {
      return `Invalid value for ${path}: expected at least ${schema.minItems} item${schema.minItems === 1 ? "" : "s"}`;
    }
    if (Number.isInteger(schema.maxItems) && value.length > schema.maxItems) {
      return `Invalid value for ${path}: expected at most ${schema.maxItems} item${schema.maxItems === 1 ? "" : "s"}`;
    }
    if (schema.uniqueItems === true) {
      for (let left = 0; left < value.length; left += 1) {
        for (let right = left + 1; right < value.length; right += 1) {
          if (jsonValuesEqual(value[left], value[right])) {
            return `Invalid value for ${path}: expected unique items`;
          }
        }
      }
    }
    const evaluatedItems = new Set();
    if (isRecord(schema.contains) || typeof schema.contains === "boolean") {
      let matches = 0;
      for (let index = 0; index < value.length; index += 1) {
        if (validateJsonSchemaValue(value[index], schema.contains, path, root, new Set(seenRefs)) === null) {
          matches += 1;
          evaluatedItems.add(index);
        }
      }
      const minContains = Number.isInteger(schema.minContains) ? schema.minContains : 1;
      const maxContains = Number.isInteger(schema.maxContains) ? schema.maxContains : null;
      if (matches < minContains) {
        return `Invalid value for ${path}: expected at least ${minContains} matching item${minContains === 1 ? "" : "s"}`;
      }
      if (maxContains !== null && matches > maxContains) {
        return `Invalid value for ${path}: expected at most ${maxContains} matching item${maxContains === 1 ? "" : "s"}`;
      }
    }
    const prefixItems = Array.isArray(schema.prefixItems)
      ? schema.prefixItems
      : Array.isArray(schema.items)
        ? schema.items
        : [];
    for (let index = 0; index < Math.min(prefixItems.length, value.length); index += 1) {
      const error = validateJsonSchemaValue(value[index], prefixItems[index], `${path}[${index}]`, root, new Set(seenRefs));
      if (error) return error;
      evaluatedItems.add(index);
    }
    if (schema.additionalItems === false && value.length > prefixItems.length) {
      return `Unexpected array item for ${path}: ${prefixItems.length}`;
    }
    if (schema.additionalItems === true) {
      for (let index = prefixItems.length; index < value.length; index += 1) {
        evaluatedItems.add(index);
      }
    }
    if (isRecord(schema.additionalItems)) {
      for (let index = prefixItems.length; index < value.length; index += 1) {
        const error = validateJsonSchemaValue(value[index], schema.additionalItems, `${path}[${index}]`, root, new Set(seenRefs));
        if (error) return error;
        evaluatedItems.add(index);
      }
    }
    if (schema.items === false && value.length > prefixItems.length) {
      return `Unexpected array item for ${path}: ${prefixItems.length}`;
    }
    if (schema.items === true) {
      for (let index = prefixItems.length; index < value.length; index += 1) {
        evaluatedItems.add(index);
      }
    }
    if (!Array.isArray(schema.items) && isRecord(schema.items)) {
      for (let index = prefixItems.length; index < value.length; index += 1) {
        const error = validateJsonSchemaValue(value[index], schema.items, `${path}[${index}]`, root, new Set(seenRefs));
        if (error) return error;
        evaluatedItems.add(index);
      }
    }
    if (schema.unevaluatedItems === false) {
      const unevaluatedIndex = value.findIndex((_item, index) => !evaluatedItems.has(index));
      if (unevaluatedIndex >= 0) {
        return `Unexpected array item for ${path}: ${unevaluatedIndex}`;
      }
    }
    if (isRecord(schema.unevaluatedItems)) {
      for (let index = 0; index < value.length; index += 1) {
        if (evaluatedItems.has(index)) continue;
        const error = validateJsonSchemaValue(value[index], schema.unevaluatedItems, `${path}[${index}]`, root, new Set(seenRefs));
        if (error) return error;
      }
    }
  }

  return null;
}

function canonicalJsonSchema(schema) {
  let current = schema;
  const visited = new Set();
  while (isRecord(current)) {
    if (schemaHasStructuralKeyword(current)) return current;
    if (visited.has(current)) return current;
    visited.add(current);
    const wrapped = ["schema", "json_schema", "input_schema", "inputSchema"].map((key) => current[key]).find(isRecord);
    if (!wrapped) return current;
    current = wrapped;
  }
  return current;
}

function schemaHasStructuralKeyword(schema) {
  return [
    "$defs",
    "$ref",
    "additionalProperties",
    "additionalItems",
    "allOf",
    "anyOf",
    "const",
    "contains",
    "definitions",
    "else",
    "enum",
    "if",
    "items",
    "maxContains",
    "maxItems",
    "maxProperties",
    "minContains",
    "minItems",
    "minProperties",
    "not",
    "oneOf",
    "patternProperties",
    "prefixItems",
    "properties",
    "propertyNames",
    "required",
    "then",
    "dependentRequired",
    "dependentSchemas",
    "type",
    "unevaluatedItems",
    "unevaluatedProperties",
    "uniqueItems"
  ].some((key) => Object.prototype.hasOwnProperty.call(schema, key));
}

function schemaReferenceTarget(schema, rootSchema, seenRefs = new Set()) {
  if (!isRecord(schema) || typeof schema.$ref !== "string") return null;
  const ref = schema.$ref.trim();
  if (!ref.startsWith("#") || seenRefs.has(ref)) return null;
  const target = jsonPointerTarget(rootSchema, ref);
  if (!isRecord(target)) return null;
  const nextSeenRefs = new Set(seenRefs);
  nextSeenRefs.add(ref);
  return { schema: target, seenRefs: nextSeenRefs };
}

function jsonPointerTarget(root, ref) {
  if (ref === "#") return root;
  if (!ref.startsWith("#/")) return null;
  let pointer = ref.slice(1);
  try {
    pointer = decodeURIComponent(pointer);
  } catch {}
  let target = root;
  for (const rawSegment of pointer.slice(1).split("/")) {
    const segment = decodeJsonPointerSegment(rawSegment);
    if (Array.isArray(target) && /^\d+$/.test(segment)) {
      target = target[Number(segment)];
    } else if (isRecord(target) && Object.prototype.hasOwnProperty.call(target, segment)) {
      target = target[segment];
    } else {
      return null;
    }
  }
  return target;
}

function decodeJsonPointerSegment(segment) {
  return segment.replace(/~1/g, "/").replace(/~0/g, "~");
}

function schemaTypes(schema) {
  if (typeof schema.type === "string") return [schema.type];
  if (Array.isArray(schema.type)) return schema.type.filter((type) => typeof type === "string");
  return [];
}

function schemaAllowsNull(schema, rootSchema = schema, seenRefs = new Set()) {
  schema = canonicalJsonSchema(schema);
  if (!isRecord(schema)) return false;
  const root = canonicalJsonSchema(rootSchema || schema);
  const reference = schemaReferenceTarget(schema, root, seenRefs);
  if (reference) return schemaAllowsNull(reference.schema, root, reference.seenRefs);
  if (schema?.nullable === true) return true;
  if (schemaTypes(schema).includes("null")) return true;
  for (const key of ["anyOf", "oneOf"]) {
    const variants = Array.isArray(schema[key]) ? schema[key] : [];
    if (variants.some((candidate) => candidate && typeof candidate === "object" && schemaAllowsNull(candidate, root, new Set(seenRefs)))) {
      return true;
    }
  }
  return false;
}

function validateStringConstraints(value, schema, path) {
  if (typeof value !== "string") return null;
  const length = [...value].length;
  if (Number.isInteger(schema.minLength) && length < schema.minLength) {
    return `Invalid value for ${path}: expected at least ${schema.minLength} character(s)`;
  }
  if (Number.isInteger(schema.maxLength) && length > schema.maxLength) {
    return `Invalid value for ${path}: expected at most ${schema.maxLength} character(s)`;
  }
  if (typeof schema.pattern === "string" && schema.pattern) {
    try {
      if (!new RegExp(schema.pattern).test(value)) {
        return `Invalid value for ${path}: expected to match pattern ${schema.pattern}`;
      }
    } catch {}
  }
  return null;
}

function validateNumberConstraints(value, schema, path) {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  if (typeof schema.minimum === "number" && value < schema.minimum) {
    return `Invalid value for ${path}: expected >= ${schema.minimum}`;
  }
  if (typeof schema.maximum === "number" && value > schema.maximum) {
    return `Invalid value for ${path}: expected <= ${schema.maximum}`;
  }
  if (typeof schema.exclusiveMinimum === "number" && value <= schema.exclusiveMinimum) {
    return `Invalid value for ${path}: expected > ${schema.exclusiveMinimum}`;
  }
  if (schema.exclusiveMinimum === true && typeof schema.minimum === "number" && value <= schema.minimum) {
    return `Invalid value for ${path}: expected > ${schema.minimum}`;
  }
  if (typeof schema.exclusiveMaximum === "number" && value >= schema.exclusiveMaximum) {
    return `Invalid value for ${path}: expected < ${schema.exclusiveMaximum}`;
  }
  if (schema.exclusiveMaximum === true && typeof schema.maximum === "number" && value >= schema.maximum) {
    return `Invalid value for ${path}: expected < ${schema.maximum}`;
  }
  if (typeof schema.multipleOf === "number" && schema.multipleOf > 0) {
    const quotient = value / schema.multipleOf;
    if (Math.abs(quotient - Math.round(quotient)) > Number.EPSILON * 100) {
      return `Invalid value for ${path}: expected a multiple of ${schema.multipleOf}`;
    }
  }
  return null;
}

function patternPropertySchemasForKey(schema, key) {
  if (!isRecord(schema.patternProperties)) return [];
  const output = [];
  for (const [pattern, patternSchema] of Object.entries(schema.patternProperties)) {
    if (!isRecord(patternSchema) && typeof patternSchema !== "boolean") continue;
    try {
      if (new RegExp(pattern).test(key)) output.push(patternSchema);
    } catch {}
  }
  return output;
}

function schemaEvaluatesObjectProperty(schema, key, rootSchema, value, seenRefs = new Set()) {
  schema = canonicalJsonSchema(schema);
  if (!schema || typeof schema !== "object" || Array.isArray(schema)) return false;
  const reference = schemaReferenceTarget(schema, rootSchema, seenRefs);
  if (reference) return schemaEvaluatesObjectProperty(reference.schema, key, rootSchema, value, reference.seenRefs);
  if (isRecord(schema.properties) && Object.prototype.hasOwnProperty.call(schema.properties, key)) return true;
  if (patternPropertySchemasForKey(schema, key).length > 0) return true;
  if (schema.additionalProperties === true || isRecord(schema.additionalProperties)) return true;
  if (isRecord(schema.dependentSchemas) && isRecord(value)) {
    for (const [dependency, dependentSchema] of Object.entries(schema.dependentSchemas)) {
      if (!Object.prototype.hasOwnProperty.call(value, dependency)) continue;
      if (schemaEvaluatesObjectProperty(dependentSchema, key, rootSchema, value, new Set(seenRefs))) return true;
    }
  }
  if (Array.isArray(schema.allOf)) {
    if (schema.allOf.some((candidate) => schemaEvaluatesObjectProperty(candidate, key, rootSchema, value, new Set(seenRefs)))) return true;
  }
  for (const keyword of ["anyOf", "oneOf"]) {
    if (!Array.isArray(schema[keyword])) continue;
    for (const candidate of schema[keyword]) {
      if (validateJsonSchemaValue(value, candidate, "$", rootSchema, new Set(seenRefs)) !== null) continue;
      if (schemaEvaluatesObjectProperty(candidate, key, rootSchema, value, new Set(seenRefs))) return true;
    }
  }
  if (isRecord(schema.if) || typeof schema.if === "boolean") {
    const matchesIf = validateJsonSchemaValue(value, schema.if, "$", rootSchema, new Set(seenRefs)) === null;
    if (matchesIf && schemaEvaluatesObjectProperty(schema.if, key, rootSchema, value, new Set(seenRefs))) return true;
    const branch = matchesIf ? schema.then : schema.else;
    if ((isRecord(branch) || typeof branch === "boolean")
        && schemaEvaluatesObjectProperty(branch, key, rootSchema, value, new Set(seenRefs))) {
      return true;
    }
  }
  return false;
}

function jsonValueMatchesType(value, type) {
  switch (type) {
    case "string":
      return typeof value === "string";
    case "number":
      return typeof value === "number" && Number.isFinite(value);
    case "integer":
      return Number.isInteger(value);
    case "boolean":
      return typeof value === "boolean";
    case "array":
      return Array.isArray(value);
    case "object":
      return isRecord(value);
    case "null":
      return value === null;
    default:
      return true;
  }
}

function jsonValuesEqual(left, right) {
  if (Object.is(left, right)) return true;
  return stableJson(left) === stableJson(right);
}

function clientMcpToolDefinitions(clientTools = []) {
  const pathProperty = { type: "string", description: "File or directory path for the outer client." };
  const fallbackTools = [
    {
      name: "client_write",
      description: "Forward a file write to the outer client.",
      inputSchema: {
        type: "object",
        properties: {
          path: pathProperty,
          fileText: { type: "string" }
        },
        required: ["path", "fileText"],
        additionalProperties: true
      }
    },
    {
      name: "client_shell",
      description: "Forward a shell command to the outer client. The bridge never executes it locally.",
      inputSchema: {
        type: "object",
        properties: {
          command: { type: "string" },
          workingDirectory: { type: "string" },
          timeout: { type: "number" }
        },
        required: ["command"],
        additionalProperties: true
      }
    },
    {
      name: "client_read",
      description: "Forward a file read to the outer client.",
      inputSchema: {
        type: "object",
        properties: {
          path: pathProperty,
          offset: { type: "number" },
          limit: { type: "number" }
        },
        required: ["path"],
        additionalProperties: true
      }
    },
    {
      name: "client_edit",
      description: "Forward a text replacement edit to the outer client.",
      inputSchema: {
        type: "object",
        properties: {
          path: pathProperty,
          oldString: { type: "string" },
          newString: { type: "string" }
        },
        required: ["path", "oldString", "newString"],
        additionalProperties: true
      }
    },
    {
      name: "client_delete",
      description: "Forward a file or directory delete to the outer client.",
      inputSchema: {
        type: "object",
        properties: { path: pathProperty },
        required: ["path"],
        additionalProperties: true
      }
    },
    {
      name: "client_glob",
      description: "Forward a glob file search to the outer client.",
      inputSchema: {
        type: "object",
        properties: {
          targetDirectory: { type: "string" },
          globPattern: { type: "string" }
        },
        required: ["globPattern"],
        additionalProperties: true
      }
    },
    {
      name: "client_grep",
      description: "Forward a text search to the outer client.",
      inputSchema: {
        type: "object",
        properties: {
          pattern: { type: "string" },
          path: { type: "string" },
          glob: { type: "string" }
        },
        required: ["pattern"],
        additionalProperties: true
      }
    },
    {
      name: "client_ls",
      description: "Forward a directory listing to the outer client.",
      inputSchema: {
        type: "object",
        properties: { path: { type: "string" } },
        additionalProperties: true
      }
    },
    {
      name: "client_read_lints",
      description: "Forward diagnostics/lint reads to the outer client.",
      inputSchema: {
        type: "object",
        properties: {
          paths: { type: "array", items: { type: "string" } }
        },
        required: ["paths"],
        additionalProperties: true
      }
    },
    {
      name: "client_sem_search",
      description: "Forward semantic code search to the outer client.",
      inputSchema: {
        type: "object",
        properties: {
          query: { type: "string" },
          targetDirectories: { type: "array", items: { type: "string" } }
        },
        required: ["query"],
        additionalProperties: true
      }
    },
    {
      name: "client_todo_write",
      description: "Forward todo list updates to the outer client.",
      inputSchema: {
        type: "object",
        properties: {
          todos: { type: "array", items: { type: "object", additionalProperties: true } }
        },
        required: ["todos"],
        additionalProperties: true
      }
    },
    {
      name: "client_task",
      description: "Forward a subagent/task request to the outer client.",
      inputSchema: {
        type: "object",
        properties: {
          description: { type: "string" },
          prompt: { type: "string" },
          subagentType: { anyOf: [{ type: "string" }, { type: "object", additionalProperties: true }] },
          model: { type: "string" },
          resume: { type: "string" },
          agentId: { type: "string" },
          attachments: { type: "array", items: { type: "string" } },
          mode: { type: "string" }
        },
        required: ["description", "prompt"],
        additionalProperties: true
      }
    },
    {
      name: "client_create_plan",
      description: "Forward a plan creation/update request to the outer client.",
      inputSchema: {
        type: "object",
        properties: {
          plan: { type: "string" },
          overview: { type: "string" },
          name: { type: "string" },
          todos: { type: "array", items: { type: "object", additionalProperties: true } },
          phases: { type: "array", items: { type: "object", additionalProperties: true } },
          isProject: { type: "boolean" }
        },
        additionalProperties: true
      }
    },
    {
      name: "client_generate_image",
      description: "Forward an image generation request to the outer client.",
      inputSchema: {
        type: "object",
        properties: {
          description: { type: "string" },
          filePath: pathProperty
        },
        required: ["description"],
        additionalProperties: true
      }
    },
    {
      name: "client_record_screen",
      description: "Forward a screen recording control request to the outer client.",
      inputSchema: {
        type: "object",
        properties: {
          mode: { type: "string", enum: ["START_RECORDING", "SAVE_RECORDING", "DISCARD_RECORDING"] }
        },
        required: ["mode"],
        additionalProperties: true
      }
    }
  ];
  const tools = [];
  const seen = new Set();
  for (const tool of clientTools) {
    if (!tool.name || seen.has(tool.name)) continue;
    seen.add(tool.name);
    tools.push({
      name: tool.name,
      description: tool.description || `Forward ${tool.name} to the outer client.`,
      inputSchema: clientMcpInputSchema(tool.parameters)
    });
  }
  for (const tool of fallbackTools) {
    if (seen.has(tool.name)) continue;
    seen.add(tool.name);
    tools.push(tool);
  }
  return tools;
}

function bridgePrompt(prompt, clientTools = []) {
  const mcpClientTools = clientToolsNeedingMcp(clientTools);
  const exactTools = clientTools
    .map((tool) => tool?.name)
    .filter((name) => typeof name === "string" && name.trim())
    .join(", ");
  const exactMcpTools = mcpClientTools
    .map((tool) => tool?.name)
    .filter((name) => typeof name === "string" && name.trim())
    .join(", ");
  const toolInstruction = exactTools
    ? `The outer client tools are: ${exactTools}.`
    : "No outer client tools were provided for this request.";
  const mcpInstruction = exactMcpTools
    ? `Client-only tools are exposed through the client MCP server by exact name: ${exactMcpTools}.`
    : "No client MCP forwarding tools are attached for this turn; answer without new local tool calls unless the prompt contains LOCAL TOOL RESULT records to continue from.";
  const localServerInstruction = exactMcpTools
    ? "A local MCP server named client exposes forwarding tools such as client_shell, client_write, client_read, client_edit, client_delete, client_glob, client_grep, and the exact outer client tool names."
    : "No local MCP server tools are available on this turn.";

  return [
    "You are running through the real Cursor SDK local runtime behind an OpenAI-compatible client.",
    "The outer client owns local tool execution. The bridge must forward local operations; it must not execute SDK built-in shell/read/write/edit/glob/grep/ls/delete tools inside the bridge runtime.",
    toolInstruction,
    mcpInstruction,
    localServerInstruction,
    "Prefer exact client tools and dedicated client MCP tools such as write, read, edit, glob, grep, ls, delete, client_write, client_read, client_edit, client_glob, client_grep, client_ls, and client_delete before bash/client_shell. Use shell only for commands or when no dedicated client tool fits.",
    "Use SDK mcp with providerIdentifier \"client\" for every local operation. Do not use SDK built-in shell, write, edit, read, glob, grep, ls, delete, readLints, semSearch, todowrite, task, createPlan, generateImage, or recordScreen.",
    "If the prompt says LOCAL TOOL REQUIRED, emit exactly one client MCP forwarding tool call and no prose.",
    "If LOCAL TOOL RESULT records are present, treat those tools as already executed by the outer client and continue from the result.",
    "",
    prompt
  ].join("\n");
}

function toolCallFromDelta(update) {
  if (!update || typeof update !== "object") return null;
  if (update.type !== "tool-call-started") return null;
  const toolCall = update.toolCall;
  if (!toolCall || typeof toolCall !== "object") return null;
  return toolCall;
}

function normalizeSDKToolCall(toolCall, clientTools = []) {
  const name = typeof toolCall.type === "string" ? toolCall.type : typeof toolCall.name === "string" ? toolCall.name : "";
  if (!name) return null;
  const args = objectArgumentFrom(toolCall, "args", "arguments", "input", "parameters", "params");
  const clientMcpTool = normalizeClientMcpToolCall(name, args);
  if (clientMcpTool) return clientMcpTool;
  const directClientTool = normalizeDirectClientToolCall(name, args, clientTools);
  if (directClientTool) return directClientTool;
  return {
    name,
    arguments: normalizeArguments(args)
  };
}

function normalizeClientMcpToolCall(name, args) {
  if (canonicalToolName(name) !== "mcp") return null;
  const provider = firstString(args, "providerIdentifier", "provider", "server", "serverName", "server_name");
  if (provider && provider !== clientMcpServerName) return null;
  const toolName = firstString(args, "toolName", "tool_name", "tool", "name");
  const sdkName = sdkToolNameFromClientMcpTool(toolName);
  const payload = clientMcpPayloadArguments(args);
  if (!sdkName) {
    return {
      name: "mcp",
      arguments: {
        providerIdentifier: clientMcpServerName,
        toolName,
        args: normalizeArguments(payload)
      }
    };
  }
  return {
    name: sdkName,
    arguments: normalizeArguments(payload)
  };
}

function normalizeDirectClientToolCall(name, args, clientTools = []) {
  const sdkName = sdkToolNameFromClientMcpTool(name);
  const normalizedName = normalizeToolName(name);
  const matchingClientTool = clientTools.find((tool) => normalizeToolName(tool.name) === normalizedName);
  if (sdkName && (normalizedName.startsWith("client") || matchingClientTool)) {
    return {
      name: sdkName,
      arguments: normalizeArguments(args)
    };
  }
  if (!matchingClientTool) return null;
  return {
    name: "mcp",
    arguments: {
      providerIdentifier: clientMcpServerName,
      toolName: matchingClientTool.name,
      args: normalizeArguments(args)
    }
  };
}

function sdkToolNameFromClientMcpTool(toolName) {
  const normalized = normalizeToolName(toolName).replace(/^client/, "");
  switch (normalized) {
    case "shell":
    case "bash":
    case "run":
    case "runcommand":
      return "shell";
    case "write":
    case "writefile":
      return "write";
    case "read":
    case "readfile":
      return "read";
    case "edit":
    case "editfile":
      return "edit";
    case "delete":
    case "deletefile":
    case "remove":
    case "removefile":
      return "delete";
    case "glob":
    case "fileglob":
      return "glob";
    case "grep":
    case "search":
      return "grep";
    case "ls":
    case "list":
    case "listfiles":
      return "ls";
    case "readlints":
    case "diagnostics":
      return "readLints";
    case "semsearch":
    case "semanticsearch":
      return "semSearch";
    case "todowrite":
    case "todos":
    case "updatetodos":
      return "todowrite";
    case "task":
    case "subagent":
    case "subagenttask":
      return "task";
    case "createplan":
      return "createPlan";
    case "generateimage":
    case "imagegeneration":
    case "imagegen":
      return "generateImage";
    case "recordscreen":
    case "screenrecord":
    case "screenrecording":
      return "recordScreen";
    default:
      return null;
  }
}

function isForwardableSDKToolCall(toolCall, clientTools = []) {
  const args = toolCall.arguments || {};
  if (matchingClientToolByName(toolCall.name, clientTools)) {
    return clientToolPayloadIsComplete(toolCall.name, args, clientTools);
  }
  switch (canonicalToolName(toolCall.name)) {
    case "shell":
      return hasString(args, "command");
    case "write":
      return hasString(args, "path", "filePath", "targetFile")
        && hasStringAllowEmpty(args, "fileText", "content", "contents", "text", "data");
    case "edit":
      return hasString(args, "path", "filePath", "targetFile")
        && (
          hasStringAllowEmpty(args, "patchContent", "patch_content", "streamContent", "stream_content")
          || (hasStringAllowEmpty(args, "oldText", "oldString", "old_str") && hasStringAllowEmpty(args, "newText", "newString", "replacement"))
        );
    case "delete":
    case "read":
      return hasString(args, "path", "filePath", "targetFile");
    case "glob":
      return hasString(args, "globPattern", "glob_pattern", "pattern", "fileGlob", "file_glob", "includePattern", "include_pattern", "glob")
        || hasGlobString(args, "targetDirectory", "target_directory", "targeting", "path", "directory", "dir", "root", "basePath", "base_path");
    case "grep":
      return hasString(args, "pattern", "query");
    case "ls":
      return true;
    case "mcp":
      if (!hasString(args, "providerIdentifier", "provider", "server")
          || !hasString(args, "toolName", "tool", "name")) {
        return false;
      }
      return mcpClientToolPayloadIsComplete(args, clientTools);
    case "readlints":
      return hasStringOrStringArray(args, "paths", "files", "filePaths", "file_paths", "path", "file_path", "filePath", "filename", "file");
    case "semsearch":
      return hasString(args, "query", "pattern", "search", "searchQuery", "search_query", "semanticQuery", "semantic_query", "prompt");
    case "todowrite":
      return hasArray(args, "todos", "todoList", "todo_list", "todoItems", "todo_items", "items", "tasks", "taskList", "task_list");
    case "task":
      return hasString(args, "description", "desc", "summary")
        && hasString(args, "prompt", "instructions", "input", "query");
    case "createplan":
      return hasString(args, "plan", "overview", "name", "title", "description")
        || hasArray(args, "todos", "todoList", "todo_list", "todoItems", "todo_items", "items", "tasks", "taskList", "task_list", "phases");
    case "generateimage":
      return hasString(args, "description", "desc", "summary", "prompt", "input", "query");
    case "recordscreen":
      return hasString(args, "mode", "action", "operation", "op");
    default:
      return false;
  }
}

function clientToolPayloadIsComplete(toolName, payload, clientTools = []) {
  const tool = matchingClientToolByName(toolName, clientTools);
  if (!tool) return true;
  const schema = clientMcpInputSchema(tool.parameters);
  return validateJsonSchemaValue(payload, schema, tool.name, schema) === null;
}

function mcpClientToolPayloadIsComplete(args, clientTools = []) {
  const tool = matchingClientToolForMcpCall(args, clientTools);
  if (tool) {
    const payload = clientMcpPayloadArguments(args);
    const schema = clientMcpInputSchema(tool.parameters);
    return validateJsonSchemaValue(payload, schema, tool.name, schema) === null;
  }
  const wrapper = matchingClientMcpWrapperTool(args, clientTools);
  if (!wrapper) return false;
  const schema = clientMcpInputSchema(wrapper.parameters);
  const wrapperArgs = clientMcpWrapperArguments(args, schema);
  if (!wrapperArgs) return false;
  if (validateJsonSchemaValue(wrapperArgs, schema, wrapper.name, schema) === null) return true;
  return mcpWrapperPayloadLooksComplete(args);
}

function matchingClientToolByName(toolName, clientTools = []) {
  const normalized = normalizeToolName(toolName);
  return clientTools.find((tool) => normalizeToolName(tool?.name) === normalized) || null;
}

function matchingClientToolForMcpCall(args, clientTools = []) {
  const provider = firstString(args, "providerIdentifier", "provider_identifier", "provider", "server", "serverName", "server_name");
  const toolName = firstString(args, "toolName", "tool_name", "tool", "name");
  if (!toolName) return null;
  const candidates = new Set([toolName]);
  for (const variant of mcpProviderNameVariants(provider)) {
    candidates.add(`${variant}__${toolName}`);
    candidates.add(`${variant}_${toolName}`);
    candidates.add(`mcp__${variant}__${toolName}`);
    candidates.add(`mcp_${variant}_${toolName}`);
  }
  const normalizedCandidates = new Set([...candidates].map(normalizeToolName));
  return clientTools.find((tool) => normalizedCandidates.has(normalizeToolName(tool?.name))) || null;
}

function matchingClientMcpWrapperTool(args, clientTools = []) {
  const provider = firstString(args, "providerIdentifier", "provider_identifier", "provider", "server", "serverName", "server_name");
  const toolName = firstString(args, "toolName", "tool_name", "tool", "name");
  if (!provider || !toolName) return null;
  return clientTools.find((tool) => clientToolLooksLikeMcpWrapper(tool)) || null;
}

function clientToolLooksLikeMcpWrapper(tool) {
  if (!tool || typeof tool.name !== "string") return false;
  const schema = clientMcpInputSchema(tool.parameters);
  const properties = isRecord(schema.properties) ? Object.keys(schema.properties) : [];
  return Boolean(
    schemaPropertyName(properties, mcpProviderKeys())
    && schemaPropertyName(properties, mcpToolNameKeys())
    && schemaPropertyName(properties, mcpPayloadKeys())
  );
}

function clientMcpWrapperArguments(args, schema) {
  const properties = isRecord(schema.properties) ? Object.keys(schema.properties) : [];
  const providerKey = schemaPropertyName(properties, mcpProviderKeys());
  const toolKey = schemaPropertyName(properties, mcpToolNameKeys());
  const payloadKey = schemaPropertyName(properties, mcpPayloadKeys());
  if (!providerKey || !toolKey || !payloadKey) return null;
  const provider = firstString(args, ...mcpProviderKeys());
  const toolName = firstString(args, ...mcpToolNameKeys());
  if (!provider || !toolName) return null;
  return {
    [providerKey]: provider,
    [toolKey]: toolName,
    [payloadKey]: clientMcpPayloadArguments(args)
  };
}

function mcpWrapperPayloadLooksComplete(args) {
  const toolName = canonicalToolName(firstString(args, ...mcpToolNameKeys()));
  const payload = clientMcpPayloadArguments(args);
  switch (toolName) {
    case "write":
    case "writefile":
    case "create":
    case "createfile":
    case "overwrite":
    case "overwritefile":
      return hasString(payload, "path", "filePath", "file_path", "targetFile", "target_file")
        && hasStringAllowEmpty(payload, "fileText", "file_text", "content", "contents", "text", "data");
    case "edit":
    case "editfile":
    case "replace":
    case "replacefile":
    case "strreplace":
    case "strreplacefile":
      return hasString(payload, "path", "filePath", "file_path", "targetFile", "target_file")
        && (
          hasStringAllowEmpty(payload, "patchContent", "patch_content", "streamContent", "stream_content")
          || (
            hasStringAllowEmpty(payload, "oldText", "old_text", "oldString", "old_string", "old_str")
            && hasStringAllowEmpty(payload, "newText", "new_text", "newString", "new_string", "replacement")
          )
        );
    case "read":
    case "readfile":
    case "open":
    case "openfile":
    case "delete":
    case "deletefile":
    case "remove":
    case "removefile":
      return hasString(payload, "path", "filePath", "file_path", "targetFile", "target_file");
    case "run":
    case "runcommand":
    case "shell":
    case "bash":
      return hasString(payload, "command", "cmd", "script", "input");
    case "glob":
    case "fileglob":
    case "find":
    case "findfile":
    case "findfiles":
      return hasString(payload, "globPattern", "glob_pattern", "pattern", "fileGlob", "file_glob", "includePattern", "include_pattern", "glob")
        || hasGlobString(payload, "targetDirectory", "target_directory", "targeting", "path", "directory", "dir", "root", "basePath", "base_path");
    case "grep":
    case "search":
    case "query":
      return hasString(payload, "pattern", "query", "search", "regex");
    case "task":
    case "subagent":
    case "subagenttask":
      return hasString(payload, "description", "desc", "summary")
        && hasString(payload, "prompt", "instructions", "input", "query");
    case "createplan":
    case "plan":
    case "planupdate":
    case "setplan":
      return hasString(payload, "plan", "overview", "name", "title", "description")
        || hasArray(payload, "todos", "todoList", "todo_list", "todoItems", "todo_items", "items", "tasks", "taskList", "task_list", "phases");
    case "generateimage":
    case "imagegeneration":
    case "imagegen":
      return hasString(payload, "description", "desc", "summary", "prompt", "input", "query");
    case "recordscreen":
    case "screenrecord":
    case "screenrecording":
      return hasString(payload, "mode", "action", "operation", "op");
    default:
      return false;
  }
}

function schemaPropertyName(properties, keys) {
  const normalizedKeys = new Set(keys.map(normalizeToolName));
  return properties.find((property) => normalizedKeys.has(normalizeToolName(property))) || "";
}

function mcpProviderKeys() {
  return ["providerIdentifier", "provider_identifier", "provider", "server", "serverName", "server_name"];
}

function mcpToolNameKeys() {
  return ["toolName", "tool_name", "tool", "name"];
}

function mcpPayloadKeys() {
  return ["args", "arguments", "input", "parameters", "params", "payload", "data"];
}

function mcpProviderNameVariants(provider) {
  const trimmed = typeof provider === "string" ? provider.trim() : "";
  if (!trimmed) return [];
  const output = [];
  const append = (value) => {
    const candidate = String(value || "").trim();
    if (candidate && !output.includes(candidate)) output.push(candidate);
  };
  append(trimmed);
  for (const separator of [":", "/", "\\", "."]) {
    const pieces = trimmed.split(separator).filter(Boolean);
    if (pieces.length) append(pieces[pieces.length - 1]);
  }
  for (const prefix of ["mcp__", "mcp_", "mcp-", "mcp:"]) {
    if (trimmed.toLowerCase().startsWith(prefix)) append(trimmed.slice(prefix.length));
  }
  return output;
}

function canonicalToolName(name) {
  return String(name || "").replace(/[^A-Za-z0-9]/g, "").toLowerCase();
}

function normalizeToolName(name) {
  return canonicalToolName(name);
}

function hasString(args, ...keys) {
  return keys.some((key) => typeof args[key] === "string" && args[key].trim().length > 0);
}

function firstString(args, ...keys) {
  for (const key of keys) {
    if (typeof args[key] === "string" && args[key].trim()) return args[key].trim();
  }
  return "";
}

function firstMatchingKey(source, ...keys) {
  if (!isRecord(source)) return "";
  for (const key of keys) {
    if (Object.prototype.hasOwnProperty.call(source, key)) return key;
  }
  const normalizedKeys = new Set(keys.map(normalizeToolName));
  for (const key of Object.keys(source)) {
    if (normalizedKeys.has(normalizeToolName(key))) return key;
  }
  return "";
}

function hasStringAllowEmpty(args, ...keys) {
  return keys.some((key) => typeof args[key] === "string");
}

function hasArray(args, ...keys) {
  return keys.some((key) => Array.isArray(args[key]));
}

function hasStringOrStringArray(args, ...keys) {
  return keys.some((key) => {
    const value = args[key];
    if (typeof value === "string") return value.trim().length > 0;
    return Array.isArray(value) && value.some((item) => typeof item === "string" && item.trim().length > 0);
  });
}

function hasGlobString(args, ...keys) {
  return keys.some((key) => typeof args[key] === "string" && /[*?[\]{}]/.test(args[key]));
}

function normalizeArguments(args) {
  const output = {};
  for (const [key, value] of Object.entries(args)) {
    if (value === undefined || typeof value === "function" || typeof value === "symbol") continue;
    output[key] = normalizeJsonValue(value);
  }
  return output;
}

function objectArgumentFrom(source, ...keys) {
  if (!isRecord(source)) return {};
  for (const key of keys) {
    const value = source[key];
    if (isRecord(value)) return value;
    if (typeof value === "string") {
      const parsed = parseJsonObject(value);
      if (parsed) return parsed;
    }
  }
  const normalizedKeys = new Set(keys.map(normalizeToolName));
  for (const [key, value] of Object.entries(source)) {
    if (!normalizedKeys.has(normalizeToolName(key))) continue;
    if (isRecord(value)) return value;
    if (typeof value === "string") {
      const parsed = parseJsonObject(value);
      if (parsed) return parsed;
    }
  }
  return {};
}

function objectArgumentEntryFrom(source, ...keys) {
  if (!isRecord(source)) return null;
  for (const key of keys) {
    const value = source[key];
    if (isRecord(value)) return { key, value };
    if (typeof value === "string") {
      const parsed = parseJsonObject(value);
      if (parsed) return { key, value: parsed };
    }
  }
  const normalizedKeys = new Set(keys.map(normalizeToolName));
  for (const [key, value] of Object.entries(source)) {
    if (!normalizedKeys.has(normalizeToolName(key))) continue;
    if (isRecord(value)) return { key, value };
    if (typeof value === "string") {
      const parsed = parseJsonObject(value);
      if (parsed) return { key, value: parsed };
    }
  }
  return null;
}

function clientMcpPayloadArguments(args) {
  const envelope = objectArgumentEntryFrom(args, "args", "arguments", "input", "parameters", "params", "payload", "data");
  if (envelope && Object.keys(envelope.value).length > 0) return envelope.value;
  if (!isRecord(args)) return {};
  const providerKey = firstMatchingKey(args, "providerIdentifier", "provider", "server", "serverName", "server_name");
  const toolKey = firstMatchingKey(args, "toolName", "tool_name", "tool", "name");
  const output = {};
  for (const [key, value] of Object.entries(args)) {
    if (key === providerKey || key === toolKey || key === envelope?.key) continue;
    output[key] = value;
  }
  return output;
}

function parseJsonObject(value) {
  const trimmed = value.trim();
  if (!trimmed.startsWith("{")) return null;
  try {
    const parsed = JSON.parse(trimmed);
    return isRecord(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function normalizeJsonValue(value) {
  if (value === null || typeof value === "string" || typeof value === "number" || typeof value === "boolean") return value;
  if (Array.isArray(value)) return value.map(normalizeJsonValue);
  if (typeof value === "object") return normalizeArguments(value);
  return String(value);
}

function clientMcpInputSchema(parameters) {
  if (isRecord(parameters) && Object.keys(parameters).length > 0) {
    return canonicalJsonSchema(normalizeJsonValue(parameters));
  }
  return {
    type: "object",
    additionalProperties: true
  };
}

function agentCacheKey(input) {
  const digest = crypto
    .createHash("sha256")
    .update([input.apiKey, input.model, input.workingDirectory, input.sessionKey].join("\0"))
    .digest("hex")
    .slice(0, 32);
  return digest;
}

function evictAgents() {
  while (agentCache.size > maxAgents) {
    const oldest = [...agentCache.entries()].sort((a, b) => a[1].touchedAt - b[1].touchedAt)[0];
    if (!oldest) return;
    agentCache.delete(oldest[0]);
    forceNextRunAgentKeys.delete(oldest[0]);
    try {
      oldest[1].agent.close();
    } catch {}
  }
}

function normalizeModel(model) {
  const raw = model.trim();
  const normalized = raw.toLowerCase().split("/").filter(Boolean).at(-1) || "";
  if (!normalized || normalized === "default" || normalized === "auto") return "default";
  if (normalized === "composer-latest" || normalized === "composer" || normalized === "composer-2.5" || normalized === "composer-2-5") {
    return "composer-2.5";
  }
  if (normalized === "composer-2.5-sdk" || normalized === "composer-2-5-sdk") return "composer-2.5";
  if (normalized === "composer-2.5-fast" || normalized === "composer-2-5-fast") return "composer-2.5-fast";
  return raw;
}

function sdkModelSelection(model) {
  const normalized = normalizeModel(typeof model === "string" ? model : "");
  if (normalized === "composer-2.5") return { id: "composer-2.5", params: [{ id: "fast", value: "false" }] };
  if (normalized === "composer-2.5-fast") return { id: "composer-2.5", params: [{ id: "fast", value: "true" }] };
  return { id: normalized };
}

function sdkWorkingDirectory(value) {
  const trimmed = typeof value === "string" ? value.trim() : "";
  if (!trimmed || trimmed.toLowerCase() === "undefined" || trimmed.toLowerCase() === "null") return defaultCwd;
  return trimmed;
}

function stripFinalMarker(text) {
  return text.replace(/\s*<\/?(?:final_answer|answer)>\s*$/gi, "").trim();
}

function requiredString(value, key) {
  if (typeof value !== "string" || !value.trim()) {
    throw new HttpError(`Missing ${key}`, 400, "invalid_request");
  }
  return value;
}

function parseClientTools(value) {
  if (!Array.isArray(value)) return [];
  return value.flatMap((tool) => {
    if (!isRecord(tool) || typeof tool.name !== "string" || !tool.name.trim()) return [];
    const description = typeof tool.description === "string" ? tool.description : undefined;
    const parameters = isJsonSerializable(tool.parameters) ? tool.parameters : undefined;
    return [{
      name: tool.name.trim(),
      ...(description ? { description } : {}),
      ...(parameters !== undefined ? { parameters: normalizeJsonValue(parameters) } : {})
    }];
  });
}

async function readJsonBody(request) {
  let body = "";
  for await (const chunk of request) {
    body += chunk;
    if (body.length > maxJsonBytes) throw new HttpError("Request body too large", 413, "request_too_large");
  }
  if (!body.trim()) return {};
  try {
    return JSON.parse(body);
  } catch {
    throw new HttpError("Invalid JSON", 400, "invalid_json");
  }
}

function writeJson(response, body, status = 200) {
  const data = Buffer.from(JSON.stringify(body));
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": String(data.length),
    "Cache-Control": "no-cache, no-transform",
    "Access-Control-Allow-Origin": "*"
  });
  response.end(data);
}

function writeNdjson(response, body) {
  if (response.writableEnded || response.destroyed) return false;
  try {
    response.write(`${JSON.stringify(body)}\n`);
    return true;
  } catch (error) {
    if (error?.code === "EPIPE" || error?.code === "ERR_STREAM_DESTROYED") {
      return false;
    }
    throw error;
  }
}

function installBridgeProcessHandlers() {
  process.on("unhandledRejection", (reason) => {
    if (isBenignCancellationError(reason) || isBenignPipeError(reason)) return;
    if (isRetryableSDKRunError(reason)) {
      console.warn("Ignored late retryable Cursor SDK upstream error.");
      return;
    }
    console.error(reason);
    closeAndExit(1);
  });
  process.on("uncaughtException", (error) => {
    if (isBenignCancellationError(error) || isBenignPipeError(error)) return;
    if (isRetryableSDKRunError(error)) {
      console.warn("Ignored late retryable Cursor SDK upstream error.");
      return;
    }
    console.error(error);
    closeAndExit(1);
  });
}

function isBenignCancellationError(error) {
  return error?.name === "AbortError" || error?.code === "ABORT_ERR";
}

function isBenignPipeError(error) {
  return error?.code === "EPIPE" || error?.code === "ERR_STREAM_DESTROYED";
}

function isRetryableSDKRunError(error) {
  const values = flattenErrorValues(error);
  if (values.some((value) => value?.isRetryable === true)) return true;
  if (values.some((value) => value?.status === 429 || value?.status === 503 || value?.code === 8 || value?.code === 14)) return true;
  return values
    .flatMap((value) => [value?.message, value?.rawMessage, value?.code, value?.status, value?.name])
    .filter((value) => value !== undefined && value !== null)
    .map((value) => String(value).toLowerCase())
    .some((text) =>
      text.includes("server at capacity")
        || text.includes("temporarily unavailable")
        || text.includes("resource exhausted")
        || text.includes("rate limit")
        || text.includes("too many requests")
        || text.includes("try again")
        || text === "unavailable"
        || text === "resource_exhausted"
    );
}

function sdkRunFailureError(result) {
  const summary = sdkRunFailureSummary(result);
  const error = new HttpError(
    summary.message || "Cursor SDK run failed",
    summary.retryable ? 503 : 502,
    "cursor_sdk_error"
  );
  error.rawMessage = summary.message;
  error.isRetryable = summary.retryable;
  error.cause = summary;
  console.warn(`Cursor SDK run returned error status${summary.code ? ` (${summary.code})` : ""}.`);
  return error;
}

function sdkRunFailureSummary(result) {
  const source = firstRecord(result?.error, result?.cause, result?.details, result?.result);
  const message = firstNonEmptyString(
    source?.message,
    source?.rawMessage,
    source?.error,
    source?.details,
    typeof result?.result === "string" ? result.result : undefined
  );
  const code = firstNonEmptyString(source?.code, result?.code);
  return {
    status: result?.status,
    code,
    message,
    retryable: isRetryableSDKRunError(source) || (!message && !code)
  };
}

function firstRecord(...values) {
  return values.find((value) => isRecord(value)) || {};
}

function firstNonEmptyString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return "";
}

function flattenErrorValues(error) {
  const values = [];
  const seen = new Set();
  let current = error;
  while (current && !seen.has(current)) {
    values.push(current);
    seen.add(current);
    current = current.cause;
  }
  return values;
}

function retryDelayMs(attempt) {
  return Math.min(5000, retryBaseDelayMs * 2 ** attempt);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function openAiError(error) {
  const status = statusFromError(error);
  const message = messageFromError(error, status);
  const code = codeFromError(error, status);
  return {
    error: {
      message,
      type: error?.type || (status >= 500 ? "api_error" : "invalid_request_error"),
      code,
      status
    }
  };
}

function statusFromError(error) {
  for (const value of flattenErrorValues(error)) {
    const status = parseHTTPStatus(value?.status);
    if (status) return status;
  }
  if (isAuthenticationSDKError(error)) return 401;
  if (isRetryableSDKRunError(error)) return 503;
  return 500;
}

function messageFromError(error, status) {
  if (status === 401 && isAuthenticationSDKError(error)) {
    return "Missing or invalid authorization";
  }
  const message = firstNonEmptyString(
    error?.message,
    error?.rawMessage,
    error?.error,
    error?.details
  );
  if (message && message !== "Error") return message;
  if (status === 401) return "Missing or invalid authorization";
  return message || "Cursor SDK request failed";
}

function codeFromError(error, status) {
  if (status === 401 && isAuthenticationSDKError(error)) return "unauthorized";
  const code = firstNonEmptyString(error?.code, error?.cause?.code);
  if (code && !(status === 401 && code === "internal")) return code;
  if (status === 401) return "unauthorized";
  if (status === 503) return "cursor_sdk_unavailable";
  return code || "cursor_sdk_error";
}

function isAuthenticationSDKError(error) {
  return flattenErrorValues(error).some((value) => {
    const name = String(value?.name || "").toLowerCase();
    const code = String(value?.code || "").toLowerCase();
    const message = String(value?.message || value?.rawMessage || "").toLowerCase();
    const status = parseHTTPStatus(value?.status);
    return status === 401
      || name.includes("authentication")
      || code === "unauthorized"
      || code === "authentication_error"
      || message.includes("missing or invalid authorization")
      || message.includes("invalid authorization")
      || message.includes("unauthorized");
  });
}

function parseHTTPStatus(value) {
  if (Number.isInteger(value) && value >= 100 && value <= 599) return value;
  if (typeof value === "string" && /^\d{3}$/.test(value.trim())) {
    const parsed = Number.parseInt(value, 10);
    if (parsed >= 100 && parsed <= 599) return parsed;
  }
  return 0;
}

class HttpError extends Error {
  constructor(message, status = 500, code = "api_error") {
    super(message);
    this.status = status;
    this.code = code;
    this.type = status >= 500 ? "api_error" : "invalid_request_error";
  }
}

function bearerToken(request) {
  const value = request.headers.authorization || "";
  const [scheme, token] = value.split(/\s+/, 2);
  return scheme?.toLowerCase() === "bearer" ? token || "" : "";
}

function parseInteger(value, fallback) {
  const parsed = Number.parseInt(String(value || ""), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function isRecord(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function isJsonSerializable(value) {
  return value === null || ["string", "number", "boolean"].includes(typeof value) || Array.isArray(value) || isRecord(value);
}

function stableJson(value) {
  return JSON.stringify(sortJson(value));
}

function sortJson(value) {
  if (Array.isArray(value)) return value.map(sortJson);
  if (!isRecord(value)) return value;
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortJson(value[key])]));
}

function loadEnvFile(filePath) {
  if (!existsSync(filePath)) return;
  for (const line of readFileSync(filePath, "utf8").split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const normalized = trimmed.startsWith("export ") ? trimmed.slice(7).trim() : trimmed;
    const equals = normalized.indexOf("=");
    if (equals <= 0) continue;
    const key = normalized.slice(0, equals).trim();
    let value = normalized.slice(equals + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (!process.env[key]) process.env[key] = value;
  }
}

async function closeAndExit(code) {
  for (const entry of agentCache.values()) {
    try {
      entry.agent.close();
    } catch {}
  }
  server?.close(() => process.exit(code));
  setTimeout(() => process.exit(code), 500).unref();
}

function isMainModule() {
  return process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
}
