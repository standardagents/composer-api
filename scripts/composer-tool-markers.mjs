const TOOL_CALLS_BEGIN = "<|tool_calls_begin|>";
const TOOL_CALLS_END = "<|tool_calls_end|>";
const TOOL_CALL_BEGIN = "<|tool_call_begin|>";
const TOOL_CALL_END = "<|tool_call_end|>";
const TOOL_SEP = "<|tool_sep|>";
const TOOL_CALL_BEGIN_MARKERS = [
  TOOL_CALL_BEGIN,
  "<｜tool▁call▁begin｜>",
  "<|tool_call_begin|>",
];
const TOOL_CALL_END_MARKERS = [
  TOOL_CALL_END,
  "<｜tool▁call▁end｜>",
  "<|tool_call_end|>",
];
const TOOL_MARKER_CANDIDATES = [
  TOOL_CALLS_BEGIN,
  TOOL_CALLS_END,
  TOOL_CALL_BEGIN,
  TOOL_CALL_END,
  TOOL_SEP,
].flatMap((marker) => [
  marker,
  marker.replaceAll("|", "｜").replaceAll("_", "▁"),
]);

export class ComposerToolCallFilter {
  constructor() {
    this.buffer = "";
  }

  push(delta) {
    this.buffer += delta;
    return this.drain(false);
  }

  flush() {
    return this.drain(true);
  }

  drain(force) {
    this.buffer = canonicalizeComposerToolMarkers(this.buffer);
    const events = [];
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

      const end = findComposerToolMarker(
        this.buffer.slice(begin.length),
        "tool_calls_end",
      );
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

export function parseComposerToolCalls(value) {
  const normalized = canonicalizeComposerToolMarkers(value);
  const beginIndex = normalized.indexOf(TOOL_CALLS_BEGIN);
  const endIndex = normalized.lastIndexOf(TOOL_CALLS_END);
  if (beginIndex === -1 || endIndex === -1 || endIndex <= beginIndex) return [];

  const body = normalized.slice(beginIndex + TOOL_CALLS_BEGIN.length, endIndex);
  const calls = [];
  let offset = 0;
  for (;;) {
    const start = findCallBegin(body, offset);
    if (start === -1) break;
    const marker = findCallBeginMarker(body, offset);
    const contentStart = start + marker.length;
    const end = findCallEnd(body, contentStart);
    if (end === -1) break;
    const call = parseComposerToolCallBody(body.slice(contentStart, end.index));
    if (call) calls.push(call);
    offset = end.index + end.length;
  }
  if (!calls.length) {
    const fallback = parseComposerToolCallBody(body.trim());
    if (fallback) calls.push(fallback);
  }
  return calls;
}

export function extractComposerToolOutput(text) {
  const filter = new ComposerToolCallFilter();
  let visibleText = "";
  const toolCalls = [];
  for (const event of [...filter.push(text), ...filter.flush()]) {
    if (event.type === "text") visibleText += event.text;
    else if (event.type === "tool_call") toolCalls.push(event.toolCall);
  }
  if (!toolCalls.length) {
    for (const toolCall of parseComposerToolCalls(text)) {
      toolCalls.push(toolCall);
    }
    if (toolCalls.length) {
      visibleText = stripEmbeddedToolMarkerBlocks(text);
    }
  }
  return { text: visibleText.trim(), toolCalls };
}

function findCallBeginMarker(body, offset) {
  for (const marker of TOOL_CALL_BEGIN_MARKERS) {
    if (
      body.indexOf(marker, offset) === offset ||
      body.indexOf(marker, offset) !== -1
    ) {
      const index = body.indexOf(marker, offset);
      if (index !== -1) return marker;
    }
  }
  for (const marker of TOOL_CALL_BEGIN_MARKERS) {
    const index = body.indexOf(marker, offset);
    if (index !== -1) return marker;
  }
  return TOOL_CALL_BEGIN;
}

function findCallBegin(body, offset) {
  let earliest = -1;
  for (const marker of TOOL_CALL_BEGIN_MARKERS) {
    const index = body.indexOf(marker, offset);
    if (index !== -1 && (earliest === -1 || index < earliest)) earliest = index;
  }
  return earliest;
}

function findCallEnd(body, contentStart) {
  let earliest = -1;
  let marker = TOOL_CALL_END;
  for (const candidate of TOOL_CALL_END_MARKERS) {
    const index = body.indexOf(candidate, contentStart);
    if (index !== -1 && (earliest === -1 || index < earliest)) {
      earliest = index;
      marker = candidate;
    }
  }
  return earliest === -1 ? null : { index: earliest, length: marker.length };
}

function parseComposerToolCallBody(value) {
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

  const args = {};
  for (const part of parts) {
    const trimmed = part.replace(/^\s+/, "");
    if (!trimmed) continue;
    const match = /^([^\r\n]+)(?:\r?\n([\s\S]*))?$/.exec(trimmed);
    if (!match) continue;
    const key = match[1].trim();
    if (!key) continue;
    args[key] = parseComposerToolArgument((match[2] || "").trim());
  }

  return { name, arguments: args };
}

function parseJsonToolCallBody(value) {
  if (!value.startsWith("{") || !value.endsWith("}")) return null;
  try {
    const parsed = JSON.parse(value);
    if (!isRecord(parsed)) return null;
    const fn = isRecord(parsed.function) ? parsed.function : undefined;
    const name = firstString(
      parsed.name,
      parsed.tool,
      parsed.tool_name,
      parsed.toolName,
      fn?.name,
    );
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

function firstString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return null;
}

function recordFromToolArguments(value) {
  if (isRecord(value)) return value;
  if (typeof value !== "string" || !value.trim()) return null;
  try {
    const decoded = JSON.parse(value);
    return isRecord(decoded) ? decoded : null;
  } catch {
    return null;
  }
}

function parseInlineToolCall(value) {
  const match = /^([A-Za-z0-9_.-]+)\s*(?:\(([\s\S]*)\)|\[([\s\S]*)\])?$/.exec(
    value.trim(),
  );
  if (!match) return null;
  const name = match[1].trim();
  const rawArgs = (match[2] ?? match[3] ?? "").trim();
  return { name, arguments: rawArgs ? parseInlineToolArguments(rawArgs) : {} };
}

function parseInlineToolArguments(value) {
  const args = {};
  for (const part of splitInlineArguments(value)) {
    const match = /^([A-Za-z0-9_.-]+)\s*[:=]\s*([\s\S]*)$/.exec(part.trim());
    if (!match) continue;
    args[match[1]] = parseComposerToolArgument(match[2].trim());
  }
  return args;
}

function splitInlineArguments(value) {
  const parts = [];
  let start = 0;
  let quote = null;
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

function parseComposerToolArgument(value) {
  if (!value) return "";
  if (value === "true") return true;
  if (value === "false") return false;
  if (value === "null") return null;
  if (/^-?\d+(?:\.\d+)?$/.test(value)) return Number(value);
  if (
    (value.startsWith("{") && value.endsWith("}")) ||
    (value.startsWith("[") && value.endsWith("]"))
  ) {
    try {
      return JSON.parse(value);
    } catch {
      return value;
    }
  }
  return value;
}

function canonicalizeComposerToolMarkers(value) {
  return value
    .replace(
      /<\s*[|｜]\s*(tool[_▁]calls[_▁]begin|tool[_▁]calls[_▁]end|tool[_▁]call[_▁]begin|tool[_▁]call[_▁]end|tool[_▁]sep)\s*[|｜]\s*>/g,
      (_match, marker) => {
        const normalized = marker.replaceAll("▁", "_");
        if (normalized === "tool_call_begin") return TOOL_CALL_BEGIN;
        if (normalized === "tool_call_end") return TOOL_CALL_END;
        return `<|${normalized}|>`;
      },
    )
    .replace(/<\|tool_calls<\|tool_calls_begin\|>/g, TOOL_CALLS_BEGIN)
    .replace(/<\|tool_calls<\|tool_calls_end\|>/g, TOOL_CALLS_END)
    .replace(/<\|tool<\|tool_sep\|>/g, TOOL_SEP);
}

function stripEmbeddedToolMarkerBlocks(value) {
  const normalized = canonicalizeComposerToolMarkers(value);
  const beginIndex = normalized.indexOf(TOOL_CALLS_BEGIN);
  const endIndex = normalized.lastIndexOf(TOOL_CALLS_END);
  if (beginIndex === -1 || endIndex === -1 || endIndex <= beginIndex)
    return value.trim();
  return `${normalized.slice(0, beginIndex)}${normalized.slice(endIndex + TOOL_CALLS_END.length)}`.trim();
}

function findComposerToolMarker(value, marker) {
  const markerPattern = marker.replaceAll("_", "[_▁]");
  const pattern = new RegExp(`<\\s*[|｜]\\s*${markerPattern}\\s*[|｜]\\s*>`);
  const match = pattern.exec(value);
  return match ? { index: match.index, length: match[0].length } : null;
}

function toolMarkerPrefixIndex(value) {
  const max = Math.min(
    value.length,
    Math.max(...TOOL_MARKER_CANDIDATES.map((candidate) => candidate.length)),
  );
  for (let length = max; length >= 1; length -= 1) {
    const index = value.length - length;
    const suffix = value.slice(index);
    if (
      TOOL_MARKER_CANDIDATES.some((candidate) => candidate.startsWith(suffix))
    )
      return index;
  }
  return -1;
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
