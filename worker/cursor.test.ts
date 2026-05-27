import { describe, expect, it } from "vitest";
import { cursorTestExports, resolveCursorModel, streamCursorText } from "./cursor";
import { encodeSse } from "./sse";

describe("cursorIdentityCache eviction", () => {
  it("evicts expired entries when evictExpiredCacheEntries is called", () => {
    const { cursorIdentityCache, evictExpiredCacheEntries } = cursorTestExports;
    const past = Date.now() - 1;
    const future = Date.now() + 3_600_000;

    cursorIdentityCache.set("expired-key", { identity: "expired", expiresAt: past });
    cursorIdentityCache.set("valid-key", { identity: "valid", expiresAt: future });

    evictExpiredCacheEntries(Date.now());

    expect(cursorIdentityCache.has("expired-key")).toBe(false);
    expect(cursorIdentityCache.has("valid-key")).toBe(true);
  });

  it("handles an empty cache without error", () => {
    const { evictExpiredCacheEntries } = cursorTestExports;
    expect(() => evictExpiredCacheEntries(Date.now())).not.toThrow();
  });
});

describe("Cursor stream adapter", () => {
  it("maps public default aliases to a concrete internal Composer model", () => {
    expect(resolveCursorModel("default")).toEqual({ id: "composer-2.5" });
    expect(resolveCursorModel("auto")).toEqual({ id: "composer-2.5" });
  });

  it("encodes attached images into the user ConversationMessage", () => {
    const body = cursorTestExports.encodeCursorChatRequest({
      prompt: { text: "Describe this image." },
      images: [
        {
          data: new Uint8Array([1, 2, 3]),
          dimension: { width: 640, height: 480 },
          uuid: "image-test"
        }
      ],
      model: "composer-2.5",
      requestId: "request-test",
      conversationId: "conversation-test",
      messageId: "message-test"
    });

    const outer = fields(body);
    const request = fields(bytesField(outer, 1));
    const userMessage = fields(bytesField(request, 1));
    const image = fields(bytesField(userMessage, 10));
    const dimension = fields(bytesField(image, 2));

    expect(bytesField(userMessage, 1)).toEqual(new TextEncoder().encode("Describe this image."));
    expect(bytesField(image, 1)).toEqual(new Uint8Array([1, 2, 3]));
    expect(numberField(dimension, 1)).toBe(640);
    expect(numberField(dimension, 2)).toBe(480);
    expect(bytesField(image, 3)).toEqual(new TextEncoder().encode("image-test"));
  });

  it("encodes Agent mode for tool-capable requests", () => {
    const body = cursorTestExports.encodeCursorChatRequest({
      prompt: { text: "List files.", mode: "agent" },
      model: "composer-2.5",
      requestId: "request-test",
      conversationId: "conversation-test",
      messageId: "message-test"
    });

    const outer = fields(body);
    const request = fields(bytesField(outer, 1));

    expect(new TextDecoder().decode(bytesField(request, 54))).toBe("Agent");
  });

  it("defaults to Ask mode for plain chat requests", () => {
    const body = cursorTestExports.encodeCursorChatRequest({
      prompt: { text: "Say hello." },
      model: "composer-2.5",
      requestId: "request-test",
      conversationId: "conversation-test",
      messageId: "message-test"
    });

    const outer = fields(body);
    const request = fields(bytesField(outer, 1));

    expect(new TextDecoder().decode(bytesField(request, 54))).toBe("Ask");
  });

  it("extracts final text from raw Cursor Connect/protobuf frames", async () => {
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(connectFrame(chatResponseText("Hello")));
          controller.enqueue(connectFrame(chatResponseText(" from Composer")));
          controller.enqueue(connectFrame(new TextEncoder().encode("{}"), 2));
          controller.close();
        }
      }),
      { headers: { "Content-Type": "application/connect+proto" } }
    );
    const events = [];
    for await (const event of streamCursorText(response)) events.push(event);
    expect(events).toEqual([
      { type: "text", text: "Hello" },
      { type: "text", text: " from Composer" },
      { type: "done", finalText: "Hello from Composer", toolCalls: [] }
    ]);
  });

  it("strips Composer thinking before yielding final Cursor text", async () => {
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(connectFrame(chatResponseThinking('The user asked for OK.')));
          controller.enqueue(connectFrame(chatResponseThinking("\n</think>\nOK")));
          controller.enqueue(connectFrame(new TextEncoder().encode("{}"), 2));
          controller.close();
        }
      }),
      { headers: { "Content-Type": "application/connect+proto" } }
    );
    const events = [];
    for await (const event of streamCursorText(response)) events.push(event);
    expect(events).toEqual([
      { type: "text", text: "OK" },
      { type: "done", finalText: "OK", toolCalls: [] }
    ]);
  });

  it("strips Composer final markers when there is no think closing tag", async () => {
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(connectFrame(chatResponseThinking("Hidden reasoning <｜final｜>Visible answer")));
          controller.enqueue(connectFrame(new TextEncoder().encode("{}"), 2));
          controller.close();
        }
      }),
      { headers: { "Content-Type": "application/connect+proto" } }
    );
    const events = [];
    for await (const event of streamCursorText(response)) events.push(event);
    expect(events).toEqual([
      { type: "text", text: "Visible answer" },
      { type: "done", finalText: "Visible answer", toolCalls: [] }
    ]);
  });

  it("strips Composer final markers from normal text frames", async () => {
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(connectFrame(chatResponseText("Hidden reasoning <｜final｜>\nVisible answer")));
          controller.enqueue(connectFrame(chatResponseText("< | final | >Second answer")));
          controller.enqueue(connectFrame(new TextEncoder().encode("{}"), 2));
          controller.close();
        }
      }),
      { headers: { "Content-Type": "application/connect+proto" } }
    );
    const events = [];
    for await (const event of streamCursorText(response)) events.push(event);
    expect(events).toEqual([
      { type: "text", text: "Visible answer" },
      { type: "text", text: "Second answer" },
      { type: "done", finalText: "Visible answerSecond answer", toolCalls: [] }
    ]);
  });

  it("strips Composer final markers split across normal text frames", async () => {
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(connectFrame(chatResponseText("<")));
          controller.enqueue(connectFrame(chatResponseText("｜fina")));
          controller.enqueue(connectFrame(chatResponseText("l｜")));
          controller.enqueue(connectFrame(chatResponseText(">\n\nVisible answer")));
          controller.enqueue(connectFrame(new TextEncoder().encode("{}"), 2));
          controller.close();
        }
      }),
      { headers: { "Content-Type": "application/connect+proto" } }
    );
    const events = [];
    for await (const event of streamCursorText(response)) events.push(event);
    expect(events).toEqual([
      { type: "text", text: "Visible answer" },
      { type: "done", finalText: "Visible answer", toolCalls: [] }
    ]);
  });

  it("parses Composer tool-call markers into structured tool calls", async () => {
    const marker = [
      "Checking the workspace.\n",
      "<|tool_calls_begin|><|tool_call_begin|>\n",
      "Glob\n",
      "<|tool_sep|>targeting\n",
      "/Users/example/project/**\n",
      "<|tool_sep|>glob_pattern\n",
      "*\n",
      "<|tool_call_end|><|tool_calls_end|>"
    ].join("");
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(connectFrame(chatResponseText(marker.slice(0, 45))));
          controller.enqueue(connectFrame(chatResponseText(marker.slice(45))));
          controller.enqueue(connectFrame(new TextEncoder().encode("{}"), 2));
          controller.close();
        }
      }),
      { headers: { "Content-Type": "application/connect+proto" } }
    );
    const events = [];
    for await (const event of streamCursorText(response)) events.push(event);
    expect(events).toEqual([
      { type: "text", text: "Checking the workspace.\n" },
      {
        type: "tool_call",
        toolCall: {
          name: "Glob",
          arguments: {
            targeting: "/Users/example/project/**",
            glob_pattern: "*"
          }
        }
      },
      {
        type: "done",
        finalText: "Checking the workspace.\n",
        toolCalls: [{ name: "Glob", arguments: { targeting: "/Users/example/project/**", glob_pattern: "*" } }]
      }
    ]);
  });

  it("parses Composer tool-call markers with direct parser", () => {
    expect(
      cursorTestExports.parseComposerToolCalls(
        "< | tool_calls_begin | >< | tool_call_begin | >\nRead< | tool_sep | >path\nREADME.md< | tool_call_end | >< | tool_calls_end | >"
      )
    ).toEqual([{ name: "Read", arguments: { path: "README.md" } }]);
  });

  it("parses full-width Composer tool-call markers", () => {
    expect(
      cursorTestExports.parseComposerToolCalls(
        "<｜tool▁calls▁begin｜><｜tool▁call▁begin｜>\nglob\n<｜tool▁sep｜>glob_pattern\n*\n<｜tool▁call▁end｜><｜tool▁calls▁end｜>"
      )
    ).toEqual([{ name: "glob", arguments: { glob_pattern: "*" } }]);
  });

  it("parses inline Composer tool-call arguments", () => {
    expect(
      cursorTestExports.parseComposerToolCalls(
        "<|tool_calls_begin|><|tool_call_begin|>\nGlob [targeting=/Users/example/project/**, glob_pattern=*]\n<|tool_call_end|><|tool_calls_end|>"
      )
    ).toEqual([{ name: "Glob", arguments: { targeting: "/Users/example/project/**", glob_pattern: "*" } }]);
  });

  it("parses JSON Composer tool-call bodies", () => {
    expect(
      cursorTestExports.parseComposerToolCalls(
        '<|tool_calls_begin|><|tool_call_begin|>{"name":"read","arguments":{"filePath":"README.md"}}<|tool_call_end|><|tool_calls_end|>'
      )
    ).toEqual([{ name: "read", arguments: { filePath: "README.md" } }]);
  });

  it("parses alternate JSON tool-call body shapes", () => {
    expect(
      cursorTestExports.parseComposerToolCalls(
        '<|tool_calls_begin|><|tool_call_begin|>{"tool_name":"write_file","args":{"target_file":"index.html","new_contents":"hi"}}<|tool_call_end|><|tool_calls_end|>'
      )
    ).toEqual([{ name: "write_file", arguments: { target_file: "index.html", new_contents: "hi" } }]);

    expect(
      cursorTestExports.parseComposerToolCalls(
        '<|tool_calls_begin|><|tool_call_begin|>{"function":{"name":"bash","arguments":"{\\"cmd\\":\\"npm test\\"}"}}<|tool_call_end|><|tool_calls_end|>'
      )
    ).toEqual([{ name: "bash", arguments: { cmd: "npm test" } }]);
  });

  it("does not emit leading whitespace before split tool-call markers", async () => {
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(connectFrame(chatResponseText("\n<｜tool")));
          controller.enqueue(
            connectFrame(
              chatResponseText(
                "▁calls▁begin｜><｜tool▁call▁begin｜>\nglob\n<｜tool▁sep｜>glob_pattern\n*\n<｜tool▁call▁end｜><｜tool▁calls▁end｜>"
              )
            )
          );
          controller.enqueue(connectFrame(new TextEncoder().encode("{}"), 2));
          controller.close();
        }
      }),
      { headers: { "Content-Type": "application/connect+proto" } }
    );
    const events = [];
    for await (const event of streamCursorText(response)) events.push(event);
    expect(events).toEqual([
      { type: "tool_call", toolCall: { name: "glob", arguments: { glob_pattern: "*" } } },
      { type: "done", finalText: "", toolCalls: [{ name: "glob", arguments: { glob_pattern: "*" } }] }
    ]);
  });

  it("surfaces detailed Cursor end-stream errors", async () => {
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(connectFrame(cursorError("Too many computers.", "Too many computers used within the last 24 hours."), 2));
          controller.close();
        }
      }),
      { headers: { "Content-Type": "application/connect+proto" } }
    );
    await expect(async () => {
      for await (const _event of streamCursorText(response)) {
        // Drain stream.
      }
    }).rejects.toThrow("Too many computers used within the last 24 hours");
  });

  it("extracts text deltas from Cursor interaction_update events", async () => {
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(encodeSse({ type: "text-delta", text: "Hello" }, "interaction_update"));
          controller.enqueue(encodeSse({ type: "text-delta", text: " world" }, "interaction_update"));
          controller.enqueue(encodeSse({ status: "FINISHED", result: "Hello world" }, "result"));
          controller.close();
        }
      })
    );
    const events = [];
    for await (const event of streamCursorText(response)) events.push(event);
    expect(events).toEqual([
      { type: "text", text: "Hello" },
      { type: "text", text: " world" },
      { type: "done", finalText: "Hello world", toolCalls: [] }
    ]);
  });

  it("falls back to legacy assistant events", async () => {
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(encodeSse({ text: "Legacy text" }, "assistant"));
          controller.enqueue(encodeSse({ status: "FINISHED" }, "result"));
          controller.close();
        }
      })
    );
    const events = [];
    for await (const event of streamCursorText(response)) events.push(event);
    expect(events.at(-1)).toEqual({ type: "done", finalText: "Legacy text", toolCalls: [] });
  });
});

function chatResponseText(text: string): Uint8Array {
  return protoMessage([protoField(2, protoMessage([protoField(1, text)]))]);
}

function chatResponseThinking(text: string): Uint8Array {
  return protoMessage([protoField(2, protoMessage([protoField(25, protoMessage([protoField(1, text)]))]))]);
}

function connectFrame(payload: Uint8Array, flags = 0): Uint8Array {
  const frame = new Uint8Array(5 + payload.length);
  frame[0] = flags;
  new DataView(frame.buffer).setUint32(1, payload.length, false);
  frame.set(payload, 5);
  return frame;
}

function cursorError(title: string, detail: string): Uint8Array {
  return new TextEncoder().encode(
    JSON.stringify({
      error: {
        code: "resource_exhausted",
        message: "Error",
        details: [{ debug: { details: { title, detail } } }]
      }
    })
  );
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

function protoField(fieldNumber: number, value: string | Uint8Array): Uint8Array {
  const data = typeof value === "string" ? new TextEncoder().encode(value) : value;
  return protoMessage([varint((fieldNumber << 3) | 2), varint(data.length), data]);
}

function varint(value: number): Uint8Array {
  const bytes: number[] = [];
  let current = value;
  while (current >= 0x80) {
    bytes.push((current & 0x7f) | 0x80);
    current >>>= 7;
  }
  bytes.push(current);
  return new Uint8Array(bytes);
}

type TestField = { no: number; wt: number; value: number | Uint8Array };

function fields(data: Uint8Array): TestField[] {
  const output: TestField[] = [];
  let offset = 0;
  while (offset < data.length) {
    const tag = readVarint(data, offset);
    offset = tag.offset;
    const no = tag.value >> 3;
    const wt = tag.value & 7;
    if (wt === 0) {
      const value = readVarint(data, offset);
      offset = value.offset;
      output.push({ no, wt, value: value.value });
    } else if (wt === 2) {
      const length = readVarint(data, offset);
      offset = length.offset;
      output.push({ no, wt, value: data.slice(offset, offset + length.value) });
      offset += length.value;
    } else {
      throw new Error(`Unsupported wire type ${wt}`);
    }
  }
  return output;
}

function bytesField(fieldList: TestField[], no: number): Uint8Array {
  const field = fieldList.find((item) => item.no === no);
  if (!field || !(field.value instanceof Uint8Array)) throw new Error(`Missing bytes field ${no}`);
  return field.value;
}

function numberField(fieldList: TestField[], no: number): number {
  const field = fieldList.find((item) => item.no === no);
  if (!field || typeof field.value !== "number") throw new Error(`Missing number field ${no}`);
  return field.value;
}

function readVarint(data: Uint8Array, offset: number): { value: number; offset: number } {
  let value = 0;
  let shift = 0;
  while (offset < data.length) {
    const byte = data[offset++];
    value += (byte & 0x7f) * 2 ** shift;
    if ((byte & 0x80) === 0) return { value, offset };
    shift += 7;
  }
  throw new Error("Unexpected end of varint");
}
