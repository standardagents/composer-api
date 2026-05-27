#!/usr/bin/env node
import { Agent } from "@cursor/sdk";
import crypto from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import http from "node:http";
import path from "node:path";
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
const defaultCwd = process.env.CURSOR_SDK_WORKING_DIRECTORY || process.cwd();
const clientMcpServerName = "client";

const agentCache = new Map();
let server = null;

if (isMainModule()) {
  startServer();
  process.on("SIGINT", () => closeAndExit(0));
  process.on("SIGTERM", () => closeAndExit(0));
}

export {
  bridgePrompt,
  clientMcpToolDefinitions,
  clientForwardingMcpServerSource,
  localAgentCreateOptions,
  localAgentSendOptions,
  isForwardableSDKToolCall,
  normalizeSDKToolCall,
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
  const model = normalizeModel(typeof body.model === "string" ? body.model : "");
  const sessionKey = typeof body.sessionKey === "string" && body.sessionKey ? body.sessionKey : crypto.randomUUID();
  const workingDirectory = sdkWorkingDirectory(body.workingDirectory);
  const requestId = typeof body.requestId === "string" && body.requestId ? body.requestId : crypto.randomUUID();
  const clientTools = parseClientTools(body.tools);
  const streamEvents = body.streamEvents === true;

  const input = {
    apiKey,
    model,
    prompt: bridgePrompt(prompt),
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

async function streamLocalAgent(input, response) {
  let closed = false;
  const markClosed = () => {
    closed = true;
  };
  response.on("close", markClosed);
  response.on("error", markClosed);
  response.socket?.on?.("error", markClosed);
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
    if (!response.writableEnded && !response.destroyed) {
      response.end();
    }
  }
}

async function runLocalAgent(input, onEvent) {
  let activeRun = null;
  let timer = null;
  const work = runLocalAgentBody(input, (run) => {
    activeRun = run;
  }, onEvent);
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
  } finally {
    if (timer) clearTimeout(timer);
    work.catch(() => {});
  }
}

async function runLocalAgentBody(input, onRun, onEvent) {
  const agentEntry = await getAgent(input);
  const agent = agentEntry.agent;
  let run;
  let capturedToolCall = null;
  let cancelRequested = false;
  let text = "";

  const captureToolCall = async (toolCall) => {
    if (capturedToolCall || !toolCall) return;
    const normalized = normalizeSDKToolCall(toolCall, input.clientTools);
    if (!normalized || !isForwardableSDKToolCall(normalized)) return;
    capturedToolCall = normalized;
    if (onEvent) onEvent({ type: "tool_call", toolCall: capturedToolCall });
    cancelRequested = true;
    if (run) {
      try {
        await run.cancel();
      } catch {
        // The SDK may already be finishing the local run. The captured model
        // tool call is still the response we need to return to the client.
      }
    }
  };

  run = await agent.send(input.prompt, {
    ...localAgentSendOptions(input),
    idempotencyKey: input.requestId,
    onDelta: async ({ update }) => {
      const toolCall = toolCallFromDelta(update);
      if (toolCall) await captureToolCall(toolCall);
    }
  });
  onRun(run);

  if (cancelRequested) {
    try {
      await run.cancel();
    } catch {}
  }

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
      await captureToolCall({ type: event.name, args: event.args });
      if (capturedToolCall) break;
    }
  }

  if (capturedToolCall) {
    evictAgent(agentEntry.cacheKey, agent);
    return {
      text: "",
      toolCalls: [capturedToolCall],
      agentID: agent.agentId,
      runID: run.id,
      status: "tool_call"
    };
  }

  const result = await run.wait();
  if (result.status === "error") {
    evictAgent(agentEntry.cacheKey, agent);
    throw new HttpError("Cursor SDK run failed", 502, "cursor_sdk_error");
  }
  if (!text && typeof result.result === "string") text = result.result;
  return {
    text: stripFinalMarker(text),
    toolCalls: [],
    agentID: agent.agentId,
    runID: run.id,
    status: result.status
  };
}

async function getAgent(input) {
  const cacheKey = agentCacheKey(input);
  const cached = agentCache.get(cacheKey);
  if (cached) {
    cached.touchedAt = Date.now();
    return { agent: cached.agent, cacheKey };
  }

  const agent = await Agent.create(localAgentCreateOptions(input));
  agentCache.set(cacheKey, { agent, touchedAt: Date.now() });
  evictAgents();
  return { agent, cacheKey };
}

function evictAgent(cacheKey, agent) {
  const cached = agentCache.get(cacheKey);
  if (cached?.agent === agent) {
    agentCache.delete(cacheKey);
  }
  try {
    agent.close();
  } catch {}
}

function localAgentCreateOptions(input) {
  return {
    apiKey: input.apiKey,
    model: { id: input.model },
    name: "API for Cursor local bridge",
    mcpServers: clientForwardingMcpServers(input.clientTools),
    local: {
      cwd: input.workingDirectory
    }
  };
}

function localAgentSendOptions(input) {
  return {
    model: { id: input.model }
  };
}

function clientForwardingMcpServers(clientTools = []) {
  return {
    [clientMcpServerName]: {
      type: "stdio",
      command: process.execPath,
      args: ["-e", clientForwardingMcpServerSource(clientTools)]
    }
  };
}

function clientForwardingMcpServerSource(clientTools = []) {
  const tools = JSON.stringify(clientMcpToolDefinitions(clientTools));
  return `
const readline = require("node:readline");
const tools = ${tools};
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
function send(id, result) {
  if (id === undefined || id === null) return;
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n");
}
function sendError(id, message) {
  if (id === undefined || id === null) return;
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32000, message } }) + "\\n");
}
rl.on("line", (line) => {
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
  const tools = [
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
    }
  ];
  const seen = new Set(tools.map((tool) => tool.name));
  for (const tool of clientTools) {
    if (!tool.name || seen.has(tool.name)) continue;
    seen.add(tool.name);
    tools.push({
      name: tool.name,
      description: tool.description || `Forward ${tool.name} to the outer client.`,
      inputSchema: clientMcpInputSchema(tool.parameters)
    });
  }
  return tools;
}

function bridgePrompt(prompt) {
  return [
    "You are running through the real Cursor SDK local runtime behind an OpenAI-compatible client.",
    "The outer client owns local tool execution. When local work is needed, emit exactly one SDK tool call, then stop.",
    "A local MCP server named client exposes forwarding tools: client_shell, client_write, client_read, client_edit, client_delete, client_glob, client_grep, client_ls, client_read_lints, client_sem_search, and client_todo_write.",
    "The same client MCP server also exposes the current harness tools by exact tool name when the outer client provided a tool schema.",
    "Use those client MCP forwarding tools for every local operation. Do not use the SDK built-in shell, write, edit, read, glob, grep, ls, delete, readLints, semSearch, or todowrite tools because those execute inside the bridge instead of the outer client.",
    "If the request below mentions an SDK routing map or asks for SDK mcp, satisfy that by calling the matching client MCP forwarding tool.",
    "For file creation, file edits, deletes, package installs, tests, builds, and project scaffolds, use client_shell or the exact harness shell tool with a complete command. Include mkdir -p for parent directories and quoted heredocs or a small script with the full intended content.",
    "When creating Vite 8 React projects, use @vitejs/plugin-react ^5 with vite ^8, or omit the plugin if it is not needed. Do not pair Vite 8 with @vitejs/plugin-react 4.",
    "For inspection-only work, use client_read, client_grep, client_glob, or client_ls. Do not claim local work is done until a tool result is present in the transcript.",
    "",
    prompt
  ].join("\n");
}

function toolCallFromDelta(update) {
  if (!update || typeof update !== "object") return null;
  if (update.type !== "partial-tool-call" && update.type !== "tool-call-started") return null;
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
    default:
      return null;
  }
}

function isForwardableSDKToolCall(toolCall) {
  const args = toolCall.arguments || {};
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
      return hasString(args, "providerIdentifier", "provider", "server")
        && hasString(args, "toolName", "tool", "name");
    case "readlints":
    case "semsearch":
    case "todowrite":
      return Object.keys(args).length > 0;
    default:
      return Object.keys(args).length > 0;
  }
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
  const toolSignature = stableJson(input.clientTools || []);
  const digest = crypto
    .createHash("sha256")
    .update([input.apiKey, input.model, input.workingDirectory, input.sessionKey, toolSignature].join("\0"))
    .digest("hex")
    .slice(0, 32);
  return digest;
}

function evictAgents() {
  while (agentCache.size > maxAgents) {
    const oldest = [...agentCache.entries()].sort((a, b) => a[1].touchedAt - b[1].touchedAt)[0];
    if (!oldest) return;
    agentCache.delete(oldest[0]);
    try {
      oldest[1].agent.close();
    } catch {}
  }
}

function normalizeModel(model) {
  const normalized = model.trim().toLowerCase();
  if (!normalized || normalized === "default" || normalized === "auto") return "composer-2.5";
  if (normalized === "composer-2.5-sdk" || normalized === "composer-2-5-sdk") return "composer-2.5";
  if (normalized === "composer-2.5-fast" || normalized === "composer-2-5-fast") return "composer-2.5";
  return model.trim();
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

function openAiError(error) {
  return {
    error: {
      message: error instanceof Error ? error.message : String(error),
      type: error?.type || "api_error",
      code: error?.code || null
    }
  };
}

function statusFromError(error) {
  return Number.isInteger(error?.status) ? error.status : 500;
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
