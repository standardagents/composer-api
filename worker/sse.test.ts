import { describe, expect, it } from "vitest";
import { encodeSse, parseSse } from "./sse";

describe("SSE helpers", () => {
  it("encodes and parses event frames", async () => {
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(encodeSse({ type: "hello", text: "hi" }, "message"));
        controller.close();
      }
    });
    const events = [];
    for await (const event of parseSse(stream)) events.push(event);
    expect(events).toEqual([
      {
        event: "message",
        data: JSON.stringify({ type: "hello", text: "hi" })
      }
    ]);
  });
});
