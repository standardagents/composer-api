import { describe, expect, it } from "vitest";
import {
  prepareChatRequest,
  prepareOpencodeSdkChatRequest,
  prepareResponsesRequest,
  chatCompletionResponse,
  chatUsageChunk,
  responseObject,
  toOpenAiToolCalls
} from "./openai";

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

  it("accepts bare harness tools with input_schema and maps SDK glob arguments to that schema", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [{ role: "user", content: "find source files" }],
        tools: [
          {
            name: "glob",
            description: "Find files",
            input_schema: {
              type: "object",
              additionalProperties: false,
              properties: {
                pattern: { type: "string" },
                path: { type: "string" }
              },
              required: ["pattern"]
            }
          }
        ]
      },
      { id: "composer-2.5-sdk" }
    );

    expect(prepared.tools).toEqual([
      {
        name: "glob",
        description: "Find files",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            pattern: { type: "string" },
            path: { type: "string" }
          },
          required: ["pattern"]
        }
      }
    ]);

    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: prepared.tools,
      toolCalls: [{ name: "glob", arguments: { targetDirectory: "src", globPattern: "**/*.tsx" } }]
    });

    expect(toolCalls[0].function.name).toBe("glob");
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({ pattern: "**/*.tsx", path: "src" });
  });

  it("accepts server tool schemas and skips nameless built-in response tools", () => {
    const prepared = prepareResponsesRequest(
      {
        model: "composer-2.5",
        input: "search the repo",
        tools: [
          { type: "web_search_preview" },
          {
            type: "server_tool",
            name: "repo_search",
            description: "Search repository symbols",
            inputSchema: {
              type: "object",
              properties: {
                query: { type: "string" }
              },
              required: ["query"]
            }
          }
        ]
      },
      { id: "composer-2.5" }
    );

    expect(prepared.tools).toEqual([
      {
        name: "repo_search",
        description: "Search repository symbols",
        parameters: {
          type: "object",
          properties: {
            query: { type: "string" }
          },
          required: ["query"]
        }
      }
    ]);
    expect(prepared.prompt.text).toContain("Allowed tool names: repo_search");
    expect(prepared.responseMetadata.tools).toEqual([
      {
        type: "function",
        name: "repo_search",
        description: "Search repository symbols",
        parameters: {
          type: "object",
          properties: {
            query: { type: "string" }
          },
          required: ["query"]
        }
      }
    ]);
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

  it("keeps SDK workspace mutation required after non-mutating shell probes", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          { role: "user", content: "build a complete TypeScript CLI project" },
          {
            role: "assistant",
            content: null,
            tool_calls: [{ id: "call_ls", type: "function", function: { name: "bash", arguments: "{\"command\":\"pwd && ls -la\"}" } }]
          },
          { role: "tool", tool_call_id: "call_ls", name: "bash", content: "{\"exitCode\":0,\"stdout\":\"empty\",\"stderr\":\"\"}" }
        ],
        tools: [
          {
            type: "function",
            function: {
              name: "bash",
              description: "Run a shell command",
              parameters: { type: "object", properties: { command: { type: "string" } }, required: ["command"] }
            }
          }
        ]
      },
      { id: "composer-2.5-sdk" }
    );

    expect(prepared.prompt.text).toContain("SDK WORKSPACE MUTATION REQUIRED:");
    expect(prepared.prompt.text).toContain("When starting a dev server or other long-running watcher");
    expect(prepared.prompt.text).toContain("No file-mutating tool call has been made yet");
    expect(prepared.prompt.text).not.toContain("A file-mutating tool call has already been made");
  });

  it("requires SDK workspace mutation for schema-compatible custom writers", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [{ role: "user", content: "build a todo app in vite 8 and react" }],
        tools: [
          {
            type: "function",
            function: {
              name: "project_files",
              parameters: {
                type: "object",
                properties: {
                  input: {
                    type: "object",
                    properties: {
                      action: { type: "string", enum: ["read", "write", "replace", "delete"] },
                      path: { type: "string" },
                      content: { type: "string" },
                      old: { type: "string" },
                      replacement: { type: "string" }
                    },
                    required: ["action", "path"]
                  }
                },
                required: ["input"]
              }
            }
          }
        ]
      },
      { id: "composer-2.5-sdk" }
    );

    expect(prepared.prompt.text).toContain("SDK WORKSPACE MUTATION REQUIRED:");
    expect(prepared.prompt.text).toContain("Your next tool call must be write or shell");
    expect(prepared.requiresLocalTool).toBe(true);
  });

  it("marks SDK workspace mutation done after a schema-compatible custom writer call", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          { role: "user", content: "build a todo app in vite 8 and react" },
          {
            role: "assistant",
            content: null,
            tool_calls: [
              {
                id: "call_project_file",
                type: "function",
                function: {
                  name: "project_files",
                  arguments: JSON.stringify({
                    input: {
                      action: "write",
                      path: "src/App.tsx",
                      content: "export default function App() { return null; }"
                    }
                  })
                }
              }
            ]
          },
          { role: "tool", tool_call_id: "call_project_file", name: "project_files", content: "Wrote src/App.tsx" }
        ],
        tools: [
          {
            type: "function",
            function: {
              name: "project_files",
              parameters: {
                type: "object",
                properties: {
                  input: {
                    type: "object",
                    properties: {
                      action: { type: "string", enum: ["read", "write", "replace", "delete"] },
                      path: { type: "string" },
                      content: { type: "string" },
                      old: { type: "string" },
                      replacement: { type: "string" }
                    },
                    required: ["action", "path"]
                  }
                },
                required: ["input"]
              }
            }
          }
        ]
      },
      { id: "composer-2.5-sdk" }
    );

    expect(prepared.prompt.text).toContain("A file-mutating tool call has already been made");
    expect(prepared.prompt.text).not.toContain("No file-mutating tool call has been made yet");
    expect(prepared.requiresLocalTool).toBe(false);
  });

  it("does not force SDK workspace mutation when no writable or shell tool is compatible", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [{ role: "user", content: "build a todo app in vite 8 and react" }],
        tools: [
          {
            type: "function",
            function: {
              name: "notify",
              parameters: {
                type: "object",
                properties: { message: { type: "string" } },
                required: ["message"]
              }
            }
          }
        ]
      },
      { id: "composer-2.5-sdk" }
    );

    expect(prepared.prompt.text).not.toContain("SDK WORKSPACE MUTATION REQUIRED:");
    expect(prepared.prompt.text).not.toContain("Your next tool call must be write or shell");
    expect(prepared.requiresLocalTool).toBe(false);
  });

  it("prefers explicitly requested OpenCode MCP tools in SDK prompts", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          { role: "user", content: "Use the probe_write_file tool, not bash, to create mcp-marker.txt containing MCP_OK." }
        ],
        tools: [
          {
            type: "function",
            function: {
              name: "bash",
              description: "Run a shell command",
              parameters: { type: "object", properties: { command: { type: "string" } }, required: ["command"] }
            }
          },
          {
            type: "function",
            function: {
              name: "probe_write_file",
              description: "Write through probe MCP",
              parameters: {
                type: "object",
                properties: { file_path: { type: "string" }, contents: { type: "string" } },
                required: ["file_path", "contents"]
              }
            }
          }
        ]
      },
      { id: "composer-2.5-sdk" }
    );

    expect(prepared.prompt.text).toContain('Use SDK mcp now with providerIdentifier "probe", toolName "write_file"');
    expect(prepared.prompt.text).toContain("Do not use SDK shell/write as a substitute");
    expect(prepared.prompt.text).toContain("OpenCode MCP/server tools exposed as provider_tool names should be requested with SDK mcp");
    expect(prepared.prompt.text).not.toContain("Your next tool call must be write or shell");
    expect(prepared.requiresLocalTool).toBe(true);
  });

  it("marks SDK workspace mutation done after a file-writing shell command", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          { role: "user", content: "build a complete TypeScript CLI project" },
          {
            role: "assistant",
            content: null,
            tool_calls: [
              {
                id: "call_write",
                type: "function",
                function: {
                  name: "bash",
                  arguments: "{\"command\":\"cat > package.json <<'EOF'\\n{\\\"type\\\":\\\"module\\\"}\\nEOF\"}"
                }
              }
            ]
          },
          { role: "tool", tool_call_id: "call_write", name: "bash", content: "{\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"\"}" }
        ],
        tools: [
          {
            type: "function",
            function: {
              name: "bash",
              description: "Run a shell command",
              parameters: { type: "object", properties: { command: { type: "string" } }, required: ["command"] }
            }
          }
        ]
      },
      { id: "composer-2.5-sdk" }
    );

    expect(prepared.prompt.text).toContain("A file-mutating tool call has already been made");
    expect(prepared.prompt.text).not.toContain("No file-mutating tool call has been made yet");
    expect(prepared.requiresLocalTool).toBe(false);
  });

  it("marks Responses workspace mutation done after an apply_patch function call", () => {
    const prepared = prepareResponsesRequest(
      {
        model: "composer-2.5",
        input: [
          { role: "user", content: [{ type: "input_text", text: "build a todo app in vite 8 and react" }] },
          {
            type: "function_call",
            call_id: "call_patch",
            name: "apply_patch",
            arguments: JSON.stringify({
              patch: "*** Begin Patch\n*** Add File: src/App.tsx\n+export default function App() { return null; }\n*** End Patch"
            })
          },
          { type: "function_call_output", call_id: "call_patch", output: "Done" }
        ],
        tools: [
          {
            type: "function",
            name: "apply_patch",
            parameters: {
              type: "object",
              properties: {
                patch: { type: "string" }
              },
              required: ["patch"]
            }
          }
        ]
      },
      { id: "composer-2.5" }
    );

    expect(prepared.prompt.text).toContain("A file-mutating tool call has already been made");
    expect(prepared.prompt.text).not.toContain("Use SDK write now");
    expect(prepared.requiresLocalTool).toBe(false);
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

  it("accepts Responses function tools and carries function outputs into the prompt", () => {
    const prepared = prepareResponsesRequest(
      {
        model: "composer-2.5",
        input: [
          { role: "user", content: [{ type: "input_text", text: "build a todo app in vite 8 and react" }] },
          { type: "function_call", call_id: "call_1", name: "glob", arguments: "{\"pattern\":\"*\"}" },
          { type: "function_call_output", call_id: "call_1", output: "[]" }
        ],
        tools: [
          {
            type: "function",
            name: "glob",
            description: "Find files",
            parameters: { type: "object", properties: { pattern: { type: "string" } }, required: ["pattern"] }
          }
        ],
        tool_choice: "required"
      },
      { id: "composer-2.5" }
    );

    expect(prepared.tools).toEqual([
      {
        name: "glob",
        description: "Find files",
        parameters: { type: "object", properties: { pattern: { type: "string" } }, required: ["pattern"] }
      }
    ]);
    expect(prepared.prompt.mode).toBe("agent");
    expect(prepared.prompt.text).toContain("LOCAL TOOL INVENTORY:");
    expect(prepared.prompt.text).toContain("Allowed tool names: glob");
    expect(prepared.prompt.text).toContain("LOCAL TOOL RESULT:");
    expect(prepared.prompt.text).toContain("You must call at least one tool.");
    expect(prepared.responseMetadata.tools).toEqual([
      {
        type: "function",
        name: "glob",
        description: "Find files",
        parameters: { type: "object", properties: { pattern: { type: "string" } }, required: ["pattern"] }
      }
    ]);
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
      choices: [{ message: { role: "assistant", content: "hello" } }],
      usage: {
        cost: {
          estimated: true,
          pricing: {
            input_per_million_tokens_usd: 0.5,
            output_per_million_tokens_usd: 2.5
          }
        }
      }
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
      output: [{ type: "message", content: [{ type: "output_text", text: "hello" }] }],
      usage: {
        cost: {
          estimated: true,
          pricing: {
            input_per_million_tokens_usd: 0.5,
            output_per_million_tokens_usd: 2.5
          }
        }
      }
    });
  });

  it("emits an OpenAI-style final usage chunk for streamed chat", () => {
    const chunk = new TextDecoder().decode(
      chatUsageChunk({
        id: "chatcmpl_test",
        created: 1,
        model: "composer-2.5",
        promptChars: 20,
        completionChars: 5
      })
    );

    expect(chunk).toContain('"choices":[]');
    expect(chunk).toContain('"usage"');
    expect(chunk).toContain('"total_tokens"');
    expect(chunk).toContain('"total_usd"');
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

  it("normalizes Cursor-style tool names and arguments to the client schema", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "write",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              filePath: { type: "string" },
              content: { type: "string" }
            },
            required: ["filePath", "content"]
          }
        },
        {
          name: "edit",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              filePath: { type: "string" },
              oldString: { type: "string" },
              newString: { type: "string" }
            },
            required: ["filePath", "oldString", "newString"]
          }
        },
        {
          name: "bash",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: { command: { type: "string" } },
            required: ["command"]
          }
        }
      ],
      toolCalls: [
        { name: "write_file", arguments: { target_file: "index.html", new_contents: "<main>Hello</main>", extra: "drop me" } },
        { name: "edit_file", arguments: { path: "index.html", old_string: "Hello", new_contents: "Hi" } },
        { name: "run_terminal_cmd", arguments: { cmd: "npm test" } }
      ]
    });

    expect(toolCalls.map((call) => call.function.name)).toEqual(["write", "edit", "bash"]);
    expect(toolCalls.map((call) => JSON.parse(call.function.arguments))).toEqual([
      { filePath: "index.html", content: "<main>Hello</main>" },
      { filePath: "index.html", oldString: "Hello", newString: "Hi" },
      { command: "npm test" }
    ]);
  });

  it("maps Cursor SDK MCP calls to OpenCode server_tool functions", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "probe_write_file",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              file_path: { type: "string" },
              contents: { type: "string" },
              overwrite: { type: "boolean" }
            },
            required: ["file_path", "contents"]
          }
        }
      ],
      toolCalls: [
        {
          name: "mcp",
          arguments: {
            providerIdentifier: "probe",
            toolName: "write_file",
            args: {
              file_path: "src/App.tsx",
              contents: "export default function App() { return null }",
              overwrite: true
            }
          }
        }
      ]
    });

    expect(toolCalls[0].function.name).toBe("probe_write_file");
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({
      file_path: "src/App.tsx",
      contents: "export default function App() { return null }",
      overwrite: true
    });
  });

  it("feeds OpenCode server tool results back as completed SDK MCP calls", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          { role: "user", content: "Use the filesystem write_file MCP tool." },
          {
            role: "assistant",
            content: null,
            tool_calls: [
              {
                id: "call_mcp",
                type: "function",
                function: {
                  name: "mcp__filesystem__write_file",
                  arguments: JSON.stringify({
                    file_path: "src/App.tsx",
                    contents: "export default function App() { return null }"
                  })
                }
              }
            ]
          },
          { role: "tool", tool_call_id: "call_mcp", name: "mcp__filesystem__write_file", content: "{\"content\":\"ok\"}" }
        ],
        tools: [
          {
            type: "function",
            function: {
              name: "mcp__filesystem__write_file",
              parameters: {
                type: "object",
                properties: {
                  file_path: { type: "string" },
                  contents: { type: "string" }
                },
                required: ["file_path", "contents"]
              }
            }
          }
        ]
      },
      { id: "composer-2.5-sdk" }
    );

    const line = prepared.prompt.text
      .split("\n")
      .find((item) => item.startsWith("LOCAL OPENCODE TOOL RESULT: "));
    expect(line).toBeTruthy();
    const feedback = JSON.parse(line!.slice("LOCAL OPENCODE TOOL RESULT: ".length));
    expect(feedback.name).toBe("mcp");
    expect(feedback.args).toEqual({
      providerIdentifier: "filesystem",
      toolName: "write_file",
      args: {
        file_path: "src/App.tsx",
        contents: "export default function App() { return null }"
      }
    });
    expect(feedback.result).toEqual({ status: "success", value: { content: "ok" } });
  });

  it("maps SDK builtins to schema-compatible prefixed server tools", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "probe_write_file",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              file_path: { type: "string" },
              contents: { type: "string" }
            },
            required: ["file_path", "contents"]
          }
        }
      ],
      toolCalls: [
        {
          name: "write",
          arguments: {
            path: "src/App.tsx",
            fileText: "export default function App() { return null }"
          }
        }
      ]
    });

    expect(toolCalls[0].function.name).toBe("probe_write_file");
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({
      file_path: "src/App.tsx",
      contents: "export default function App() { return null }"
    });
  });

  it("maps SDK ls calls to glob tools when a client has no ls tool", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "glob",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              pattern: { type: "string" },
              path: { type: "string" }
            },
            required: ["pattern"]
          }
        }
      ],
      toolCalls: [{ name: "ls", arguments: { path: "src" } }]
    });

    expect(toolCalls[0].function.name).toBe("glob");
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({ pattern: "*", path: "src" });
  });

  it("emulates SDK file writes through shell when shell is the only compatible client tool", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "bash",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              command: { type: "string" },
              description: { type: "string" }
            },
            required: ["command", "description"]
          }
        }
      ],
      toolCalls: [{ name: "write", arguments: { path: "src/App.tsx", fileText: "hello\nworld" } }]
    });

    expect(toolCalls[0].function.name).toBe("bash");
    const args = JSON.parse(toolCalls[0].function.arguments);
    expect(args.command).toContain("cat > 'src/App.tsx'");
    expect(args.command).toContain("hello\nworld");
    expect(args.description).toContain("mkdir -p");
  });

  it("maps Cursor SDK MCP calls to generic wrapper functions", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "call_mcp_tool",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              serverName: { type: "string" },
              toolName: { type: "string" },
              arguments: { type: "object" }
            },
            required: ["serverName", "toolName", "arguments"]
          }
        }
      ],
      toolCalls: [
        {
          name: "mcp",
          arguments: {
            providerIdentifier: "filesystem",
            toolName: "write_file",
            args: { file_path: "src/App.tsx", contents: "ok" }
          }
        }
      ]
    });

    expect(toolCalls[0].function.name).toBe("call_mcp_tool");
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({
      serverName: "filesystem",
      toolName: "write_file",
      arguments: { file_path: "src/App.tsx", contents: "ok" }
    });
  });

  it("drops synthetic SDK shell workdirs so OpenCode uses its local cwd", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "bash",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: { command: { type: "string" }, workdir: { type: "string" } },
            required: ["command"]
          }
        }
      ],
      toolCalls: [{ name: "shell", arguments: { command: "npm install && npm test", workingDirectory: "/workspace" } }]
    });

    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({ command: "npm install && npm test" });
  });

  it("backgrounds SDK server shell calls so OpenCode is not blocked", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "bash",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              command: { type: "string" },
              workdir: { type: "string" },
              description: { type: "string" }
            },
            required: ["command", "description"]
          }
        }
      ],
      toolCalls: [
        {
          name: "shell",
          arguments: {
            command: "python3 -m http.server 8080",
            workingDirectory: "/Users/example/site"
          }
        }
      ]
    });

    const args = JSON.parse(toolCalls[0].function.arguments) as Record<string, string>;
    expect(args.command).toContain("nohup sh -lc 'python3 -m http.server 8080'");
    expect(args.command).toMatch(/\/tmp\/opencode-background-[0-9a-f]{8}\.log/);
    expect(args.command).toContain("& echo \"Started background process pid=$!");
    expect(args.workdir).toBe("/Users/example/site");
    expect(args.description).toBe("Starts background process: Runs python3 -m http.server 8080");
  });

  it("prefers glob patterns over Cursor targeting when both are emitted", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "glob",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: { pattern: { type: "string" } },
            required: ["pattern"]
          }
        }
      ],
      toolCalls: [{ name: "file_search", arguments: { targeting: "/Users/example/project/**", glob_pattern: "*.ts" } }]
    });

    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({ pattern: "*.ts" });
  });

  it("defaults empty SDK glob calls to a valid OpenCode workspace glob", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "glob",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: { pattern: { type: "string" } },
            required: ["pattern"]
          }
        }
      ],
      toolCalls: [{ name: "glob", arguments: {} }]
    });

    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({ pattern: "*" });
  });

  it("maps SDK glob calls to query-based file search schemas", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "file_search",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              query: { type: "string" },
              basePath: { type: "string" }
            },
            required: ["query"]
          }
        }
      ],
      toolCalls: [{ name: "glob", arguments: { globPattern: "**/*.tsx", targetDirectory: "src" } }]
    });

    expect(toolCalls[0].function.name).toBe("file_search");
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({ query: "**/*.tsx", basePath: "src" });
  });

  it("maps SDK ls calls to query-based file search schemas", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "find_files",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              filePattern: { type: "string" },
              root: { type: "string" }
            },
            required: ["filePattern"]
          }
        }
      ],
      toolCalls: [{ name: "ls", arguments: { path: "src" } }]
    });

    expect(toolCalls[0].function.name).toBe("find_files");
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({ filePattern: "*", root: "src" });
  });

  it("does not map SDK glob calls to generic semantic query tools", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "semantic_search",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: { query: { type: "string" } },
            required: ["query"]
          }
        }
      ],
      toolCalls: [{ name: "glob", arguments: { globPattern: "**/*.tsx" } }]
    });

    expect(toolCalls).toEqual([]);
  });

  it("maps SDK file operations to Anthropic-style text editor schemas", () => {
    const tools = [
      {
        name: "str_replace_editor",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            command: { type: "string" },
            path: { type: "string" },
            file_text: { type: "string" },
            old_str: { type: "string" },
            new_str: { type: "string" },
            view_range: { type: "array", items: { type: "integer" } }
          },
          required: ["command", "path"]
        }
      }
    ];

    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools,
      toolCalls: [
        { name: "write", arguments: { path: "src/App.tsx", fileText: "export default function App() { return null }" } },
        { name: "read", arguments: { path: "src/App.tsx", offset: 10, limit: 20 } },
        { name: "edit", arguments: { path: "src/App.tsx", oldString: "Hello", newString: "Hi" } }
      ]
    });

    expect(toolCalls.map((call) => call.function.name)).toEqual(["str_replace_editor", "str_replace_editor", "str_replace_editor"]);
    expect(toolCalls.map((call) => JSON.parse(call.function.arguments))).toEqual([
      { command: "create", path: "src/App.tsx", file_text: "export default function App() { return null }" },
      { command: "view", path: "src/App.tsx", view_range: [10, 29] },
      { command: "str_replace", path: "src/App.tsx", old_str: "Hello", new_str: "Hi" }
    ]);
  });

  it("maps SDK file operations to action-based compound file tools", () => {
    const tools = [
      {
        name: "file_manager",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            action: { type: "string", enum: ["read", "write", "replace", "delete"] },
            path: { type: "string" },
            content: { type: "string" },
            old: { type: "string" },
            replacement: { type: "string" },
            offset: { type: "integer" },
            limit: { type: "integer" }
          },
          required: ["action", "path"]
        }
      }
    ];

    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools,
      toolCalls: [
        { name: "write", arguments: { path: "src/App.tsx", fileText: "export default function App() { return null }" } },
        { name: "read", arguments: { path: "src/App.tsx", offset: 5, limit: 10 } },
        { name: "edit", arguments: { path: "src/App.tsx", oldString: "Hello", newString: "Hi" } },
        { name: "delete", arguments: { path: "src/old.tsx" } }
      ]
    });

    expect(toolCalls.map((call) => call.function.name)).toEqual(["file_manager", "file_manager", "file_manager", "file_manager"]);
    expect(toolCalls.map((call) => JSON.parse(call.function.arguments))).toEqual([
      { action: "write", path: "src/App.tsx", content: "export default function App() { return null }" },
      { action: "read", path: "src/App.tsx", offset: 5, limit: 10 },
      { action: "replace", path: "src/App.tsx", old: "Hello", replacement: "Hi" },
      { action: "delete", path: "src/old.tsx" }
    ]);
  });

  it("maps SDK edit streamContent calls to write-compatible tools", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "write_file",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              filePath: { type: "string" },
              content: { type: "string" }
            },
            required: ["filePath", "content"]
          }
        }
      ],
      toolCalls: [
        {
          name: "edit",
          arguments: {
            path: "src/App.tsx",
            streamContent: "export default function App() { return null }"
          }
        }
      ]
    });

    expect(toolCalls[0].function.name).toBe("write_file");
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({
      filePath: "src/App.tsx",
      content: "export default function App() { return null }"
    });
  });

  it("maps SDK calls into wrapper object tool schemas", () => {
    const tools = [
      {
        name: "wrapped_bash",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            input: {
              type: "object",
              additionalProperties: false,
              properties: {
                command: { type: "string" },
                workdir: { type: "string" }
              },
              required: ["command"]
            }
          },
          required: ["input"]
        }
      },
      {
        name: "wrapped_files",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            input: {
              type: "object",
              additionalProperties: false,
              properties: {
                action: { type: "string", enum: ["read", "write", "replace", "delete"] },
                path: { type: "string" },
                content: { type: "string" },
                old: { type: "string" },
                replacement: { type: "string" }
              },
              required: ["action", "path"]
            }
          },
          required: ["input"]
        }
      }
    ];

    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools,
      toolCalls: [
        { name: "shell", arguments: { command: "npm test", workingDirectory: "/tmp/app" } },
        { name: "write", arguments: { path: "src/App.tsx", fileText: "export default function App() { return null }" } },
        { name: "edit", arguments: { path: "src/App.tsx", oldString: "Hello", newString: "Hi" } }
      ]
    });

    expect(toolCalls.map((call) => call.function.name)).toEqual(["wrapped_bash", "wrapped_files", "wrapped_files"]);
    expect(toolCalls.map((call) => JSON.parse(call.function.arguments))).toEqual([
      { input: { command: "npm test", workdir: "/tmp/app" } },
      { input: { action: "write", path: "src/App.tsx", content: "export default function App() { return null }" } },
      { input: { action: "replace", path: "src/App.tsx", old: "Hello", replacement: "Hi" } }
    ]);
  });

  it("maps SDK patchContent edits to apply-patch style tools", () => {
    const patch = [
      "*** Begin Patch",
      "*** Update File: src/App.tsx",
      "@@",
      "-return null",
      "+return <main />",
      "*** End Patch"
    ].join("\n");
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "apply_patch",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              patch: { type: "string" },
              path: { type: "string" }
            },
            required: ["patch"]
          }
        }
      ],
      toolCalls: [{ name: "edit", arguments: { path: "src/App.tsx", patchContent: patch } }]
    });

    expect(toolCalls[0].function.name).toBe("apply_patch");
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({
      path: "src/App.tsx",
      patch
    });
  });

  it("maps SDK file operations to apply-patch style tools", () => {
    const tools = [
      {
        name: "apply_patch",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            patch: { type: "string" },
            path: { type: "string" }
          },
          required: ["patch"]
        }
      }
    ];

    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools,
      toolCalls: [
        { name: "write", arguments: { path: "src/App.tsx", fileText: "export default function App() {\n  return null\n}\n" } },
        { name: "edit", arguments: { path: "src/App.tsx", oldString: "return null", newString: "return <main />" } },
        { name: "delete", arguments: { path: "src/old.tsx" } }
      ]
    });

    expect(toolCalls.map((call) => call.function.name)).toEqual(["apply_patch", "apply_patch", "apply_patch"]);
    expect(toolCalls.map((call) => JSON.parse(call.function.arguments))).toEqual([
      {
        path: "src/App.tsx",
        patch: [
          "*** Begin Patch",
          "*** Add File: src/App.tsx",
          "+export default function App() {",
          "+  return null",
          "+}",
          "*** End Patch"
        ].join("\n")
      },
      {
        path: "src/App.tsx",
        patch: [
          "*** Begin Patch",
          "*** Update File: src/App.tsx",
          "@@",
          "-return null",
          "+return <main />",
          "*** End Patch"
        ].join("\n")
      },
      {
        path: "src/old.tsx",
        patch: [
          "*** Begin Patch",
          "*** Delete File: src/old.tsx",
          "*** End Patch"
        ].join("\n")
      }
    ]);
  });

  it("does not emit SDK-native tool names outside the advertised client tools", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "notify",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: { message: { type: "string" } },
            required: ["message"]
          }
        }
      ],
      toolCalls: [{ name: "shell", arguments: { command: "pwd" } }]
    });

    expect(toolCalls).toEqual([]);
  });

  it("keeps raw SDK tool calls only when the client did not provide a tool inventory", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [],
      toolCalls: [{ name: "shell", arguments: { command: "pwd" } }]
    });

    expect(toolCalls[0].function.name).toBe("shell");
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({ command: "pwd" });
  });
});
