import { describe, expect, it } from "vitest";
import { prepareChatRequest, prepareResponsesRequest, chatCompletionResponse, responseObject, toOpenAiToolCalls } from "./openai";

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
              { type: "image_url", image_url: { url: "https://example.com/image.png", width: 640, height: 480 } }
            ]
          }
        ],
        max_tokens: 50
      },
      { id: "composer-2.5" }
    );
    expect(prepared.prompt.text).toContain("SYSTEM: Be terse.");
    expect(prepared.prompt.text).toContain("USER: What is this?");
    expect(prepared.prompt.text).toContain("within about 50 output tokens");
    expect(prepared.prompt.images).toEqual([{ url: "https://example.com/image.png", dimension: { width: 640, height: 480 } }]);
  });

  it("converts Responses input images into Cursor prompts", () => {
    const prepared = prepareResponsesRequest(
      {
        model: "composer-2.5",
        input: [
          {
            role: "user",
            content: [
              { type: "input_text", text: "What is in this image?" },
              {
                type: "input_image",
                image_url: {
                  url: "data:image/jpeg;base64,AQID",
                  width: 320,
                  height: 240
                }
              }
            ]
          }
        ]
      },
      { id: "composer-2.5" }
    );

    expect(prepared.prompt.text).toContain("USER: What is in this image?");
    expect(prepared.prompt.images).toEqual([
      { mimeType: "image/jpeg", data: "AQID", dimension: { width: 320, height: 240 } }
    ]);
  });

  it("accepts OpenAI function tools and includes them in the Cursor prompt", () => {
    const prepared = prepareChatRequest(
      {
        model: "composer-2.5",
        messages: [{ role: "user", content: "list files" }],
        tools: [
          {
            type: "function",
            function: {
              name: "glob",
              description: "Find files",
              parameters: { type: "object", properties: { pattern: { type: "string" } } }
            }
          }
        ]
      },
      { id: "composer-2.5" }
    );
    expect(prepared.tools).toEqual([
      {
        name: "glob",
        description: "Find files",
        parameters: { type: "object", properties: { pattern: { type: "string" } } }
      }
    ]);
    expect(prepared.prompt.mode).toBe("agent");
    expect(prepared.prompt.text).toContain("already in Agent mode");
    expect(prepared.prompt.text).toContain("Never claim that tools are unavailable");
    expect(prepared.prompt.text).toContain("CLIENT TOOL INVENTORY:");
    expect(prepared.prompt.text).toContain("Allowed tool names: glob");
    expect(prepared.prompt.text).toContain("Switched to agent mode successfully");
    expect(prepared.prompt.text).toContain('"name":"glob"');
  });

  it("requires workspace tools for create/build style requests", () => {
    const prepared = prepareChatRequest(
      {
        model: "composer-2.5",
        messages: [{ role: "user", content: "make me a simple landing page" }],
        tools: [
          {
            type: "function",
            function: {
              name: "write",
              description: "Write a file",
              parameters: { type: "object", properties: { filePath: { type: "string" }, content: { type: "string" } } }
            }
          }
        ]
      },
      { id: "composer-2.5" }
    );

    expect(prepared.prompt.text).toContain("WORKSPACE MUTATION REQUIRED:");
    expect(prepared.prompt.text).toContain("Do not output a standalone file for the user to save");
    expect(prepared.prompt.text).toContain("Your next assistant response must be a write/edit/bash tool call");
    expect(prepared.prompt.text).toContain("Workspace action required");
  });

  it("does not force another mutation tool after one has been called", () => {
    const prepared = prepareChatRequest(
      {
        model: "composer-2.5",
        messages: [
          { role: "user", content: "make me a simple landing page" },
          {
            role: "assistant",
            content: null,
            tool_calls: [{ id: "call_1", type: "function", function: { name: "write", arguments: "{\"filePath\":\"index.html\"}" } }]
          },
          { role: "tool", tool_call_id: "call_1", name: "write", content: "Wrote file successfully." }
        ],
        tools: [
          {
            type: "function",
            function: {
              name: "write",
              description: "Write a file",
              parameters: { type: "object", properties: { filePath: { type: "string" }, content: { type: "string" } } }
            }
          }
        ]
      },
      { id: "composer-2.5" }
    );

    expect(prepared.prompt.text).toContain("A file-mutating tool call has already been made");
    expect(prepared.prompt.text).not.toContain("Your next assistant response must be a write/edit/bash tool call");
  });

  it("converts Responses input arrays", () => {
    const prepared = prepareResponsesRequest(
      {
        model: "composer-2.5",
        instructions: "Use JSON.",
        input: [{ role: "user", content: [{ type: "input_text", text: "hello" }] }],
        text: { format: { type: "json_object" } }
      },
      { id: "composer-2.5" }
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

  it("returns OpenAI-shaped tool call responses", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [{ name: "glob", parameters: { type: "object", properties: { pattern: { type: "string" } } } }],
      toolCalls: [{ name: "Glob", arguments: { glob_pattern: "*" } }]
    });
    const chat = chatCompletionResponse({
      id: "chatcmpl_test",
      created: 1,
      model: "composer-2.5",
      text: "",
      toolCalls,
      promptChars: 20
    });
    expect(chat).toMatchObject({
      choices: [
        {
          message: {
            role: "assistant",
            content: null,
            tool_calls: [{ type: "function", function: { name: "glob", arguments: "{\"pattern\":\"*\"}" } }]
          },
          finish_reason: "tool_calls"
        }
      ]
    });
  });
});
