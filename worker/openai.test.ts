import { describe, expect, it } from "vitest";
import { HttpError } from "./http";
import { prepareChatRequest, prepareResponsesRequest, chatCompletionResponse, responseObject } from "./openai";

describe("OpenAI compatibility adapter", () => {
  it("converts chat messages and image URLs into Cursor prompts", () => {
    const prepared = prepareChatRequest(
      {
        model: "composer-2.5",
        messages: [
          { role: "system", content: "Be terse." },
          {
            role: "user",
            content: [
              { type: "text", text: "What is this?" },
              { type: "image_url", image_url: { url: "https://example.com/image.png" } }
            ]
          }
        ],
        max_tokens: 50
      },
      { id: "composer-latest" }
    );
    expect(prepared.prompt.text).toContain("SYSTEM: Be terse.");
    expect(prepared.prompt.text).toContain("USER: What is this?");
    expect(prepared.prompt.text).toContain("within about 50 output tokens");
    expect(prepared.prompt.images).toEqual([{ url: "https://example.com/image.png" }]);
  });

  it("rejects unsupported OpenAI function tools", () => {
    expect(() =>
      prepareChatRequest(
        {
          model: "composer-2.5",
          messages: [{ role: "user", content: "hi" }],
          tools: [{ type: "function", function: { name: "x" } }]
        },
        { id: "composer-latest" }
      )
    ).toThrow(HttpError);
  });

  it("converts Responses input arrays", () => {
    const prepared = prepareResponsesRequest(
      {
        model: "composer-2.5",
        instructions: "Use JSON.",
        input: [{ role: "user", content: [{ type: "input_text", text: "hello" }] }],
        text: { format: { type: "json_object" } }
      },
      { id: "composer-latest" }
    );
    expect(prepared.prompt.text).toContain("INSTRUCTIONS:");
    expect(prepared.prompt.text).toContain("USER: hello");
    expect(prepared.prompt.text).toContain("valid JSON object");
  });

  it("returns OpenAI-shaped response objects", () => {
    const chat = chatCompletionResponse({
      id: "chatcmpl_test",
      created: 1,
      model: "composer-2.5",
      text: "hello",
      promptChars: 20
    });
    expect(chat).toMatchObject({
      object: "chat.completion",
      choices: [{ message: { role: "assistant", content: "hello" } }]
    });

    const response = responseObject({
      id: "resp_test",
      created: 1,
      model: "composer-2.5",
      text: "hello",
      promptChars: 20
    });
    expect(response).toMatchObject({
      object: "response",
      output: [{ type: "message", content: [{ type: "output_text", text: "hello" }] }]
    });
  });
});
