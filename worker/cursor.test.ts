import { describe, expect, it } from "vitest";
import { streamCursorText } from "./cursor";
import { encodeSse } from "./sse";

describe("Cursor stream adapter", () => {
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
      { type: "done", finalText: "Hello world" }
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
    expect(events.at(-1)).toEqual({ type: "done", finalText: "Legacy text" });
  });
});
