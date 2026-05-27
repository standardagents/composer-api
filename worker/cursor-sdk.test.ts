import { describe, expect, it } from "vitest";
import { cursorSdkTestExports } from "./cursor-sdk";

describe("Cursor SDK harness", () => {
  it("does not emit incomplete SDK tool-call starts to OpenCode", () => {
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "glob", arguments: {} })).toBe(false);
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "edit", arguments: {} })).toBe(false);
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "edit", arguments: { path: "package.json", oldText: "old" } })).toBe(false);
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "edit", arguments: { path: "package.json", newText: "new" } })).toBe(false);
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "write", arguments: { path: "package.json" } })).toBe(false);
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "shell", arguments: {} })).toBe(false);
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "mcp", arguments: { providerIdentifier: "filesystem" } })).toBe(false);
  });

  it("allows SDK tool calls once required execution arguments are available", () => {
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "glob", arguments: { globPattern: "**/*.tsx" } })).toBe(true);
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "glob", arguments: { targetDirectory: "src" } })).toBe(true);
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "glob", arguments: { targetDirectory: "src/**/*.tsx" } })).toBe(true);
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "write", arguments: { path: "package.json", fileText: "" } })).toBe(true);
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "write", arguments: { filePath: "empty.txt", content: "" } })).toBe(true);
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "edit", arguments: { path: "package.json", oldText: "", newText: "{}" } })).toBe(true);
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "edit", arguments: { filePath: "package.json", old_str: "{}", replacement: "" } })).toBe(true);
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "edit", arguments: { path: "package.json", patch_content: "" } })).toBe(true);
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "shell", arguments: { command: "npm test" } })).toBe(true);
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "mcp", arguments: { providerIdentifier: "filesystem", toolName: "write_file" } })).toBe(true);
  });

  it("converts completed SDK streaming edits into OpenCode writes", () => {
    expect(
      cursorSdkTestExports.normalizeSdkToolCallForOpenCode({
        name: "edit",
        arguments: { path: "scripts/verify.mjs", streamContent: "console.log('ok')\n" }
      })
    ).toEqual({
      name: "write",
      arguments: { path: "scripts/verify.mjs", fileText: "console.log('ok')\n" }
    });
    expect(cursorSdkTestExports.isEmittableSdkToolCall({ name: "edit", arguments: { path: "scripts/verify.mjs", streamContent: "x" } })).toBe(
      true
    );
    expect(
      cursorSdkTestExports.normalizeSdkToolCallForOpenCode({
        name: "edit",
        arguments: { path: "scripts/empty.mjs", stream_content: "" }
      })
    ).toEqual({
      name: "write",
      arguments: { path: "scripts/empty.mjs", fileText: "" }
    });
  });

  it("decodes SDK MCP tool args maps", () => {
    const mcpArgs = protoMessage([
      protoStringField(1, "write_file"),
      protoMessageField(2, protoValueMapEntry("file_path", protoStringValue("src/App.tsx"))),
      protoMessageField(2, protoValueMapEntry("overwrite", protoBoolValue(true))),
      protoStringField(3, "call-mcp-1"),
      protoStringField(4, "filesystem"),
      protoStringField(5, "write_file")
    ]);
    const mcpTool = protoMessage([protoMessageField(1, mcpArgs)]);
    const toolCallUpdate = protoMessage([protoMessageField(2, protoMessage([protoMessageField(15, mcpTool)]))]);
    const interaction = protoMessage([protoMessageField(2, toolCallUpdate)]);
    const frame = protoMessage([protoMessageField(1, interaction)]);

    const event = cursorSdkTestExports.decodeLocalAgentServerFrame(frame).find((item) => item.type === "tool_call");

    expect(event).toMatchObject({
      type: "tool_call",
      toolCall: {
        name: "mcp",
        arguments: {
          name: "write_file",
          providerIdentifier: "filesystem",
          toolName: "write_file",
          toolCallId: "call-mcp-1",
          args: {
            file_path: "src/App.tsx",
            overwrite: true
          }
        }
      }
    });
  });

  it("encodes the harness working directory in SDK request context results", () => {
    const context = cursorSdkTestExports.encodeAgentClientRequestContextResult(
      { id: 42, execId: "exec-1" },
      { workingDirectory: "/tmp/project" }
    );
    const execMessage = dataField(decodeFields(context), 2);
    const result = dataField(decodeFields(execMessage), 10);
    const success = dataField(decodeFields(result), 1);
    const requestContext = dataField(decodeFields(success), 1);
    const env = dataField(decodeFields(requestContext), 4);
    const envFields = decodeFields(env);

    expect(stringField(envFields, 2)).toBe("/tmp/project");
    expect(stringField(envFields, 11)).toBe("/tmp/project");
    expect(stringField(envFields, 21)).toBe("/tmp/project");
  });

  it("builds a hard retry prompt when a tool-required SDK turn returns prose", () => {
    const prompt = cursorSdkTestExports.retryPromptAfterMissingTool("Original prompt");

    expect(prompt).toContain("Original prompt");
    expect(prompt).toContain("TOOL CALL RETRY");
    expect(prompt).toContain("attempt 2 of 3");
    expect(prompt).toContain("The next response is invalid unless it contains a tool_call.");
    expect(prompt).toContain("Do not answer in prose");
    expect(prompt).toContain("Emit exactly one SDK tool call");
  });

  it("builds a retry prompt when the SDK chooses an unmapped tool", () => {
    const prompt = cursorSdkTestExports.retryPromptAfterUnsupportedTool("Original prompt", {
      name: "shell",
      arguments: { command: "pwd" }
    }, "Required client arguments: command:string, description:string.");

    expect(prompt).toContain("Original prompt");
    expect(prompt).toContain("shell");
    expect(prompt).toContain("could not be mapped");
    expect(prompt).toContain("Required client arguments");
    expect(prompt).toContain("mappable tool_call");
    expect(prompt).toContain("allowed OpenCode tool inventory");
  });
});

function protoMessage(parts: Uint8Array[]): Uint8Array {
  const length = parts.reduce((sum, part) => sum + part.length, 0);
  const output = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.length;
  }
  return output;
}

function protoMessageField(fieldNumber: number, value: Uint8Array): Uint8Array {
  return protoMessage([protoVarint((fieldNumber << 3) | 2), protoVarint(value.length), value]);
}

function protoStringField(fieldNumber: number, value: string): Uint8Array {
  return protoMessageField(fieldNumber, new TextEncoder().encode(value));
}

function protoValueMapEntry(key: string, value: Uint8Array): Uint8Array {
  return protoMessage([protoStringField(1, key), protoMessageField(2, value)]);
}

function protoStringValue(value: string): Uint8Array {
  return protoMessage([protoStringField(3, value)]);
}

function protoBoolValue(value: boolean): Uint8Array {
  return protoMessage([protoVarint(4 << 3), protoVarint(value ? 1 : 0)]);
}

function protoVarint(value: number): Uint8Array {
  const bytes: number[] = [];
  let current = value >>> 0;
  while (current >= 0x80) {
    bytes.push((current & 0x7f) | 0x80);
    current >>>= 7;
  }
  bytes.push(current);
  return Uint8Array.from(bytes);
}

interface ProtoField {
  no: number;
  value: number | Uint8Array;
}

function decodeFields(bytes: Uint8Array): ProtoField[] {
  const fields: ProtoField[] = [];
  let offset = 0;
  while (offset < bytes.length) {
    const key = readVarint(bytes, offset);
    offset = key.offset;
    const no = key.value >> 3;
    const wireType = key.value & 7;
    if (wireType === 0) {
      const value = readVarint(bytes, offset);
      offset = value.offset;
      fields.push({ no, value: value.value });
      continue;
    }
    if (wireType !== 2) break;
    const length = readVarint(bytes, offset);
    offset = length.offset;
    const end = offset + length.value;
    fields.push({ no, value: bytes.subarray(offset, end) });
    offset = end;
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

function dataField(fields: ProtoField[], no: number): Uint8Array {
  const value = fields.find((field) => field.no === no)?.value;
  if (value instanceof Uint8Array) return value;
  throw new Error(`Missing data field ${no}`);
}

function stringField(fields: ProtoField[], no: number): string | undefined {
  const value = fields.find((field) => field.no === no)?.value;
  return value instanceof Uint8Array ? new TextDecoder().decode(value) : undefined;
}
