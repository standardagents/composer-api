import { HttpError } from "./http";
import { encodeSse } from "./sse";
import type { CursorImage, CursorPrompt } from "./types";

export type ApiKind = "chat" | "responses";

export interface PreparedRequest {
  model: string;
  cursorModel?: { id: string };
  prompt: CursorPrompt;
  stream: boolean;
  promptChars: number;
  responseMetadata: Record<string, unknown>;
}

const SYSTEM_DIRECTIVE = [
  "You are serving an OpenAI-compatible API request through Cursor Composer.",
  "Answer the user directly in chat style.",
  "Do not modify files, run terminal commands, open pull requests, or use coding-agent workflow unless the user explicitly asks for code as text.",
  "Return only the final answer content."
].join("\n");

export function prepareChatRequest(body: unknown, cursorModel: { id: string } | undefined): PreparedRequest {
  const record = expectRecord(body, "body");
  const messages = expectArray(record.messages, "messages");
  validateCommonUnsupported(record);
  if (record.tools !== undefined && record.tool_choice !== "none") {
    throw new HttpError("OpenAI tool calls are not supported by Cursor's public agent API adapter.", 400, "unsupported_parameter", "tools");
  }
  if (record.functions !== undefined) {
    throw new HttpError("Legacy function calling is not supported by this adapter.", 400, "unsupported_parameter", "functions");
  }

  const model = typeof record.model === "string" && record.model.trim() ? record.model.trim() : "composer-2.5";
  const transcript: string[] = [SYSTEM_DIRECTIVE, "", "Conversation:"];
  const images: CursorImage[] = [];
  for (const message of messages) {
    const item = expectRecord(message, "messages[]");
    const role = typeof item.role === "string" ? item.role : "user";
    const { text, images: messageImages } = contentToTextAndImages(item.content, role);
    images.push(...messageImages);
    transcript.push(`${role.toUpperCase()}: ${text || "[empty]"}`);
    if (Array.isArray(item.tool_calls)) {
      transcript.push(`${role.toUpperCase()} TOOL_CALLS: ${JSON.stringify(item.tool_calls)}`);
    }
  }
  appendChatOptions(transcript, record);
  const text = transcript.join("\n");
  return {
    model,
    cursorModel,
    prompt: { text, ...(images.length ? { images } : {}) },
    stream: record.stream === true,
    promptChars: text.length,
    responseMetadata: {
      temperature: numberOrNull(record.temperature),
      top_p: numberOrNull(record.top_p)
    }
  };
}

export function prepareResponsesRequest(body: unknown, cursorModel: { id: string } | undefined): PreparedRequest {
  const record = expectRecord(body, "body");
  validateCommonUnsupported(record);
  if (Array.isArray(record.tools) && record.tools.length > 0) {
    throw new HttpError("OpenAI Responses tools are not supported by Cursor's public agent API adapter.", 400, "unsupported_parameter", "tools");
  }
  if (record.background === true) {
    throw new HttpError("background responses are not supported.", 400, "unsupported_parameter", "background");
  }

  const model = typeof record.model === "string" && record.model.trim() ? record.model.trim() : "composer-2.5";
  const transcript: string[] = [SYSTEM_DIRECTIVE];
  const instructions = typeof record.instructions === "string" ? record.instructions.trim() : "";
  if (instructions) transcript.push("", `INSTRUCTIONS:\n${instructions}`);
  transcript.push("", "INPUT:");
  const { text, images } = responseInputToTextAndImages(record.input);
  transcript.push(text || "[empty]");
  appendResponseOptions(transcript, record);
  const prompt = transcript.join("\n");
  return {
    model,
    cursorModel,
    prompt: { text: prompt, ...(images.length ? { images } : {}) },
    stream: record.stream === true,
    promptChars: prompt.length,
    responseMetadata: {
      instructions: instructions || null,
      max_output_tokens: integerOrNull(record.max_output_tokens),
      temperature: numberOrNull(record.temperature),
      top_p: numberOrNull(record.top_p),
      text: isRecord(record.text) ? record.text : { format: { type: "text" } }
    }
  };
}

export function chatCompletionResponse(input: {
  id: string;
  created: number;
  model: string;
  text: string;
  promptChars: number;
  metadata?: Record<string, unknown>;
}): Record<string, unknown> {
  return {
    id: input.id,
    object: "chat.completion",
    created: input.created,
    model: input.model,
    choices: [
      {
        index: 0,
        message: {
          role: "assistant",
          content: input.text,
          refusal: null,
          annotations: []
        },
        logprobs: null,
        finish_reason: "stop"
      }
    ],
    usage: usageFromChars(input.promptChars, input.text.length),
    service_tier: "default",
    system_fingerprint: null,
    ...input.metadata
  };
}

export function responseObject(input: {
  id: string;
  created: number;
  model: string;
  text: string;
  promptChars: number;
  metadata?: Record<string, unknown>;
}): Record<string, unknown> {
  const messageId = `msg_${input.id.slice(5)}`;
  return {
    id: input.id,
    object: "response",
    created_at: input.created,
    status: "completed",
    completed_at: Math.max(input.created, Math.floor(Date.now() / 1000)),
    error: null,
    incomplete_details: null,
    model: input.model,
    output: [
      {
        id: messageId,
        type: "message",
        status: "completed",
        role: "assistant",
        content: [
          {
            type: "output_text",
            text: input.text,
            annotations: []
          }
        ]
      }
    ],
    parallel_tool_calls: true,
    previous_response_id: null,
    reasoning: { effort: null, summary: null },
    store: false,
    tool_choice: "auto",
    tools: [],
    truncation: "disabled",
    usage: responseUsageFromChars(input.promptChars, input.text.length),
    user: null,
    metadata: {},
    ...input.metadata
  };
}

export function chatChunk(input: {
  id: string;
  created: number;
  model: string;
  delta?: string;
  role?: "assistant";
  finish?: boolean;
}): Uint8Array {
  const chunk = {
    id: input.id,
    object: "chat.completion.chunk",
    created: input.created,
    model: input.model,
    system_fingerprint: null,
    choices: [
      {
        index: 0,
        delta: input.finish ? {} : { ...(input.role ? { role: input.role } : {}), ...(input.delta ? { content: input.delta } : {}) },
        logprobs: null,
        finish_reason: input.finish ? "stop" : null
      }
    ]
  };
  return encodeSse(chunk);
}

export function doneChunk(): Uint8Array {
  return encodeSse("[DONE]");
}

export function responseCreatedEvents(input: { id: string; created: number; model: string; metadata?: Record<string, unknown> }): Uint8Array[] {
  const base = {
    id: input.id,
    object: "response",
    created_at: input.created,
    status: "in_progress",
    error: null,
    incomplete_details: null,
    model: input.model,
    output: [],
    parallel_tool_calls: true,
    previous_response_id: null,
    reasoning: { effort: null, summary: null },
    store: false,
    tool_choice: "auto",
    tools: [],
    truncation: "disabled",
    usage: null,
    user: null,
    metadata: {},
    ...input.metadata
  };
  const item = {
    id: `msg_${input.id.slice(5)}`,
    type: "message",
    status: "in_progress",
    role: "assistant",
    content: []
  };
  return [
    encodeSse({ type: "response.created", response: base }, "response.created"),
    encodeSse({ type: "response.in_progress", response: base }, "response.in_progress"),
    encodeSse({ type: "response.output_item.added", output_index: 0, item }, "response.output_item.added"),
    encodeSse(
      {
        type: "response.content_part.added",
        item_id: item.id,
        output_index: 0,
        content_index: 0,
        part: { type: "output_text", text: "", annotations: [] }
      },
      "response.content_part.added"
    )
  ];
}

export function responseDeltaEvent(input: { id: string; delta: string }): Uint8Array {
  return encodeSse(
    {
      type: "response.output_text.delta",
      item_id: `msg_${input.id.slice(5)}`,
      output_index: 0,
      content_index: 0,
      delta: input.delta
    },
    "response.output_text.delta"
  );
}

export function responseDoneEvents(input: {
  id: string;
  created: number;
  model: string;
  text: string;
  promptChars: number;
  metadata?: Record<string, unknown>;
}): Uint8Array[] {
  const itemId = `msg_${input.id.slice(5)}`;
  const part = { type: "output_text", text: input.text, annotations: [] };
  const item = { id: itemId, type: "message", status: "completed", role: "assistant", content: [part] };
  return [
    encodeSse(
      { type: "response.output_text.done", item_id: itemId, output_index: 0, content_index: 0, text: input.text },
      "response.output_text.done"
    ),
    encodeSse(
      { type: "response.content_part.done", item_id: itemId, output_index: 0, content_index: 0, part },
      "response.content_part.done"
    ),
    encodeSse({ type: "response.output_item.done", output_index: 0, item }, "response.output_item.done"),
    encodeSse(
      { type: "response.completed", response: responseObject(input) },
      "response.completed"
    )
  ];
}

export function modelList(): Record<string, unknown> {
  return {
    object: "list",
    data: [
      modelItem("composer-2.5", "Cursor Composer 2.5"),
      modelItem("composer-2.5-fast", "Cursor Composer 2.5 Fast"),
      modelItem("composer-latest", "Cursor Composer latest alias")
    ]
  };
}

function modelItem(id: string, name: string) {
  return {
    id,
    object: "model",
    created: 1779148800,
    owned_by: "cursor",
    name
  };
}

function validateCommonUnsupported(record: Record<string, unknown>) {
  if (typeof record.n === "number" && record.n !== 1) {
    throw new HttpError("Only n=1 is supported.", 400, "unsupported_parameter", "n");
  }
  if (record.logprobs === true || record.top_logprobs !== undefined) {
    throw new HttpError("logprobs are not available through Cursor's agent API.", 400, "unsupported_parameter", "logprobs");
  }
  if (Array.isArray(record.modalities) && record.modalities.some((value) => value !== "text")) {
    throw new HttpError("Only text output is supported.", 400, "unsupported_parameter", "modalities");
  }
  if (record.audio !== undefined) {
    throw new HttpError("Audio output is not supported.", 400, "unsupported_parameter", "audio");
  }
}

function appendChatOptions(transcript: string[], record: Record<string, unknown>) {
  const constraints: string[] = [];
  const maxTokens = integerOrNull(record.max_completion_tokens ?? record.max_tokens);
  if (maxTokens) constraints.push(`Keep the answer within about ${maxTokens} output tokens.`);
  appendStopConstraint(constraints, record.stop);
  appendJsonConstraint(constraints, record.response_format);
  if (constraints.length) transcript.push("", "OUTPUT CONSTRAINTS:", ...constraints.map((item) => `- ${item}`));
}

function appendResponseOptions(transcript: string[], record: Record<string, unknown>) {
  const constraints: string[] = [];
  const maxTokens = integerOrNull(record.max_output_tokens);
  if (maxTokens) constraints.push(`Keep the answer within about ${maxTokens} output tokens.`);
  appendStopConstraint(constraints, record.stop);
  const text = isRecord(record.text) ? record.text : undefined;
  appendJsonConstraint(constraints, text?.format);
  if (constraints.length) transcript.push("", "OUTPUT CONSTRAINTS:", ...constraints.map((item) => `- ${item}`));
}

function appendStopConstraint(constraints: string[], stop: unknown) {
  if (typeof stop === "string") constraints.push(`Do not include text after this stop sequence: ${stop}`);
  else if (Array.isArray(stop) && stop.length) constraints.push(`Stop before any of these sequences: ${stop.join(", ")}`);
}

function appendJsonConstraint(constraints: string[], format: unknown) {
  if (!isRecord(format)) return;
  if (format.type === "json_object") constraints.push("Return a single valid JSON object and no surrounding prose.");
  if (format.type === "json_schema") {
    const schema = isRecord(format.json_schema) ? format.json_schema.schema : format.schema;
    constraints.push(`Return JSON that matches this schema: ${JSON.stringify(schema ?? format)}`);
  }
}

function responseInputToTextAndImages(input: unknown): { text: string; images: CursorImage[] } {
  if (typeof input === "string") return { text: input, images: [] };
  if (!Array.isArray(input)) return { text: input === undefined ? "" : JSON.stringify(input), images: [] };
  const lines: string[] = [];
  const images: CursorImage[] = [];
  for (const item of input) {
    if (typeof item === "string") {
      lines.push(item);
      continue;
    }
    const record = expectRecord(item, "input[]");
    if (record.type === "message" || typeof record.role === "string") {
      const role = typeof record.role === "string" ? record.role : "user";
      const content = contentToTextAndImages(record.content, role);
      lines.push(`${role.toUpperCase()}: ${content.text || "[empty]"}`);
      images.push(...content.images);
    } else if (record.type === "function_call" || record.type === "function_call_output") {
      lines.push(`${String(record.type).toUpperCase()}: ${JSON.stringify(record)}`);
    } else {
      lines.push(JSON.stringify(record));
    }
  }
  return { text: lines.join("\n"), images };
}

function contentToTextAndImages(content: unknown, role: string): { text: string; images: CursorImage[] } {
  if (typeof content === "string") return { text: content, images: [] };
  if (content === null || content === undefined) return { text: "", images: [] };
  if (!Array.isArray(content)) return { text: JSON.stringify(content), images: [] };

  const parts: string[] = [];
  const images: CursorImage[] = [];
  for (const part of content) {
    if (typeof part === "string") {
      parts.push(part);
      continue;
    }
    if (!isRecord(part)) {
      parts.push(JSON.stringify(part));
      continue;
    }
    const type = part.type;
    if ((type === "text" || type === "input_text" || type === "output_text") && typeof part.text === "string") {
      parts.push(part.text);
    } else if (type === "image_url" && isRecord(part.image_url) && typeof part.image_url.url === "string") {
      images.push(imageFromUrl(part.image_url.url));
      parts.push("[image]");
    } else if (type === "input_image" && typeof part.image_url === "string") {
      images.push(imageFromUrl(part.image_url));
      parts.push("[image]");
    } else if (type === "tool_result" || type === "function_call_output") {
      parts.push(`${role} ${String(type)}: ${JSON.stringify(part)}`);
    } else {
      parts.push(JSON.stringify(part));
    }
  }
  return { text: parts.join("\n"), images };
}

function imageFromUrl(url: string): CursorImage {
  const dataUrl = /^data:([^;,]+);base64,(.+)$/i.exec(url);
  if (dataUrl) {
    return { mimeType: dataUrl[1], data: dataUrl[2] };
  }
  return { url };
}

function usageFromChars(promptChars: number, completionChars: number) {
  const promptTokens = estimateTokens(promptChars);
  const completionTokens = estimateTokens(completionChars);
  return {
    prompt_tokens: promptTokens,
    completion_tokens: completionTokens,
    total_tokens: promptTokens + completionTokens,
    prompt_tokens_details: { cached_tokens: 0, audio_tokens: 0 },
    completion_tokens_details: {
      reasoning_tokens: 0,
      audio_tokens: 0,
      accepted_prediction_tokens: 0,
      rejected_prediction_tokens: 0
    }
  };
}

function responseUsageFromChars(inputChars: number, outputChars: number) {
  const inputTokens = estimateTokens(inputChars);
  const outputTokens = estimateTokens(outputChars);
  return {
    input_tokens: inputTokens,
    input_tokens_details: { cached_tokens: 0 },
    output_tokens: outputTokens,
    output_tokens_details: { reasoning_tokens: 0 },
    total_tokens: inputTokens + outputTokens
  };
}

function estimateTokens(chars: number): number {
  return Math.max(1, Math.ceil(chars / 4));
}

function expectRecord(value: unknown, name: string): Record<string, unknown> {
  if (!isRecord(value)) throw new HttpError(`${name} must be an object`, 400, "invalid_request_error", name);
  return value;
}

function expectArray(value: unknown, name: string): unknown[] {
  if (!Array.isArray(value)) throw new HttpError(`${name} must be an array`, 400, "invalid_request_error", name);
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function integerOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isInteger(value) ? value : null;
}

function numberOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}
