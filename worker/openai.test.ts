import { describe, expect, it } from "vitest";
import {
  prepareChatRequest,
  prepareOpencodeSdkChatRequest,
  prepareResponsesRequest,
  chatCompletionResponse,
  chatUsageChunk,
  responseObject,
  toolCallRetryHint,
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
    expect(prepared.prompt.text).toContain("You are serving an OpenAI-compatible API request.");
    expect(prepared.prompt.text).not.toContain("through Cursor Composer");
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

    expect(prepared.prompt.text).toContain("You are serving an OpenAI-compatible API request.");
    expect(prepared.prompt.text).not.toContain("through Cursor Composer");
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
    expect(prepared.prompt.text).not.toContain("through Cursor Composer");
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

  it("advertises pi find through the native SDK glob route", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [{ role: "user", content: "find source files" }],
        tool_choice: { type: "function", function: { name: "find" } },
        tools: [
          {
            name: "find",
            description: "Find files by glob pattern",
            input_schema: {
              type: "object",
              additionalProperties: false,
              properties: {
                pattern: { type: "string" },
                path: { type: "string" },
                limit: { type: "number" }
              },
              required: ["pattern"]
            }
          }
        ]
      },
      { id: "composer-2.5-sdk" }
    );

    expect(prepared.prompt.text).toContain('"name":"find"');
    expect(prepared.prompt.text).not.toContain('"sdk_mcp":{"providerIdentifier":"client","toolName":"find"');
    expect(prepared.prompt.text).toContain('"sdk":"glob","client":"find"');
    expect(prepared.prompt.text).toContain('Use SDK glob now; it will be forwarded to client tool find');

    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: prepared.tools,
      toolCalls: [{ name: "glob", arguments: { targetDirectory: "src", globPattern: "**/*.tsx" } }]
    });

    expect(toolCalls[0].function.name).toBe("find");
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({ pattern: "**/*.tsx", path: "src" });
  });

  it("maps exact SDK MCP calls to built-in client tool schemas", () => {
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
      toolCalls: [{ name: "mcp", arguments: { providerIdentifier: "client", toolName: "glob", args: { pattern: "**/*.tsx", path: "src" } } }]
    });

    expect(toolCalls[0].function.name).toBe("glob");
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({ pattern: "**/*.tsx", path: "src" });
  });

  it("maps SDK grep arguments to pi grep schemas", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "grep",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              pattern: { type: "string" },
              path: { type: "string" },
              glob: { type: "string" },
              ignoreCase: { type: "boolean" },
              literal: { type: "boolean" },
              context: { type: "number" },
              limit: { type: "number" }
            },
            required: ["pattern"]
          }
        }
      ],
      toolCalls: [
        {
          name: "grep",
          arguments: {
            pattern: "TODO",
            path: "src",
            glob: "*.tsx",
            caseInsensitive: true,
            literal: true,
            context: 2,
            headLimit: 10
          }
        }
      ]
    });

    expect(toolCalls[0].function.name).toBe("grep");
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({
      pattern: "TODO",
      path: "src",
      glob: "*.tsx",
      ignoreCase: true,
      literal: true,
      context: 2,
      limit: 10
    });
  });

  it("maps SDK edit arguments to pi edit schemas", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "edit",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              path: { type: "string" },
              oldText: { type: "string" },
              newText: { type: "string" }
            },
            required: ["path", "oldText", "newText"]
          }
        }
      ],
      toolCalls: [
        {
          name: "edit",
          arguments: {
            path: "src/App.tsx",
            oldString: "return null",
            newString: "return <main />"
          }
        }
      ]
    });

    expect(toolCalls[0].function.name).toBe("edit");
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({
      path: "src/App.tsx",
      oldText: "return null",
      newText: "return <main />"
    });
  });

  it("maps the full pi built-in tool schema matrix", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "bash",
          parameters: {
            type: "object",
            properties: { command: { type: "string" }, timeout: { type: "number", description: "Timeout in seconds (optional, no default timeout)" } },
            required: ["command"]
          }
        },
        {
          name: "read",
          parameters: { type: "object", properties: { path: { type: "string" }, offset: { type: "number" }, limit: { type: "number" } }, required: ["path"] }
        },
        {
          name: "write",
          parameters: { type: "object", properties: { path: { type: "string" }, content: { type: "string" } }, required: ["path", "content"] }
        },
        {
          name: "edit",
          parameters: { type: "object", properties: { path: { type: "string" }, oldText: { type: "string" }, newText: { type: "string" } }, required: ["path", "oldText", "newText"] }
        },
        {
          name: "find",
          parameters: { type: "object", properties: { pattern: { type: "string" }, path: { type: "string" }, limit: { type: "number" } }, required: ["pattern"] }
        },
        {
          name: "grep",
          parameters: {
            type: "object",
            properties: {
              pattern: { type: "string" },
              path: { type: "string" },
              glob: { type: "string" },
              ignoreCase: { type: "boolean" },
              literal: { type: "boolean" },
              context: { type: "number" },
              limit: { type: "number" }
            },
            required: ["pattern"]
          }
        },
        { name: "ls", parameters: { type: "object", properties: { path: { type: "string" }, limit: { type: "number" } } } }
      ],
      toolCalls: [
        { name: "shell", arguments: { command: "npm test", timeout: 120_000 } },
        { name: "read", arguments: { path: "src/App.tsx", offset: 5, limit: 20 } },
        { name: "write", arguments: { path: "src/App.tsx", fileText: "export default function App() { return null }" } },
        { name: "edit", arguments: { path: "src/App.tsx", oldString: "return null", newString: "return <main />" } },
        { name: "glob", arguments: { globPattern: "**/*.tsx", targetDirectory: "src" } },
        { name: "grep", arguments: { pattern: "TODO", path: "src", glob: "*.tsx", caseInsensitive: true, literal: true, context: 2, headLimit: 10 } },
        { name: "ls", arguments: { path: "src", limit: 50 } }
      ]
    });

    expect(toolCalls.map((call) => call.function.name)).toEqual(["bash", "read", "write", "edit", "find", "grep", "ls"]);
    expect(toolCalls.map((call) => JSON.parse(call.function.arguments))).toEqual([
      { command: "npm test", timeout: 120 },
      { path: "src/App.tsx", offset: 5, limit: 20 },
      { path: "src/App.tsx", content: "export default function App() { return null }" },
      { path: "src/App.tsx", oldText: "return null", newText: "return <main />" },
      { pattern: "**/*.tsx", path: "src" },
      { pattern: "TODO", path: "src", glob: "*.tsx", ignoreCase: true, literal: true, context: 2, limit: 10 },
      { path: "src", limit: 50 }
    ]);
  });

  it("uses OpenCode working directory to normalize SDK file and glob calls to real OpenCode schemas", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          {
            role: "system",
            content: [
              "Environment:",
              "  Working directory: /tmp/project",
              "  Workspace root folder: /tmp/project"
            ].join("\n")
          },
          { role: "user", content: "build a todo app in vite 8 and react" }
        ],
        tools: [
          {
            type: "function",
            function: {
              name: "write",
              description: "Writes a file to the local filesystem.",
              parameters: {
                type: "object",
                additionalProperties: false,
                properties: {
                  content: { type: "string", description: "The content to write to the file" },
                  filePath: { type: "string", description: "The absolute path to the file to write (must be absolute, not relative)" }
                },
                required: ["content", "filePath"]
              }
            }
          },
          {
            type: "function",
            function: {
              name: "read",
              description: "Read a file or directory from the local filesystem.",
              parameters: {
                type: "object",
                additionalProperties: false,
                properties: {
                  filePath: { type: "string", description: "The absolute path to the file or directory to read" }
                },
                required: ["filePath"]
              }
            }
          },
          {
            type: "function",
            function: {
              name: "edit",
              description: "Performs exact string replacements in files.",
              parameters: {
                type: "object",
                additionalProperties: false,
                properties: {
                  filePath: { type: "string", description: "The absolute path to the file to modify" },
                  oldString: { type: "string" },
                  newString: { type: "string" }
                },
                required: ["filePath", "oldString", "newString"]
              }
            }
          },
          {
            type: "function",
            function: {
              name: "glob",
              description: "Fast file pattern matching tool.",
              parameters: {
                type: "object",
                additionalProperties: false,
                properties: {
                  pattern: { type: "string", description: "The glob pattern to match files against" },
                  path: { type: "string", description: "The directory to search in" }
                },
                required: ["pattern"]
              }
            }
          }
        ]
      },
      { id: "composer-2.5-sdk" }
    );

    expect(prepared.toolContext).toEqual({ workingDirectory: "/tmp/project" });

    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: prepared.tools,
      context: prepared.toolContext,
      toolCalls: [
        { name: "write", arguments: { path: "src/App.tsx", fileText: "export default function App() { return null }" } },
        { name: "read", arguments: { path: "src/App.tsx" } },
        { name: "edit", arguments: { path: "src/App.tsx", oldString: "return null", newString: "return <main />" } },
        { name: "glob", arguments: { targeting: "src/**", glob_pattern: "*.tsx" } }
      ]
    });

    expect(toolCalls.map((call) => call.function.name)).toEqual(["write", "read", "edit", "glob"]);
    expect(toolCalls.map((call) => JSON.parse(call.function.arguments))).toEqual([
      { content: "export default function App() { return null }", filePath: "/tmp/project/src/App.tsx" },
      { filePath: "/tmp/project/src/App.tsx" },
      { filePath: "/tmp/project/src/App.tsx", oldString: "return null", newString: "return <main />" },
      { pattern: "**/*.tsx", path: "/tmp/project/src" }
    ]);
  });

  it("expands home-relative SDK paths for absolute OpenCode file schemas", () => {
    const tools = [
      {
        name: "write",
        parameters: {
          type: "object",
          properties: {
            filePath: { type: "string", description: "The absolute path to the file to write" },
            content: { type: "string" }
          },
          required: ["filePath", "content"]
        }
      }
    ];

    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_home_path",
      tools,
      context: { workingDirectory: "/Users/example/project" },
      toolCalls: [
        { name: "write", arguments: { path: "~/Desktop/rain-in-spain.html", fileText: "<main>Rain</main>" } }
      ]
    });

    expect(toolCalls.map((call) => JSON.parse(call.function.arguments))).toEqual([
      { filePath: "/Users/example/Desktop/rain-in-spain.html", content: "<main>Rain</main>" }
    ]);
  });

  it("maps the live OpenCode build tool matrix including unique client tools", () => {
    const openCodeBuildTools = [
      {
        name: "bash",
        parameters: {
          type: "object",
          properties: {
            command: { type: "string" },
            timeout: { type: "integer" },
            workdir: { type: "string" },
            description: { type: "string" }
          },
          required: ["command", "description"]
        }
      },
      {
        name: "edit",
        parameters: {
          type: "object",
          properties: {
            filePath: { type: "string", description: "The absolute path to the file to modify" },
            oldString: { type: "string" },
            newString: { type: "string" },
            replaceAll: { type: "boolean" }
          },
          required: ["filePath", "oldString", "newString"]
        }
      },
      {
        name: "glob",
        parameters: {
          type: "object",
          properties: {
            pattern: { type: "string" },
            path: { type: "string", description: "The directory to search in" }
          },
          required: ["pattern"]
        }
      },
      {
        name: "grep",
        parameters: {
          type: "object",
          properties: {
            pattern: { type: "string" },
            path: { type: "string" },
            include: { type: "string" }
          },
          required: ["pattern"]
        }
      },
      {
        name: "read",
        parameters: {
          type: "object",
          properties: {
            filePath: { type: "string", description: "The absolute path to the file or directory to read" },
            offset: { type: "integer" },
            limit: { type: "integer" }
          },
          required: ["filePath"]
        }
      },
      {
        name: "skill",
        parameters: {
          type: "object",
          properties: { name: { type: "string" } },
          required: ["name"]
        }
      },
      {
        name: "task",
        parameters: {
          type: "object",
          properties: {
            description: { type: "string" },
            prompt: { type: "string" },
            subagent_type: { type: "string" },
            task_id: { type: "string" },
            command: { type: "string" }
          },
          required: ["description", "prompt", "subagent_type"]
        }
      },
      {
        name: "todowrite",
        parameters: {
          type: "object",
          properties: {
            todos: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  content: { type: "string" },
                  status: { type: "string" },
                  priority: { type: "string" }
                },
                required: ["content", "status", "priority"]
              }
            }
          },
          required: ["todos"]
        }
      },
      {
        name: "webfetch",
        parameters: {
          type: "object",
          properties: {
            url: { type: "string" },
            format: { anyOf: [{ type: "string", enum: ["text", "markdown", "html"] }, { type: "null" }] },
            timeout: { type: "number" }
          },
          required: ["url"]
        }
      },
      {
        name: "write",
        parameters: {
          type: "object",
          properties: {
            content: { type: "string" },
            filePath: { type: "string", description: "The absolute path to the file to write (must be absolute, not relative)" }
          },
          required: ["content", "filePath"]
        }
      }
    ];

    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: openCodeBuildTools,
      context: { workingDirectory: "/tmp/project" },
      toolCalls: [
        { name: "shell", arguments: { command: "npm test", timeout: 120_000, workingDirectory: "/tmp/project" } },
        { name: "read", arguments: { path: "src/App.tsx", offset: 5, limit: 20 } },
        { name: "write", arguments: { path: "src/App.tsx", fileText: "export default function App() { return null }" } },
        { name: "edit", arguments: { path: "src/App.tsx", oldString: "return null", newString: "return <main />", replaceAll: true } },
        { name: "glob", arguments: { targetDirectory: "src", globPattern: "**/*.tsx" } },
        { name: "grep", arguments: { pattern: "TODO", path: "src", glob: "*.tsx" } },
        { name: "todowrite", arguments: { todos: [{ content: "Build app", status: "in_progress", priority: "high" }] } },
        { name: "delete", arguments: { path: "src/old.tsx" } },
        { name: "ls", arguments: { path: "src" } },
        { name: "semsearch", arguments: { query: "submit button", targetDirectories: ["src"] } },
        { name: "mcp", arguments: { providerIdentifier: "client", toolName: "webfetch", args: { url: "https://example.com", format: "markdown", timeout: 10 } } },
        {
          name: "mcp",
          arguments: {
            providerIdentifier: "client",
            toolName: "task",
            args: { description: "Inspect app", prompt: "Find the app entry point", subagent_type: "explore", command: "inspect" }
          }
        },
        { name: "mcp", arguments: { providerIdentifier: "client", toolName: "skill", args: { name: "customize-opencode" } } }
      ]
    });

    expect(toolCalls.map((call) => call.function.name)).toEqual([
      "bash",
      "read",
      "write",
      "edit",
      "glob",
      "grep",
      "todowrite",
      "bash",
      "glob",
      "bash",
      "webfetch",
      "task",
      "skill"
    ]);
    expect(toolCalls.map((call) => JSON.parse(call.function.arguments))).toEqual([
      { command: "npm test", timeout: 120_000, workdir: "/tmp/project", description: "Runs npm test" },
      { filePath: "/tmp/project/src/App.tsx", offset: 5, limit: 20 },
      { filePath: "/tmp/project/src/App.tsx", content: "export default function App() { return null }" },
      { filePath: "/tmp/project/src/App.tsx", oldString: "return null", newString: "return <main />", replaceAll: true },
      { pattern: "**/*.tsx", path: "/tmp/project/src" },
      { pattern: "TODO", path: "src", include: "*.tsx" },
      { todos: [{ content: "Build app", status: "in_progress", priority: "high" }] },
      { command: "rm -rf 'src/old.tsx'", description: "Runs rm -rf 'src/old.tsx'" },
      { pattern: "*", path: "src" },
      { command: "rg --line-number --color never --hidden 'submit button' 'src'", description: "Runs rg --line-number --color never --hidden" },
      { url: "https://example.com", format: "markdown", timeout: 10 },
      { description: "Inspect app", prompt: "Find the app entry point", subagent_type: "explore", command: "inspect" },
      { name: "customize-opencode" }
    ]);
  });

  it("maps a Vite React app-build flow through strict OpenCode schemas", () => {
    const tools = [
      {
        name: "bash",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            command: { type: "string" },
            cwd: { type: "string" },
            timeout_ms: { type: "number" },
            description: { type: "string" }
          },
          required: ["command", "cwd", "timeout_ms", "description"]
        }
      },
      {
        name: "glob",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            pattern: { type: "string" },
            path: { type: "string" }
          },
          required: ["pattern", "path"]
        }
      },
      {
        name: "write",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            filePath: { type: "string", description: "The absolute path to the file to write" },
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
            filePath: { type: "string", description: "The absolute path to the file to modify" },
            oldString: { type: "string" },
            newString: { type: "string" }
          },
          required: ["filePath", "oldString", "newString"]
        }
      }
    ];
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          { role: "system", content: "Working directory: /tmp/todo-vite" },
          { role: "user", content: "build a todo app in vite 8 and react" }
        ],
        tools
      },
      { id: "composer-2.5-sdk" }
    );

    expect(prepared.requiresLocalTool).toBe(true);
    expect(prepared.prompt.text).toContain("Client tool targets: bash, glob, write, edit");
    expect(prepared.prompt.text).not.toContain("Allowed tool names: bash");
    expect(prepared.prompt.text).toContain("SDK TOOL ROUTING MAP:");
    expect(prepared.prompt.text).toContain('"sdk":"glob","client":"glob","clientArgs":{"pattern":"**/*","path":"/tmp/todo-vite"}');
    expect(prepared.prompt.text).toContain('"sdk":"shell","client":"bash","clientArgs":{"command":"<command>","cwd":".","timeout_ms":120000');
    const generated = toOpenAiToolCalls({
      responseId: "chatcmpl_vite_flow",
      tools: prepared.tools,
      context: prepared.toolContext,
      toolCalls: [
        { name: "glob", arguments: { targetDirectory: "." } },
        { name: "shell", arguments: { command: "npm create vite@latest . -- --template react", workingDirectory: "/workspace" } },
        { name: "write", arguments: { path: "src/App.jsx", fileText: "export default function App() { return <main>Todos</main> }" } },
        { name: "edit", arguments: { path: "package.json", oldString: "\"scripts\": {", newString: "\"scripts\": {" } },
        { name: "shell", arguments: { command: "npm install && npm run build", timeout: 120_000 } }
      ]
    });

    expect(generated.map((call) => call.function.name)).toEqual(["glob", "bash", "write", "edit", "bash"]);
    expect(generated.map((call) => JSON.parse(call.function.arguments))).toEqual([
      { pattern: "**/*", path: "/tmp/todo-vite" },
      { command: "npm create vite@latest . -- --template react", cwd: ".", timeout_ms: 120_000, description: "Runs npm create vite@latest . --" },
      { filePath: "/tmp/todo-vite/src/App.jsx", content: "export default function App() { return <main>Todos</main> }" },
      { filePath: "/tmp/todo-vite/package.json", oldString: "\"scripts\": {", newString: "\"scripts\": {" },
      { command: "npm install && npm run build", cwd: ".", timeout_ms: 120_000, description: "Runs npm install && npm run" }
    ]);

    const continued = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          { role: "system", content: "Working directory: /tmp/todo-vite" },
          { role: "user", content: "build a todo app in vite 8 and react" },
          { role: "assistant", content: null, tool_calls: generated },
          { role: "tool", tool_call_id: generated[0].id, content: "{\"files\":[]}" },
          { role: "tool", tool_call_id: generated[1].id, content: "{\"exitCode\":0,\"stdout\":\"created\",\"stderr\":\"\"}" },
          { role: "tool", tool_call_id: generated[2].id, content: "{\"content\":\"ok\"}" },
          { role: "tool", tool_call_id: generated[3].id, content: "{\"diff\":\"ok\"}" },
          { role: "tool", tool_call_id: generated[4].id, content: "{\"exitCode\":0,\"stdout\":\"built\",\"stderr\":\"\"}" }
        ],
        tools
      },
      { id: "composer-2.5-sdk" }
    );
    const feedback = continued.prompt.text
      .split("\n")
      .filter((item) => item.startsWith("LOCAL OPENCODE TOOL RESULT: "))
      .map((line) => JSON.parse(line.slice("LOCAL OPENCODE TOOL RESULT: ".length)));

    expect(feedback.map((item) => item.name)).toEqual(["glob", "shell", "write", "edit", "shell"]);
    expect(feedback.map((item) => item.args)).toEqual([
      { targetDirectory: "." },
      { command: "npm create vite@latest . -- --template react", workingDirectory: "/workspace" },
      { path: "src/App.jsx", fileText: "export default function App() { return <main>Todos</main> }" },
      { path: "package.json", oldString: "\"scripts\": {", newString: "\"scripts\": {" },
      { command: "npm install && npm run build", timeout: 120_000 }
    ]);
  });

  it("keeps direct chat tools on direct tool-call syntax", () => {
    const prepared = prepareChatRequest(
      {
        model: "composer-2.5",
        messages: [{ role: "user", content: "Use the webfetch tool to fetch https://example.com" }],
        tool_choice: { type: "function", function: { name: "webfetch" } },
        tools: [
          {
            type: "function",
            function: {
              name: "webfetch",
              description: "Fetch a URL",
              parameters: {
                type: "object",
                properties: {
                  url: { type: "string" },
                  format: { type: "string" }
                },
                required: ["url"]
              }
            }
          }
        ]
      },
      { id: "composer-2.5" }
    );

    expect(prepared.prompt.text).toContain("CLIENT TOOL INVENTORY:");
    expect(prepared.prompt.text).toContain("Use the webfetch tool if you call a tool.");
    expect(prepared.prompt.text).not.toContain("sdk_mcp");
    expect(prepared.prompt.text).not.toContain("Use SDK mcp now");
  });

  it("advertises single-word non-builtin client tools through synthetic SDK MCP targets", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [{ role: "user", content: "Use the webfetch tool to fetch https://example.com" }],
        tool_choice: { type: "function", function: { name: "webfetch" } },
        tools: [
          {
            name: "webfetch",
            description: "Fetch a URL",
            input_schema: {
              type: "object",
              properties: {
                url: { type: "string" },
                format: { type: "string" }
              },
              required: ["url"]
            }
          }
        ]
      },
      { id: "composer-2.5-sdk" }
    );

    expect(prepared.prompt.text).toContain('"sdk_mcp":{"providerIdentifier":"client","toolName":"webfetch","args":"match this tool schema"}');
    expect(prepared.prompt.text).toContain('"sdk":"mcp","client":"webfetch","sdkArgs":{"providerIdentifier":"client","toolName":"webfetch","args":"match client schema"}');
    expect(prepared.prompt.text).toContain('Use SDK mcp now with providerIdentifier "client", toolName "webfetch"');
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
    expect(prepared.prompt.text).toContain("Client tool targets: repo_search");
    expect(prepared.prompt.text).toContain("These are client execution targets, not the names you should emit.");
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

  it("requires SDK local tools for explicit desktop file writes", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [{ role: "user", content: "Please save rain-in-spain.html on ~/Desktop with a short paragraph." }],
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

    expect(prepared.requiresLocalTool).toBe(true);
    expect(prepared.prompt.text).toContain("SDK WORKSPACE MUTATION REQUIRED:");
    expect(prepared.prompt.text).toContain("Your next tool call must be write or shell");
  });

  it("requires SDK local tools for server start requests", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [{ role: "user", content: "start the local dev server" }],
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

    expect(prepared.requiresLocalTool).toBe(true);
    expect(prepared.prompt.text).toContain("When starting a dev server or other long-running watcher");
  });

  it("requires SDK local tools for explicitly requested non-mutating tools", () => {
    const tools = [
      {
        type: "function",
        function: {
          name: "glob",
          description: "Find files",
          parameters: {
            type: "object",
            properties: { pattern: { type: "string" }, path: { type: "string" } },
            required: ["pattern"]
          }
        }
      }
    ];
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [{ role: "user", content: "Use the glob tool, not bash, to find **/*.tsx files." }],
        tools
      },
      { id: "composer-2.5-sdk" }
    );

    expect(prepared.requiresLocalTool).toBe(true);
    expect(prepared.prompt.text).toContain("Use SDK glob now; it will be forwarded to client tool glob");

    const generated = toOpenAiToolCalls({
      responseId: "chatcmpl_explicit_glob",
      tools: prepared.tools,
      toolCalls: [{ name: "mcp", arguments: { providerIdentifier: "client", toolName: "glob", args: { pattern: "**/*.tsx" } } }]
    });
    const continued = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          { role: "user", content: "Use the glob tool, not bash, to find **/*.tsx files." },
          { role: "assistant", content: null, tool_calls: generated },
          { role: "tool", tool_call_id: generated[0].id, name: "glob", content: "{\"files\":[\"src/App.tsx\"]}" }
        ],
        tools
      },
      { id: "composer-2.5-sdk" }
    );

    expect(continued.requiresLocalTool).toBe(false);
    expect(continued.prompt.text).not.toContain("No file-mutating tool call has been made yet");
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
    expect(prepared.prompt.text).toContain("When the user names a specific allowed client tool, use the matching SDK TOOL ROUTING MAP route");
    expect(prepared.prompt.text).not.toContain('"sdk":"read","client":"probe_write_file"');
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
    expect(prepared.prompt.text).toContain("Client tool targets: glob");
    expect(prepared.prompt.text).toContain("emit only SDK tool names from the SDK TOOL ROUTING MAP");
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

  it("feeds Responses pi bash outputs back with SDK millisecond timeout arguments", () => {
    const prepared = prepareResponsesRequest(
      {
        model: "composer-2.5",
        input: [
          { role: "user", content: "run tests" },
          { type: "function_call", call_id: "call_bash", name: "bash", arguments: "{\"command\":\"npm test\",\"timeout\":120}" },
          { type: "function_call_output", call_id: "call_bash", output: "{\"exitCode\":0,\"stdout\":\"ok\",\"stderr\":\"\"}" }
        ],
        tools: [
          {
            type: "function",
            name: "bash",
            parameters: {
              type: "object",
              properties: {
                command: { type: "string" },
                timeout: { type: "number", description: "Timeout in seconds (optional, no default timeout)" }
              },
              required: ["command"]
            }
          }
        ]
      },
      { id: "composer-2.5" }
    );

    const line = prepared.prompt.text
      .split("\n")
      .find((item) => item.startsWith("LOCAL TOOL RESULT: "));
    expect(line).toBeTruthy();
    const feedback = JSON.parse(line!.slice("LOCAL TOOL RESULT: ".length));
    expect(feedback.name).toBe("shell");
    expect(feedback.args).toEqual({ command: "npm test", timeout: 120_000 });
    expect(feedback.result.value).toMatchObject({ exitCode: 0, stdout: "ok", stderr: "" });
  });

  it("feeds Responses generic harness outputs back with SDK builtin names from generated call ids", () => {
    const fileText = "export default function App() { return null }";
    const tools = [
      {
        type: "function",
        name: "workspace_file",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            action: { type: "string", enum: ["read", "write", "replace", "remove"] },
            target: { type: "string" },
            body: { type: "string" },
            find: { type: "string" },
            replaceWith: { type: "string" }
          },
          required: ["action", "target"]
        }
      },
      {
        type: "function",
        name: "run_command",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            shellCommand: { type: "string" },
            dir: { type: "string" }
          },
          required: ["shellCommand"]
        }
      },
      {
        type: "function",
        name: "discover_files",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            includePattern: { type: "string" },
            dir: { type: "string" }
          },
          required: ["includePattern"]
        }
      }
    ];
    const generated = toOpenAiToolCalls({
      responseId: "resp_generic",
      tools,
      toolCalls: [
        { name: "write", arguments: { path: "src/App.tsx", fileText } },
        { name: "edit", arguments: { path: "src/App.tsx", oldString: "return null", newString: "return <main />" } },
        { name: "shell", arguments: { command: "npm test", workingDirectory: "src" } },
        { name: "glob", arguments: { globPattern: "**/*.tsx", targetDirectory: "src" } }
      ]
    });
    const prepared = prepareResponsesRequest(
      {
        model: "composer-2.5",
        input: [
          { role: "user", content: "build and inspect files" },
          ...generated.flatMap((toolCall, index) => [
            {
              type: "function_call",
              call_id: toolCall.id,
              name: toolCall.function.name,
              arguments: toolCall.function.arguments
            },
            {
              type: "function_call_output",
              call_id: toolCall.id,
              output: ["{\"content\":\"ok\"}", "{\"diff\":\"updated\"}", "{\"exitCode\":0,\"stdout\":\"ok\",\"stderr\":\"\"}", "{\"files\":[\"src/App.tsx\"]}"][index]
            }
          ])
        ],
        tools
      },
      { id: "composer-2.5" }
    );

    const feedback = prepared.prompt.text
      .split("\n")
      .filter((item) => item.startsWith("LOCAL TOOL RESULT: "))
      .map((line) => JSON.parse(line.slice("LOCAL TOOL RESULT: ".length)));

    expect(feedback.map((item) => item.name)).toEqual(["write", "edit", "shell", "glob"]);
    expect(feedback.map((item) => item.args)).toEqual([
      { path: "src/App.tsx", fileText },
      { path: "src/App.tsx", oldString: "return null", newString: "return <main />" },
      { command: "npm test", workingDirectory: "src" },
      { targetDirectory: "src", globPattern: "**/*.tsx" }
    ]);
  });

  it("feeds Responses emulated shell outputs back with original SDK arguments", () => {
    const tools = [
      {
        type: "function",
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
    ];
    const generated = toOpenAiToolCalls({
      responseId: "resp_shell_memory",
      tools,
      toolCalls: [
        { name: "write", arguments: { path: "src/App.tsx", fileText: "export default function App() { return null }" } },
        { name: "edit", arguments: { path: "src/App.tsx", oldString: "return null", newString: "return <main />" } }
      ]
    });
    const prepared = prepareResponsesRequest(
      {
        model: "composer-2.5",
        input: [
          { role: "user", content: "build a todo app" },
          ...generated.flatMap((toolCall) => [
            {
              type: "function_call",
              call_id: toolCall.id,
              name: toolCall.function.name,
              arguments: toolCall.function.arguments
            },
            { type: "function_call_output", call_id: toolCall.id, output: "{\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"\"}" }
          ])
        ],
        tools
      },
      { id: "composer-2.5" }
    );

    const feedback = prepared.prompt.text
      .split("\n")
      .filter((item) => item.startsWith("LOCAL TOOL RESULT: "))
      .map((line) => JSON.parse(line.slice("LOCAL TOOL RESULT: ".length)));

    expect(generated.map((call) => call.function.name)).toEqual(["bash", "bash"]);
    expect(feedback.map((item) => item.name)).toEqual(["write", "edit"]);
    expect(feedback.map((item) => item.args)).toEqual([
      { path: "src/App.tsx", fileText: "export default function App() { return null }" },
      { path: "src/App.tsx", oldString: "return null", newString: "return <main />" }
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

  it("maps SDK calls through composed and wrapped JSON schemas", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [{ role: "user", content: "build the app" }],
        tools: [
          {
            name: "run_command",
            json_schema: {
              schema: {
                allOf: [
                  {
                    type: "object",
                    properties: {
                      shellCommand: { type: "string" }
                    },
                    required: ["shellCommand"]
                  },
                  {
                    type: "object",
                    properties: {
                      workingDir: { type: "string" },
                      timeoutSeconds: { type: "number", description: "Timeout in seconds" },
                      description: { type: "string" }
                    }
                  }
                ],
                additionalProperties: false
              }
            }
          },
          {
            name: "workspace_file",
            input_schema: {
              anyOf: [
                {
                  type: "object",
                  properties: {
                    action: { type: "string", const: "create" },
                    target: { type: "string" },
                    body: { type: "string" }
                  },
                  required: ["action", "target", "body"]
                },
                {
                  type: "object",
                  properties: {
                    action: { type: "string", const: "replace" },
                    target: { type: "string" },
                    find: { type: "string" },
                    replaceWith: { type: "string" }
                  },
                  required: ["action", "target", "find", "replaceWith"]
                }
              ],
              additionalProperties: false
            }
          }
        ]
      },
      { id: "composer-2.5-sdk" }
    );

    expect(prepared.prompt.text).toContain('"sdk":"shell","client":"run_command"');
    expect(prepared.prompt.text).toContain('"sdk":"write","client":"workspace_file"');

    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: prepared.tools,
      toolCalls: [
        { name: "shell", arguments: { command: "npm run build", workingDirectory: "/workspace", timeout: 120_000 } },
        { name: "write", arguments: { path: "src/App.jsx", fileText: "export default function App() { return null }" } },
        { name: "edit", arguments: { path: "src/App.jsx", oldString: "return null", newString: "return <main />" } }
      ],
      context: { workingDirectory: "/tmp/composed-app" }
    });

    expect(toolCalls.map((call) => call.function.name)).toEqual(["run_command", "workspace_file", "workspace_file"]);
    expect(toolCalls.map((call) => JSON.parse(call.function.arguments))).toEqual([
      {
        shellCommand: "npm run build",
        timeoutSeconds: 120
      },
      {
        action: "create",
        target: "src/App.jsx",
        body: "export default function App() { return null }"
      },
      {
        action: "replace",
        target: "src/App.jsx",
        find: "return null",
        replaceWith: "return <main />"
      }
    ]);
  });

  it("maps SDK calls through local JSON schema references", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [{ role: "user", content: "write the referenced schema file" }],
        tools: [
          {
            name: "workspace_file",
            parameters: {
              $ref: "#/$defs/FileInput",
              $defs: {
                FileInput: {
                  type: "object",
                  properties: {
                    operation: { $ref: "#/$defs/FileOperation" },
                    absolutePath: { type: "string", description: "absolute path to the file" },
                    text: { type: "string" }
                  },
                  required: ["operation", "absolutePath", "text"],
                  additionalProperties: false
                },
                FileOperation: {
                  type: "string",
                  enum: ["create", "replace", "read"]
                }
              }
            }
          }
        ]
      },
      { id: "composer-2.5-sdk" }
    );

    expect(prepared.prompt.text).toContain('"sdk":"write","client":"workspace_file"');

    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: prepared.tools,
      context: { workingDirectory: "/tmp/ref-schema-app" },
      toolCalls: [
        {
          name: "write",
          arguments: {
            path: "src/App.jsx",
            fileText: "export default function App() { return <main>Ref</main> }"
          }
        }
      ]
    });

    expect(toolCalls.map((call) => call.function.name)).toEqual(["workspace_file"]);
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({
      operation: "create",
      absolutePath: "/tmp/ref-schema-app/src/App.jsx",
      text: "export default function App() { return <main>Ref</main> }"
    });
  });

  it("maps SDK calls to generic harness schemas by reusable tool shape", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "workspace_file",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              action: { type: "string", enum: ["read", "write", "replace", "remove"] },
              target: { type: "string" },
              body: { type: "string" },
              find: { type: "string" },
              replaceWith: { type: "string" }
            },
            required: ["action", "target"]
          }
        },
        {
          name: "run_command",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              shellCommand: { type: "string" },
              dir: { type: "string" }
            },
            required: ["shellCommand"]
          }
        },
        {
          name: "discover_files",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              includePattern: { type: "string" },
              dir: { type: "string" }
            },
            required: ["includePattern"]
          }
        }
      ],
      toolCalls: [
        { name: "write", arguments: { path: "src/App.tsx", fileText: "export default function App() { return null }" } },
        { name: "edit", arguments: { path: "src/App.tsx", oldString: "return null", newString: "return <main />" } },
        { name: "shell", arguments: { command: "npm test", workingDirectory: "src" } },
        { name: "glob", arguments: { globPattern: "**/*.tsx", targetDirectory: "src" } }
      ]
    });

    expect(toolCalls.map((call) => call.function.name)).toEqual(["workspace_file", "workspace_file", "run_command", "discover_files"]);
    expect(toolCalls.map((call) => JSON.parse(call.function.arguments))).toEqual([
      { action: "write", target: "src/App.tsx", body: "export default function App() { return null }" },
      { action: "replace", target: "src/App.tsx", find: "return null", replaceWith: "return <main />" },
      { shellCommand: "npm test", dir: "src" },
      { includePattern: "**/*.tsx", dir: "src" }
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

  it("maps Cursor SDK MCP calls with alternate payload envelopes", () => {
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
        },
        {
          name: "call_mcp_tool",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              serverName: { type: "string" },
              toolName: { type: "string" },
              input: { type: "object" }
            },
            required: ["serverName", "toolName", "input"]
          }
        }
      ],
      toolCalls: [
        {
          name: "mcp",
          arguments: {
            serverName: "probe",
            name: "write_file",
            arguments: JSON.stringify({
              file_path: "src/App.tsx",
              contents: "export default function App() { return null }",
              overwrite: true
            })
          }
        },
        {
          name: "mcp",
          arguments: {
            provider: "filesystem",
            tool: "read_file",
            parameters: JSON.stringify({ path: "README.md" })
          }
        }
      ]
    });

    expect(toolCalls.map((call) => call.function.name)).toEqual(["probe_write_file", "call_mcp_tool"]);
    expect(toolCalls.map((call) => JSON.parse(call.function.arguments))).toEqual([
      {
        file_path: "src/App.tsx",
        contents: "export default function App() { return null }",
        overwrite: true
      },
      {
        serverName: "filesystem",
        toolName: "read_file",
        input: { path: "README.md" }
      }
    ]);
  });

  it("maps Cursor SDK MCP calls to single-word client tools", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "webfetch",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              url: { type: "string" },
              format: { type: "string" }
            },
            required: ["url"]
          }
        }
      ],
      toolCalls: [
        {
          name: "mcp",
          arguments: {
            providerIdentifier: "client",
            toolName: "webfetch",
            args: {
              url: "https://example.com",
              format: "markdown"
            }
          }
        }
      ]
    });

    expect(toolCalls[0].function.name).toBe("webfetch");
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({
      url: "https://example.com",
      format: "markdown"
    });
  });

  it("maps Cursor SDK MCP calls to wrapped single-word client tools", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "task",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              input: {
                type: "object",
                additionalProperties: false,
                properties: {
                  description: { type: "string" },
                  prompt: { type: "string" },
                  subagent_type: { type: "string" }
                },
                required: ["description", "prompt", "subagent_type"]
              }
            },
            required: ["input"]
          }
        }
      ],
      toolCalls: [
        {
          name: "mcp",
          arguments: {
            providerIdentifier: "client",
            toolName: "task",
            args: {
              description: "Explore files",
              prompt: "Find the app entrypoint",
              subagent_type: "explore"
            }
          }
        }
      ]
    });

    expect(toolCalls[0].function.name).toBe("task");
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({
      input: {
        description: "Explore files",
        prompt: "Find the app entrypoint",
        subagent_type: "explore"
      }
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

  it("feeds single-word client tool results back as completed synthetic SDK MCP calls", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          { role: "user", content: "Use the webfetch tool." },
          {
            role: "assistant",
            content: null,
            tool_calls: [
              {
                id: "call_webfetch",
                type: "function",
                function: {
                  name: "webfetch",
                  arguments: JSON.stringify({ url: "https://example.com", format: "markdown" })
                }
              }
            ]
          },
          { role: "tool", tool_call_id: "call_webfetch", name: "webfetch", content: "{\"content\":\"ok\"}" }
        ],
        tools: [
          {
            type: "function",
            function: {
              name: "webfetch",
              parameters: {
                type: "object",
                properties: {
                  url: { type: "string" },
                  format: { type: "string" }
                },
                required: ["url"]
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
      providerIdentifier: "client",
      toolName: "webfetch",
      args: {
        url: "https://example.com",
        format: "markdown"
      }
    });
    expect(feedback.result).toEqual({ status: "success", value: { content: "ok" } });
  });

  it("feeds live OpenCode build tool results back with SDK-compatible names and arguments", () => {
    const fileText = "export default function App() { return null }";
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          { role: "user", content: "build a todo app" },
          {
            role: "assistant",
            content: null,
            tool_calls: [
              { id: "call_write", type: "function", function: { name: "write", arguments: JSON.stringify({ filePath: "/tmp/project/src/App.tsx", content: fileText }) } },
              { id: "call_read", type: "function", function: { name: "read", arguments: JSON.stringify({ filePath: "/tmp/project/src/App.tsx", offset: 5, limit: 20 }) } },
              { id: "call_edit", type: "function", function: { name: "edit", arguments: JSON.stringify({ filePath: "/tmp/project/src/App.tsx", oldString: "return null", newString: "return <main />" }) } },
              { id: "call_glob", type: "function", function: { name: "glob", arguments: JSON.stringify({ pattern: "**/*.tsx", path: "/tmp/project/src" }) } },
              { id: "call_todo", type: "function", function: { name: "todowrite", arguments: JSON.stringify({ todos: [{ content: "Build app", status: "in_progress", priority: "high" }] }) } },
              { id: "call_task", type: "function", function: { name: "task", arguments: JSON.stringify({ description: "Inspect app", prompt: "Find the app entry point", subagent_type: "explore" }) } },
              { id: "call_skill", type: "function", function: { name: "skill", arguments: JSON.stringify({ name: "customize-opencode" }) } }
            ]
          },
          { role: "tool", tool_call_id: "call_write", content: "{\"content\":\"ok\"}" },
          { role: "tool", tool_call_id: "call_read", content: fileText },
          { role: "tool", tool_call_id: "call_edit", content: "{\"diff\":\"updated App\"}" },
          { role: "tool", tool_call_id: "call_glob", content: "{\"files\":[\"src/App.tsx\"]}" },
          { role: "tool", tool_call_id: "call_todo", content: "{\"content\":\"ok\"}" },
          { role: "tool", tool_call_id: "call_task", content: "{\"content\":\"entry point is src/App.tsx\"}" },
          { role: "tool", tool_call_id: "call_skill", content: "{\"content\":\"loaded\"}" }
        ],
        tools: [
          {
            name: "write",
            input_schema: { type: "object", properties: { filePath: { type: "string" }, content: { type: "string" } }, required: ["filePath", "content"] }
          },
          {
            name: "read",
            input_schema: { type: "object", properties: { filePath: { type: "string" }, offset: { type: "integer" }, limit: { type: "integer" } }, required: ["filePath"] }
          },
          {
            name: "edit",
            input_schema: { type: "object", properties: { filePath: { type: "string" }, oldString: { type: "string" }, newString: { type: "string" } }, required: ["filePath", "oldString", "newString"] }
          },
          {
            name: "glob",
            input_schema: { type: "object", properties: { pattern: { type: "string" }, path: { type: "string" } }, required: ["pattern"] }
          },
          {
            name: "todowrite",
            input_schema: { type: "object", properties: { todos: { type: "array" } }, required: ["todos"] }
          },
          {
            name: "task",
            input_schema: {
              type: "object",
              properties: { description: { type: "string" }, prompt: { type: "string" }, subagent_type: { type: "string" } },
              required: ["description", "prompt", "subagent_type"]
            }
          },
          {
            name: "skill",
            input_schema: { type: "object", properties: { name: { type: "string" } }, required: ["name"] }
          }
        ]
      },
      { id: "composer-2.5-sdk" }
    );

    const feedback = prepared.prompt.text
      .split("\n")
      .filter((item) => item.startsWith("LOCAL OPENCODE TOOL RESULT: "))
      .map((line) => JSON.parse(line.slice("LOCAL OPENCODE TOOL RESULT: ".length)));

    expect(feedback.map((item) => item.name)).toEqual(["write", "read", "edit", "glob", "todowrite", "mcp", "mcp"]);
    expect(feedback.map((item) => item.args)).toEqual([
      { path: "/tmp/project/src/App.tsx", fileText },
      { path: "/tmp/project/src/App.tsx", offset: 5, limit: 20 },
      { path: "/tmp/project/src/App.tsx", oldString: "return null", newString: "return <main />" },
      { targetDirectory: "/tmp/project/src", globPattern: "**/*.tsx" },
      { todos: [{ content: "Build app", status: "in_progress", priority: "high" }] },
      { providerIdentifier: "client", toolName: "task", args: { description: "Inspect app", prompt: "Find the app entry point", subagent_type: "explore" } },
      { providerIdentifier: "client", toolName: "skill", args: { name: "customize-opencode" } }
    ]);
    expect(feedback[0].result.value).toMatchObject({ path: "/tmp/project/src/App.tsx", linesCreated: 1 });
    expect(feedback[3].result.value).toMatchObject({ files: ["src/App.tsx"], totalFiles: 1 });
  });

  it("feeds generic harness tool results back with SDK builtin names from generated call ids", () => {
    const fileText = "export default function App() { return null }";
    const tools = [
      {
        name: "workspace_file",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            action: { type: "string", enum: ["read", "write", "replace", "remove"] },
            target: { type: "string" },
            body: { type: "string" },
            find: { type: "string" },
            replaceWith: { type: "string" }
          },
          required: ["action", "target"]
        }
      },
      {
        name: "run_command",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            shellCommand: { type: "string" },
            dir: { type: "string" }
          },
          required: ["shellCommand"]
        }
      },
      {
        name: "discover_files",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            includePattern: { type: "string" },
            dir: { type: "string" }
          },
          required: ["includePattern"]
        }
      }
    ];
    const generated = toOpenAiToolCalls({
      responseId: "chatcmpl_generic",
      tools,
      toolCalls: [
        { name: "write", arguments: { path: "src/App.tsx", fileText } },
        { name: "edit", arguments: { path: "src/App.tsx", oldString: "return null", newString: "return <main />" } },
        { name: "shell", arguments: { command: "npm test", workingDirectory: "src" } },
        { name: "glob", arguments: { globPattern: "**/*.tsx", targetDirectory: "src" } }
      ]
    });
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          { role: "user", content: "build a todo app" },
          { role: "assistant", content: null, tool_calls: generated },
          { role: "tool", tool_call_id: generated[0].id, content: "{\"content\":\"ok\"}" },
          { role: "tool", tool_call_id: generated[1].id, content: "{\"diff\":\"updated\"}" },
          { role: "tool", tool_call_id: generated[2].id, content: "{\"exitCode\":0,\"stdout\":\"ok\",\"stderr\":\"\"}" },
          { role: "tool", tool_call_id: generated[3].id, content: "{\"files\":[\"src/App.tsx\"]}" }
        ],
        tools
      },
      { id: "composer-2.5-sdk" }
    );

    const feedback = prepared.prompt.text
      .split("\n")
      .filter((item) => item.startsWith("LOCAL OPENCODE TOOL RESULT: "))
      .map((line) => JSON.parse(line.slice("LOCAL OPENCODE TOOL RESULT: ".length)));

    expect(feedback.map((item) => item.name)).toEqual(["write", "edit", "shell", "glob"]);
    expect(feedback.map((item) => item.args)).toEqual([
      { path: "src/App.tsx", fileText },
      { path: "src/App.tsx", oldString: "return null", newString: "return <main />" },
      { command: "npm test", workingDirectory: "src" },
      { targetDirectory: "src", globPattern: "**/*.tsx" }
    ]);
    expect(feedback[0].result.value).toMatchObject({ path: "src/App.tsx", linesCreated: 1 });
    expect(feedback[2].result.value).toMatchObject({ exitCode: 0, stdout: "ok", stderr: "" });
    expect(feedback[3].result.value.files).toEqual(["src/App.tsx"]);
  });

  it("feeds find client tool results back as completed SDK glob calls", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          { role: "user", content: "find source files" },
          {
            role: "assistant",
            content: null,
            tool_calls: [
              {
                id: "call_find",
                type: "function",
                function: {
                  name: "find",
                  arguments: JSON.stringify({ pattern: "**/*.tsx", path: "src" })
                }
              }
            ]
          },
          { role: "tool", tool_call_id: "call_find", content: "{\"files\":[\"src/App.tsx\"]}" }
        ],
        tools: [
          {
            name: "find",
            input_schema: {
              type: "object",
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

    const line = prepared.prompt.text
      .split("\n")
      .find((item) => item.startsWith("LOCAL OPENCODE TOOL RESULT: "));
    expect(line).toBeTruthy();
    const feedback = JSON.parse(line!.slice("LOCAL OPENCODE TOOL RESULT: ".length));
    expect(feedback.name).toBe("glob");
    expect(feedback.args).toEqual({ targetDirectory: "src", globPattern: "**/*.tsx" });
    expect(feedback.result.value.files).toEqual(["src/App.tsx"]);
    expect(feedback.result.value.totalFiles).toBe(1);
  });

  it("feeds pi bash results back with SDK millisecond timeout arguments", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          { role: "user", content: "run tests" },
          {
            role: "assistant",
            content: null,
            tool_calls: [
              {
                id: "call_bash",
                type: "function",
                function: {
                  name: "bash",
                  arguments: JSON.stringify({ command: "npm test", timeout: 120 })
                }
              }
            ]
          },
          { role: "tool", tool_call_id: "call_bash", content: "{\"exitCode\":0,\"stdout\":\"ok\",\"stderr\":\"\"}" }
        ],
        tools: [
          {
            name: "bash",
            input_schema: {
              type: "object",
              properties: {
                command: { type: "string" },
                timeout: { type: "number", description: "Timeout in seconds (optional, no default timeout)" }
              },
              required: ["command"]
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
    expect(feedback.name).toBe("shell");
    expect(feedback.args).toEqual({ command: "npm test", timeout: 120_000 });
    expect(feedback.result.value).toMatchObject({ exitCode: 0, stdout: "ok", stderr: "" });
  });

  it("feeds pi edit results back with SDK edit argument names", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          { role: "user", content: "edit the app" },
          {
            role: "assistant",
            content: null,
            tool_calls: [
              {
                id: "call_edit",
                type: "function",
                function: {
                  name: "edit",
                  arguments: JSON.stringify({ path: "src/App.tsx", oldText: "return null", newText: "return <main />" })
                }
              }
            ]
          },
          { role: "tool", tool_call_id: "call_edit", content: "{\"diff\":\"ok\"}" }
        ],
        tools: [
          {
            name: "edit",
            input_schema: {
              type: "object",
              properties: {
                path: { type: "string" },
                oldText: { type: "string" },
                newText: { type: "string" }
              },
              required: ["path", "oldText", "newText"]
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
    expect(feedback.name).toBe("edit");
    expect(feedback.args).toEqual({
      path: "src/App.tsx",
      oldString: "return null",
      newString: "return <main />"
    });
    expect(feedback.result.value.diffString).toBe("ok");
  });

  it("feeds pi grep results back with SDK grep option names", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          { role: "user", content: "search source files" },
          {
            role: "assistant",
            content: null,
            tool_calls: [
              {
                id: "call_grep",
                type: "function",
                function: {
                  name: "grep",
                  arguments: JSON.stringify({
                    pattern: "TODO",
                    path: "src",
                    glob: "*.tsx",
                    ignoreCase: true,
                    literal: true,
                    context: 2,
                    limit: 10
                  })
                }
              }
            ]
          },
          { role: "tool", tool_call_id: "call_grep", content: "src/App.tsx:1:TODO" }
        ],
        tools: [
          {
            name: "grep",
            input_schema: {
              type: "object",
              properties: {
                pattern: { type: "string" },
                path: { type: "string" },
                glob: { type: "string" },
                ignoreCase: { type: "boolean" },
                literal: { type: "boolean" },
                context: { type: "number" },
                limit: { type: "number" }
              },
              required: ["pattern"]
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
    expect(feedback.name).toBe("grep");
    expect(feedback.args).toEqual({
      pattern: "TODO",
      path: "src",
      glob: "*.tsx",
      caseInsensitive: true,
      literal: true,
      context: 2,
      headLimit: 10
    });
    expect(feedback.result.value.text).toBe("src/App.tsx:1:TODO");
  });

  it("feeds pi ls results back with SDK list argument names", () => {
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          { role: "user", content: "list files" },
          {
            role: "assistant",
            content: null,
            tool_calls: [
              {
                id: "call_ls",
                type: "function",
                function: {
                  name: "ls",
                  arguments: JSON.stringify({ path: "src", limit: 20 })
                }
              }
            ]
          },
          { role: "tool", tool_call_id: "call_ls", content: "App.tsx" }
        ],
        tools: [
          {
            name: "ls",
            input_schema: {
              type: "object",
              properties: {
                path: { type: "string" },
                limit: { type: "number" }
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
    expect(feedback.name).toBe("ls");
    expect(feedback.args).toEqual({ path: "src", limit: 20 });
    expect(feedback.result.value.text).toBe("App.tsx");
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

  it("does not map SDK edits to schemas missing replacement arguments", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "replace_file",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              path: { type: "string" },
              search: { type: "string" }
            },
            required: ["path", "search"]
          }
        }
      ],
      toolCalls: [{ name: "edit", arguments: { path: "src/App.tsx", oldString: "Hello", newString: "Hi" } }]
    });

    expect(toolCalls).toEqual([]);
  });

  it("does not map exact SDK edit names to incompatible schemas", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "edit",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              path: { type: "string" },
              search: { type: "string" }
            },
            required: ["path", "search"]
          }
        }
      ],
      toolCalls: [{ name: "edit", arguments: { path: "src/App.tsx", oldString: "Hello", newString: "Hi" } }]
    });

    expect(toolCalls).toEqual([]);
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

  it("emulates SDK partial reads through shell without reading the whole file", () => {
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
      toolCalls: [{ name: "read", arguments: { path: "src/App.tsx", offset: 5, limit: 10 } }]
    });

    expect(toolCalls[0].function.name).toBe("bash");
    const args = JSON.parse(toolCalls[0].function.arguments);
    expect(args.command).toBe("sed -n '5,14p' 'src/App.tsx'");
    expect(args.description).toBe("Runs sed -n '5,14p' 'src/App.tsx'");
  });

  it("emulates SDK edits through shell when shell is the only compatible client tool", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "run_command",
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
      toolCalls: [{ name: "edit", arguments: { path: "src/App.tsx", oldString: "return null", newString: "return <main />" } }]
    });

    expect(toolCalls[0].function.name).toBe("run_command");
    const args = JSON.parse(toolCalls[0].function.arguments);
    expect(args.command).toContain("from pathlib import Path");
    expect(args.command).toContain('path = Path("src/App.tsx")');
    expect(args.command).toContain('old = "return null"');
    expect(args.command).toContain('new = "return <main />"');
    expect(args.command).toContain("text.replace(old, new, 1)");
    expect(args.description).toContain("python3");
  });

  it("feeds emulated shell tool results back with the original SDK arguments", () => {
    const tools = [
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
    ];
    const generated = toOpenAiToolCalls({
      responseId: "chatcmpl_shell_memory",
      tools,
      toolCalls: [
        { name: "write", arguments: { path: "src/App.tsx", fileText: "export default function App() { return null }" } },
        { name: "edit", arguments: { path: "src/App.tsx", oldString: "return null", newString: "return <main />" } },
        { name: "read", arguments: { path: "src/App.tsx", offset: 5, limit: 10 } }
      ]
    });
    const prepared = prepareOpencodeSdkChatRequest(
      {
        model: "composer-2.5-sdk",
        messages: [
          { role: "user", content: "build a todo app" },
          { role: "assistant", content: null, tool_calls: generated },
          { role: "tool", tool_call_id: generated[0].id, content: "{\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"\"}" },
          { role: "tool", tool_call_id: generated[1].id, content: "{\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"\"}" },
          { role: "tool", tool_call_id: generated[2].id, content: "line 5" }
        ],
        tools
      },
      { id: "composer-2.5-sdk" }
    );

    const feedback = prepared.prompt.text
      .split("\n")
      .filter((item) => item.startsWith("LOCAL OPENCODE TOOL RESULT: "))
      .map((line) => JSON.parse(line.slice("LOCAL OPENCODE TOOL RESULT: ".length)));

    expect(generated.map((call) => call.function.name)).toEqual(["bash", "bash", "bash"]);
    expect(feedback.map((item) => item.name)).toEqual(["write", "edit", "read"]);
    expect(feedback.map((item) => item.args)).toEqual([
      { path: "src/App.tsx", fileText: "export default function App() { return null }" },
      { path: "src/App.tsx", oldString: "return null", newString: "return <main />" },
      { path: "src/App.tsx", offset: 5, limit: 10 }
    ]);
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

  it("fills required shell cwd and timeout fields for strict harness command tools", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "run_command",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              command: { type: "string" },
              cwd: { type: "string" },
              timeout_ms: { type: "number" },
              description: { type: "string" }
            },
            required: ["command", "cwd", "timeout_ms", "description"]
          }
        }
      ],
      toolCalls: [{ name: "shell", arguments: { command: "npm test", workingDirectory: "/workspace" } }]
    });

    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({
      command: "npm test",
      cwd: ".",
      timeout_ms: 120_000,
      description: "Runs npm test"
    });
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

  it("preserves recursive Cursor targeting without leaking absolute target paths into glob patterns", () => {
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

    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({ pattern: "**/*.ts" });
  });

  it("repairs swapped SDK glob pattern and path values", () => {
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
      toolCalls: [{ name: "glob", arguments: { targetDirectory: "**/*.tsx", globPattern: "/tmp/project" } }]
    });

    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({ pattern: "**/*.tsx", path: "/tmp/project" });
  });

  it("repairs swapped SDK glob values when the search root is current directory", () => {
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
      toolCalls: [{ name: "glob", arguments: { targetDirectory: "**/*", globPattern: "." } }]
    });

    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({ pattern: "**/*", path: "." });
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

    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({ pattern: "**/*" });
  });

  it("does not emit schema-invalid file tool calls", () => {
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
        }
      ],
      toolCalls: [{ name: "write", arguments: { path: "src/App.tsx" } }]
    });

    expect(toolCalls).toEqual([]);
  });

  it("explains schema-invalid file tool call retries with required client arguments", () => {
    const tools = [
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
      }
    ];

    const hint = toolCallRetryHint({
      tools,
      toolCall: { name: "write", arguments: { path: "src/App.tsx" } }
    });

    expect(hint).toContain("SDK write mapped to client write");
    expect(hint).toContain("Normalized arguments");
    expect(hint).toContain("filePath");
    expect(hint).toContain("content:string");
  });

  it("maps SDK directory-only glob calls to a valid OpenCode glob", () => {
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
      toolCalls: [{ name: "glob", arguments: { targetDirectory: "src" } }]
    });

    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({ pattern: "**/*", path: "src" });
  });

  it("fills a required glob path with the harness workspace root", () => {
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
            required: ["pattern", "path"]
          }
        }
      ],
      toolCalls: [{ name: "glob", arguments: { globPattern: "**/*.tsx" } }]
    });

    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({ pattern: "**/*.tsx", path: "." });
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

  it("does not emit schema-invalid specific MCP tool calls", () => {
    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools: [
        {
          name: "mcp__github__create_issue",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              title: { type: "string" },
              body: { type: "string" }
            },
            required: ["title"]
          }
        }
      ],
      toolCalls: [
        {
          name: "mcp",
          arguments: {
            providerIdentifier: "github",
            toolName: "create_issue",
            args: { body: "Missing required title" }
          }
        }
      ]
    });

    expect(toolCalls).toEqual([]);
  });

  it("does not emit wrapper MCP calls with schema-invalid nested input", () => {
    const tools = [
      {
        name: "call_mcp_tool",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            serverName: { type: "string" },
            toolName: { type: "string" },
            input: {
              type: "object",
              additionalProperties: false,
              properties: {
                file_path: { type: "string" },
                contents: { type: "string" }
              },
              required: ["file_path", "contents"]
            }
          },
          required: ["serverName", "toolName", "input"]
        }
      }
    ];
    const missingContentsCall = {
      name: "mcp",
      arguments: {
        providerIdentifier: "filesystem",
        toolName: "write_file",
        args: { file_path: "src/App.tsx" }
      }
    };

    const toolCalls = toOpenAiToolCalls({
      responseId: "chatcmpl_test",
      tools,
      toolCalls: [missingContentsCall]
    });
    const hint = toolCallRetryHint({ tools, toolCall: missingContentsCall });

    expect(toolCalls).toEqual([]);
    expect(hint).toContain("input.file_path:string");
    expect(hint).toContain("input.contents:string");
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

  it("maps SDK patchContent edits without a separate path to patch-only tools", () => {
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
              patch: { type: "string" }
            },
            required: ["patch"]
          }
        }
      ],
      toolCalls: [{ name: "edit", arguments: { patchContent: patch } }]
    });

    expect(toolCalls[0].function.name).toBe("apply_patch");
    expect(JSON.parse(toolCalls[0].function.arguments)).toEqual({ patch });
    expect(
      responseObject({
        id: "resp_patch",
        created: 1,
        model: "composer-2.5",
        text: "",
        toolCalls,
        promptChars: 20
      }).output
    ).toEqual([
      expect.objectContaining({
        type: "function_call",
        call_id: toolCalls[0].id,
        name: "apply_patch",
        arguments: JSON.stringify({ patch })
      })
    ]);
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
