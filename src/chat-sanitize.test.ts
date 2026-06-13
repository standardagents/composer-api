import { describe, expect, it } from "vitest";
import {
  assistantDisplayContent,
  sanitizeAssistantContent,
} from "./chat-sanitize";

describe("chat assistant sanitizer", () => {
  it("strips Composer final markers before rendering or persisting assistant content", () => {
    expect(sanitizeAssistantContent("<|final|>Hello")).toBe("Hello");
    expect(sanitizeAssistantContent("<｜final｜>Hello")).toBe("Hello");
    expect(sanitizeAssistantContent("< | final | >\nVisible answer")).toBe(
      "Visible answer",
    );
    expect(
      sanitizeAssistantContent("Hidden reasoning <｜final｜>\nVisible answer"),
    ).toBe("Visible answer");
  });

  it("hides partial marker prefixes while streaming", () => {
    expect(assistantDisplayContent("<")).toBe("");
    expect(assistantDisplayContent("< | fin")).toBe("");
    expect(assistantDisplayContent("<｜final")).toBe("");
    expect(assistantDisplayContent("</thi")).toBe("");
  });

  it("leaves normal assistant text alone", () => {
    expect(assistantDisplayContent("Plain answer")).toBe("Plain answer");
  });
});
