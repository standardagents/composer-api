import { describe, expect, it } from "vitest";
import { spawn, spawnSync } from "node:child_process";
import http from "node:http";
import { fileURLToPath } from "node:url";
import {
  bridgePrompt,
  clientForwardingMcpServerSource,
  clientMcpToolDefinitions,
  localAgentCreateOptions,
  localAgentSendOptions,
  isForwardableSDKToolCall,
  isRetryableSDKRunError,
  normalizeModel,
  normalizeSDKToolCall,
  openAiError,
  runExclusiveForAgent,
  sdkRunFailureSummary,
  statusFromError,
  toolCallFromDelta,
  validateClientMcpToolCall
} from "./cursor-sdk-local-agent-bridge.mjs";

const bridgeScriptPath = fileURLToPath(new URL("./cursor-sdk-local-agent-bridge.mjs", import.meta.url));

describe("Cursor SDK local-agent bridge", () => {
  it("classifies retryable Cursor SDK upstream capacity errors", () => {
    expect(isRetryableSDKRunError(new Error("Server at capacity"))).toBe(true);
    expect(isRetryableSDKRunError({ cause: { isRetryable: true } })).toBe(true);
    expect(isRetryableSDKRunError({ rawMessage: "temporarily unavailable" })).toBe(true);
    expect(isRetryableSDKRunError({ status: 429 })).toBe(true);
    expect(isRetryableSDKRunError(new Error("Missing or invalid authorization"))).toBe(false);
    expect(isRetryableSDKRunError({ status: 401, message: "Unauthorized" })).toBe(false);
  });

  it("treats opaque SDK error results as retryable but preserves explicit auth failures", () => {
    expect(sdkRunFailureSummary({ status: "error" })).toMatchObject({
      message: "",
      retryable: true
    });
    expect(sdkRunFailureSummary({ status: "error", error: { message: "Server at capacity", code: "unavailable" } })).toMatchObject({
      message: "Server at capacity",
      code: "unavailable",
      retryable: true
    });
    expect(sdkRunFailureSummary({ status: "error", error: { message: "Missing or invalid authorization", code: "unauthorized" } })).toMatchObject({
      message: "Missing or invalid authorization",
      code: "unauthorized",
      retryable: false
    });
  });

  it("surfaces Cursor SDK authentication failures as unauthorized API errors", () => {
    const error = Object.assign(new Error("Error"), {
      name: "AuthenticationError",
      code: "internal",
      status: "401",
      endpoint: "GET /v1/models"
    });

    expect(statusFromError(error)).toBe(401);
    expect(openAiError(error)).toEqual({
      error: {
        message: "Missing or invalid authorization",
        type: "invalid_request_error",
        code: "unauthorized",
        status: 401
      }
    });
  });

  it("keeps public Composer aliases distinct before SDK model selection", () => {
    expect(normalizeModel("composer-2.5")).toBe("composer-2.5");
    expect(normalizeModel("composer-2.5-fast")).toBe("composer-2.5-fast");
    expect(normalizeModel("cursorapi/composer-2.5-fast")).toBe("composer-2.5-fast");
    expect(normalizeModel("composer-latest")).toBe("composer-2.5");
    expect(normalizeModel("auto")).toBe("default");
    expect(normalizeModel("gpt-5.5")).toBe("gpt-5.5");
  });

  it("serializes overlapping runs for the same stateful SDK agent", async () => {
    const input = {
      apiKey: "test-key",
      model: "default",
      workingDirectory: "/tmp/project",
      sessionKey: "shared-session",
      clientTools: []
    };
    const order = [];
    let releaseFirst;
    let first;
    const firstStarted = new Promise((resolve) => {
      first = runExclusiveForAgent(input, async () => {
        order.push("first:start");
        resolve();
        await new Promise((release) => {
          releaseFirst = release;
        });
        order.push("first:end");
        return "first";
      });
    });

    await firstStarted;
    const second = runExclusiveForAgent({ ...input, requestId: "second" }, async () => {
      order.push("second:start");
      return "second";
    });
    await new Promise((resolve) => setImmediate(resolve));
    expect(order).toEqual(["first:start"]);

    releaseFirst();
    await expect(first).resolves.toBe("first");
    await expect(second).resolves.toBe("second");
    expect(order).toEqual(["first:start", "first:end", "second:start"]);
  });

  it("allows different SDK sessions to run concurrently", async () => {
    const baseInput = {
      apiKey: "test-key",
      model: "default",
      workingDirectory: "/tmp/project",
      clientTools: []
    };
    const order = [];
    let releaseFirst;
    const first = runExclusiveForAgent({ ...baseInput, sessionKey: "session-a" }, async () => {
      order.push("first:start");
      await new Promise((release) => {
        releaseFirst = release;
      });
      return "first";
    });
    const second = runExclusiveForAgent({ ...baseInput, sessionKey: "session-b" }, async () => {
      order.push("second:start");
      return "second";
    });

    await new Promise((resolve) => setImmediate(resolve));
    expect(order).toEqual(["first:start", "second:start"]);
    releaseFirst();
    await expect(first).resolves.toBe("first");
    await expect(second).resolves.toBe("second");
  });

  it("does not cancel SDK glob calls on directory-only partial arguments", () => {
    const partial = normalizeSDKToolCall({
      type: "glob",
      args: { targetDirectory: "." }
    });

    expect(partial).toEqual({
      name: "glob",
      arguments: { targetDirectory: "." }
    });
    expect(isForwardableSDKToolCall(partial)).toBe(false);
  });

  it("allows SDK glob calls once a real pattern is present", () => {
    expect(isForwardableSDKToolCall({ name: "glob", arguments: { globPattern: "**/*.tsx", targetDirectory: "." } })).toBe(true);
    expect(isForwardableSDKToolCall({ name: "glob", arguments: { glob_pattern: "*.tsx", targeting: "src" } })).toBe(true);
    expect(isForwardableSDKToolCall({ name: "glob", arguments: { targeting: "/tmp/project/src/**/*.tsx" } })).toBe(true);
  });

  it("ignores partial SDK tool calls even when their partial arguments look forwardable", () => {
    const update = {
      type: "partial-tool-call",
      toolCall: {
        type: "shell",
        args: { command: "cat > package.json <<'EOF'\n{\"scripts\"" }
      }
    };

    expect(toolCallFromDelta(update)).toBe(null);
  });

  it("extracts SDK tool-call starts for early bridge-side cancellation", () => {
    const update = {
      type: "tool-call-started",
      toolCall: {
        type: "shell",
        args: { command: "printf OK" }
      }
    };

    const normalized = normalizeSDKToolCall(toolCallFromDelta(update));

    expect(normalized).toEqual({
      name: "shell",
      arguments: { command: "printf OK" }
    });
    expect(isForwardableSDKToolCall(normalized)).toBe(true);
  });

  it("requires both provider and tool names for SDK MCP forwarding", () => {
    expect(isForwardableSDKToolCall({ name: "mcp", arguments: { providerIdentifier: "client" } })).toBe(false);
    expect(isForwardableSDKToolCall({ name: "mcp", arguments: { providerIdentifier: "client", toolName: "glob" } })).toBe(false);
    expect(isForwardableSDKToolCall({ name: "glob", arguments: { globPattern: "**/*" } })).toBe(true);
  });

  it("requires complete non-file SDK builtin tool arguments before forwarding", () => {
    expect(isForwardableSDKToolCall({ name: "readLints", arguments: { cwd: "." } })).toBe(false);
    expect(isForwardableSDKToolCall({ name: "readLints", arguments: { paths: [] } })).toBe(false);
    expect(isForwardableSDKToolCall({ name: "readLints", arguments: { paths: ["src/App.tsx"] } })).toBe(true);
    expect(isForwardableSDKToolCall({ name: "readLints", arguments: { filePath: "src/App.tsx" } })).toBe(true);

    expect(isForwardableSDKToolCall({ name: "semSearch", arguments: { targetDirectories: ["src"] } })).toBe(false);
    expect(isForwardableSDKToolCall({ name: "semSearch", arguments: { query: "submit button" } })).toBe(true);
    expect(isForwardableSDKToolCall({ name: "semSearch", arguments: { search_query: "submit button", targetDirectories: ["src"] } })).toBe(true);

    expect(isForwardableSDKToolCall({ name: "todowrite", arguments: { status: "in_progress" } })).toBe(false);
    expect(isForwardableSDKToolCall({ name: "todowrite", arguments: { todos: [] } })).toBe(true);
    expect(isForwardableSDKToolCall({ name: "todowrite", arguments: { taskList: [{ content: "Build app" }] } })).toBe(true);

    expect(isForwardableSDKToolCall({ name: "task", arguments: { description: "Inspect app" } })).toBe(false);
    expect(isForwardableSDKToolCall({ name: "task", arguments: { description: "Inspect app", prompt: "Find the entrypoint" } })).toBe(true);

    expect(isForwardableSDKToolCall({ name: "createPlan", arguments: { status: "in_progress" } })).toBe(false);
    expect(isForwardableSDKToolCall({ name: "createPlan", arguments: { plan: "Build and verify the app" } })).toBe(true);
    expect(isForwardableSDKToolCall({ name: "createPlan", arguments: { todos: [{ content: "Build app" }] } })).toBe(true);

    expect(isForwardableSDKToolCall({ name: "generateImage", arguments: { filePath: "out.png" } })).toBe(false);
    expect(isForwardableSDKToolCall({ name: "generateImage", arguments: { description: "A blue cube" } })).toBe(true);

    expect(isForwardableSDKToolCall({ name: "recordScreen", arguments: { path: "recording.mov" } })).toBe(false);
    expect(isForwardableSDKToolCall({ name: "recordScreen", arguments: { mode: "START_RECORDING" } })).toBe(true);
  });

  it("normalizes local client MCP forwarding tools back to SDK tool names", () => {
    const normalized = normalizeSDKToolCall({
      type: "mcp",
      args: {
        providerIdentifier: "client",
        toolName: "client_shell",
        args: {
          command: "npm test",
          timeout: 120000
        }
      }
    });

    expect(normalized).toEqual({
      name: "shell",
      arguments: {
        command: "npm test",
        timeout: 120000
      }
    });
    expect(isForwardableSDKToolCall(normalized)).toBe(true);
  });

  it("normalizes direct forwarding MCP tool events back to SDK tool names", () => {
    const normalized = normalizeSDKToolCall({
      type: "client_shell",
      args: {
        command: "npm test",
        timeout: 120000
      }
    });

    expect(normalized).toEqual({
      name: "shell",
      arguments: {
        command: "npm test",
        timeout: 120000
      }
    });
    expect(isForwardableSDKToolCall(normalized)).toBe(true);
  });

  it("normalizes SDK task and plan forwarding tools back to SDK tool names", () => {
    const task = normalizeSDKToolCall({
      type: "mcp",
      args: {
        providerIdentifier: "client",
        toolName: "client_task",
        args: {
          description: "Inspect app",
          prompt: "Find the entrypoint",
          subagentType: { kind: "agent", name: "explore" }
        }
      }
    });

    expect(task).toEqual({
      name: "task",
      arguments: {
        description: "Inspect app",
        prompt: "Find the entrypoint",
        subagentType: { kind: "agent", name: "explore" }
      }
    });
    expect(isForwardableSDKToolCall(task)).toBe(true);

    const plan = normalizeSDKToolCall({
      type: "client_create_plan",
      args: {
        plan: "Build the app",
        todos: [{ content: "Create files", status: "pending" }]
      }
    });

    expect(plan).toEqual({
      name: "createPlan",
      arguments: {
        plan: "Build the app",
        todos: [{ content: "Create files", status: "pending" }]
      }
    });
    expect(isForwardableSDKToolCall(plan)).toBe(true);
  });

  it("normalizes SDK image and screen forwarding tools back to SDK tool names", () => {
    const image = normalizeSDKToolCall({
      type: "mcp",
      args: {
        providerIdentifier: "client",
        toolName: "client_generate_image",
        args: {
          description: "A blue cube",
          filePath: "assets/cube.png"
        }
      }
    });

    expect(image).toEqual({
      name: "generateImage",
      arguments: {
        description: "A blue cube",
        filePath: "assets/cube.png"
      }
    });
    expect(isForwardableSDKToolCall(image)).toBe(true);

    const screen = normalizeSDKToolCall({
      type: "client_record_screen",
      args: {
        mode: "START_RECORDING"
      }
    });

    expect(screen).toEqual({
      name: "recordScreen",
      arguments: {
        mode: "START_RECORDING"
      }
    });
    expect(isForwardableSDKToolCall(screen)).toBe(true);
  });

  it("normalizes SDK tool calls that use OpenAI-style argument keys", () => {
    const normalized = normalizeSDKToolCall({
      name: "glob",
      arguments: {
        targetDirectory: "src",
        globPattern: "**/*.tsx"
      }
    });

    expect(normalized).toEqual({
      name: "glob",
      arguments: {
        targetDirectory: "src",
        globPattern: "**/*.tsx"
      }
    });
    expect(isForwardableSDKToolCall(normalized)).toBe(true);
  });

  it("normalizes local client MCP forwarding tools with alternate payload keys", () => {
    const normalized = normalizeSDKToolCall({
      type: "mcp",
      arguments: {
        providerIdentifier: "client",
        toolName: "client_glob",
        arguments: JSON.stringify({
          targetDirectory: "src",
          globPattern: "**/*.tsx"
        })
      }
    });

    expect(normalized).toEqual({
      name: "glob",
      arguments: {
        targetDirectory: "src",
        globPattern: "**/*.tsx"
      }
    });
    expect(isForwardableSDKToolCall(normalized)).toBe(true);
  });

  it("normalizes local client MCP forwarding tools with direct payload fields", () => {
    const normalized = normalizeSDKToolCall({
      type: "mcp",
      args: {
        providerIdentifier: "client",
        toolName: "client_glob",
        targetDirectory: "src",
        globPattern: "**/*.tsx"
      }
    });

    expect(normalized).toEqual({
      name: "glob",
      arguments: {
        targetDirectory: "src",
        globPattern: "**/*.tsx"
      }
    });
    expect(isForwardableSDKToolCall(normalized)).toBe(true);
  });

  it("keeps dynamic harness MCP tools as client MCP calls", () => {
    const clientTools = [
      {
        name: "probe_write_file",
        parameters: {
          type: "object",
          properties: {
            file_path: { type: "string" },
            contents: { type: "string" }
          },
          required: ["file_path", "contents"]
        }
      }
    ];
    const normalized = normalizeSDKToolCall({
      type: "mcp",
      args: {
        providerIdentifier: "client",
        toolName: "probe_write_file",
        args: {
          file_path: "marker.txt",
          contents: "ok"
        }
      }
    }, clientTools);

    expect(normalized).toEqual({
      name: "mcp",
      arguments: {
        providerIdentifier: "client",
        toolName: "probe_write_file",
        args: {
          file_path: "marker.txt",
          contents: "ok"
        }
      }
    });
    expect(isForwardableSDKToolCall(normalized, clientTools)).toBe(true);
  });

  it("keeps dynamic harness MCP tools with direct payload fields as client MCP calls", () => {
    const clientTools = [
      {
        name: "probe_write_file",
        parameters: {
          type: "object",
          properties: {
            file_path: { type: "string" },
            contents: { type: "string" }
          },
          required: ["file_path", "contents"]
        }
      }
    ];
    const normalized = normalizeSDKToolCall({
      type: "mcp",
      args: {
        providerIdentifier: "client",
        toolName: "probe_write_file",
        file_path: "marker.txt",
        contents: "ok"
      }
    }, clientTools);

    expect(normalized).toEqual({
      name: "mcp",
      arguments: {
        providerIdentifier: "client",
        toolName: "probe_write_file",
        args: {
          file_path: "marker.txt",
          contents: "ok"
        }
      }
    });
    expect(isForwardableSDKToolCall(normalized, clientTools)).toBe(true);
  });

  it("keeps provider-style harness tools on the local client MCP server", () => {
    const clientTools = [
      {
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
    ];
    const normalized = normalizeSDKToolCall({
      type: "mcp",
      args: {
        providerIdentifier: "client",
        toolName: "mcp__filesystem__write_file",
        args: {
          file_path: "marker.txt",
          contents: "ok"
        }
      }
    }, clientTools);

    expect(normalized).toEqual({
      name: "mcp",
      arguments: {
        providerIdentifier: "client",
        toolName: "mcp__filesystem__write_file",
        args: {
          file_path: "marker.txt",
          contents: "ok"
        }
      }
    });
    expect(isForwardableSDKToolCall(normalized, clientTools)).toBe(true);
  });

  it("normalizes direct dynamic harness MCP tool events to SDK MCP calls", () => {
    const clientTools = [
      {
        name: "probe_write_file",
        parameters: {
          type: "object",
          properties: {
            file_path: { type: "string" },
            contents: { type: "string" }
          },
          required: ["file_path", "contents"]
        }
      }
    ];
    const normalized = normalizeSDKToolCall({
      type: "probe_write_file",
      args: {
        file_path: "marker.txt",
        contents: "ok"
      }
    }, clientTools);

    expect(normalized).toEqual({
      name: "mcp",
      arguments: {
        providerIdentifier: "client",
        toolName: "probe_write_file",
        args: {
          file_path: "marker.txt",
          contents: "ok"
        }
      }
    });
    expect(isForwardableSDKToolCall(normalized, clientTools)).toBe(true);
  });

  it("normalizes direct provider-style harness MCP tool events to exact client MCP calls", () => {
    const clientTools = [
      {
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
    ];
    const normalized = normalizeSDKToolCall({
      type: "mcp__filesystem__write_file",
      args: {
        file_path: "marker.txt",
        contents: "ok"
      }
    }, clientTools);

    expect(normalized).toEqual({
      name: "mcp",
      arguments: {
        providerIdentifier: "client",
        toolName: "mcp__filesystem__write_file",
        args: {
          file_path: "marker.txt",
          contents: "ok"
        }
      }
    });
    expect(isForwardableSDKToolCall(normalized, clientTools)).toBe(true);
  });

  it("does not forward SDK tool calls that were not exposed by the harness", () => {
    expect(isForwardableSDKToolCall({
      name: "unexpected_tool",
      arguments: { path: "marker.txt", content: "ok" }
    })).toBe(false);
    expect(isForwardableSDKToolCall({
      name: "mcp",
      arguments: {
        providerIdentifier: "github",
        toolName: "create_issue",
        args: { title: "Bug", body: "Details" }
      }
    })).toBe(false);
  });

  it("waits for complete direct dynamic harness tool arguments before forwarding", () => {
    const clientTools = [
      {
        name: "probe_write_file",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            file_path: { type: "string" },
            contents: { type: "string", minLength: 1 }
          },
          required: ["file_path", "contents"]
        }
      }
    ];

    const partial = normalizeSDKToolCall({
      type: "probe_write_file",
      args: { file_path: "marker.txt" }
    }, clientTools);
    const invalid = normalizeSDKToolCall({
      type: "probe_write_file",
      args: { file_path: "marker.txt", contents: "" }
    }, clientTools);
    const complete = normalizeSDKToolCall({
      type: "probe_write_file",
      args: { file_path: "marker.txt", contents: "ok" }
    }, clientTools);

    expect(isForwardableSDKToolCall(partial, clientTools)).toBe(false);
    expect(isForwardableSDKToolCall(invalid, clientTools)).toBe(false);
    expect(isForwardableSDKToolCall(complete, clientTools)).toBe(true);
  });

  it("waits for complete provider-style MCP tool arguments before forwarding", () => {
    const clientTools = [
      {
        name: "mcp__github__create_issue",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            title: { type: "string", minLength: 1 },
            body: { type: "string", minLength: 1 }
          },
          required: ["title", "body"]
        }
      }
    ];

    const partial = normalizeSDKToolCall({
      type: "mcp",
      args: {
        providerIdentifier: "github",
        toolName: "create_issue",
        args: { title: "Bug" }
      }
    }, clientTools);
    const complete = normalizeSDKToolCall({
      type: "mcp",
      args: {
        providerIdentifier: "github",
        toolName: "create_issue",
        args: { title: "Bug", body: "Details" }
      }
    }, clientTools);

    expect(isForwardableSDKToolCall(partial, clientTools)).toBe(false);
    expect(isForwardableSDKToolCall(complete, clientTools)).toBe(true);
  });

  it("accepts provider-style SDK MCP calls through generic wrapper tools", () => {
    const clientTools = [
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
                mode: { type: "string", enum: ["create", "overwrite"] },
                filePath: { type: "string" },
                content: { type: "string" },
                description: { type: "string" }
              },
              required: ["mode", "filePath", "content", "description"]
            }
          },
          required: ["serverName", "toolName", "input"]
        }
      }
    ];

    const partial = normalizeSDKToolCall({
      type: "mcp",
      args: {
        providerIdentifier: "filesystem",
        toolName: "write_file",
        args: { file_path: "src/App.tsx" }
      }
    }, clientTools);
    const complete = normalizeSDKToolCall({
      type: "mcp",
      args: {
        providerIdentifier: "filesystem",
        toolName: "write_file",
        args: {
          file_path: "src/App.tsx",
          contents: "export default function App() { return null }"
        }
      }
    }, clientTools);

    expect(isForwardableSDKToolCall(partial, clientTools)).toBe(false);
    expect(isForwardableSDKToolCall(complete, clientTools)).toBe(true);
  });

  it("requires exact nested wrapper schemas for unknown provider-style SDK MCP tools", () => {
    const clientTools = [
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
                title: { type: "string", minLength: 1 },
                body: { type: "string", minLength: 1 }
              },
              required: ["title", "body"]
            }
          },
          required: ["serverName", "toolName", "input"]
        }
      }
    ];

    const partial = normalizeSDKToolCall({
      type: "mcp",
      args: {
        providerIdentifier: "github",
        toolName: "create_issue",
        args: { title: "Bug" }
      }
    }, clientTools);
    const complete = normalizeSDKToolCall({
      type: "mcp",
      args: {
        providerIdentifier: "github",
        toolName: "create_issue",
        args: { title: "Bug", body: "Details" }
      }
    }, clientTools);

    expect(isForwardableSDKToolCall(partial, clientTools)).toBe(false);
    expect(isForwardableSDKToolCall(complete, clientTools)).toBe(true);
  });

  it("exposes dynamic client tool schemas through the forwarding MCP server", () => {
    const tools = clientMcpToolDefinitions([
      {
        name: "probe_write_file",
        description: "Writes a marker through the harness MCP server.",
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
    ]);

    expect(tools.some((tool) => tool.name === "client_shell")).toBe(true);
    expect(tools.some((tool) => tool.name === "client_task")).toBe(true);
    expect(tools.find((tool) => tool.name === "probe_write_file")).toMatchObject({
      description: "Writes a marker through the harness MCP server.",
      inputSchema: {
        additionalProperties: false,
        required: ["file_path", "contents"]
      }
    });
    expect(tools.map((tool) => tool.name).indexOf("probe_write_file")).toBeLessThan(
      tools.map((tool) => tool.name).indexOf("client_shell")
    );
  });

  it("unwraps common dynamic client tool schema wrappers", () => {
    const tools = clientMcpToolDefinitions([
      {
        name: "wrapped_write_file",
        parameters: {
          json_schema: {
            name: "wrapped_write_file",
            schema: {
              type: "object",
              additionalProperties: false,
              properties: {
                path: { type: "string" },
                content: { type: "string" }
              },
              required: ["path", "content"]
            }
          }
        }
      }
    ]);

    expect(tools.find((tool) => tool.name === "wrapped_write_file")).toMatchObject({
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["path", "content"]
      }
    });
    expect(validateClientMcpToolCall(tools, "wrapped_write_file", { path: "marker.txt" })).toBe("Missing required argument for wrapped_write_file: content");
    expect(validateClientMcpToolCall(tools, "wrapped_write_file", { path: "marker.txt", content: "ok" })).toBe(null);
  });

  it("rejects unknown or incomplete client MCP forwarding calls internally", () => {
    const tools = clientMcpToolDefinitions([
      {
        name: "probe_write_file",
        parameters: {
          type: "object",
          properties: {
            file_path: { type: "string" },
            contents: { type: "string" }
          },
          required: ["file_path", "contents"]
        }
      }
    ]);

    expect(validateClientMcpToolCall(tools, "missing_tool", {})).toContain("Unknown client MCP forwarding tool");
    expect(validateClientMcpToolCall(tools, "probe_write_file", { file_path: "marker.txt" })).toBe("Missing required argument for probe_write_file: contents");
    expect(validateClientMcpToolCall(tools, "probe_write_file", { file_path: "marker.txt", contents: "" })).toBe(null);
  });

  it("validates dynamic client MCP schemas with local references", () => {
    const tools = clientMcpToolDefinitions([
      {
        name: "ref_write_file",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            target: { $ref: "#/$defs/fileTarget" },
            metadata: { $ref: "#/definitions/metadata" },
            format: { anyOf: [{ $ref: "#/$defs/format" }, { type: "null" }] }
          },
          required: ["target", "metadata"],
          $defs: {
            fileTarget: {
              type: "object",
              additionalProperties: false,
              properties: {
                path: { type: "string" },
                mode: { type: "string", enum: ["create", "overwrite"] }
              },
              required: ["path", "mode"]
            },
            format: { type: "string", enum: ["text", "markdown"] }
          },
          definitions: {
            metadata: {
              type: "object",
              additionalProperties: false,
              properties: {
                tags: { type: "array", items: { type: "string" }, minItems: 1 }
              },
              required: ["tags"]
            }
          }
        }
      }
    ]);

    expect(validateClientMcpToolCall(tools, "ref_write_file", {
      target: { path: "src/App.tsx" },
      metadata: { tags: ["ui"] }
    })).toBe("Missing required argument for ref_write_file.target: mode");
    expect(validateClientMcpToolCall(tools, "ref_write_file", {
      target: { path: "src/App.tsx", mode: "append" },
      metadata: { tags: ["ui"] }
    })).toContain("expected one of");
    expect(validateClientMcpToolCall(tools, "ref_write_file", {
      target: { path: "src/App.tsx", mode: "create" },
      metadata: { tags: [42] }
    })).toBe("Invalid value for ref_write_file.metadata.tags[0]: expected string");
    expect(validateClientMcpToolCall(tools, "ref_write_file", {
      target: { path: "src/App.tsx", mode: "create" },
      metadata: { tags: ["ui"] },
      format: null
    })).toBe(null);
    expect(validateClientMcpToolCall(tools, "ref_write_file", {
      target: { path: "src/App.tsx", mode: "create" },
      metadata: { tags: ["ui"] },
      format: "markdown"
    })).toBe(null);
  });

  it("validates dynamic client MCP scalar constraints", () => {
    const tools = clientMcpToolDefinitions([
      {
        name: "constrained_search",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            query: { type: "string", minLength: 2, maxLength: 12, pattern: "^[A-Za-z0-9_]+$" },
            limit: { type: "integer", minimum: 1, maximum: 50, multipleOf: 5 }
          },
          required: ["query", "limit"]
        }
      }
    ]);

    expect(validateClientMcpToolCall(tools, "constrained_search", { query: "", limit: 5 })).toBe("Invalid value for constrained_search.query: expected at least 2 character(s)");
    expect(validateClientMcpToolCall(tools, "constrained_search", { query: "todo app", limit: 5 })).toContain("expected to match pattern");
    expect(validateClientMcpToolCall(tools, "constrained_search", { query: "todo_app_name", limit: 5 })).toBe("Invalid value for constrained_search.query: expected at most 12 character(s)");
    expect(validateClientMcpToolCall(tools, "constrained_search", { query: "todo_app", limit: 0 })).toBe("Invalid value for constrained_search.limit: expected >= 1");
    expect(validateClientMcpToolCall(tools, "constrained_search", { query: "todo_app", limit: 55 })).toBe("Invalid value for constrained_search.limit: expected <= 50");
    expect(validateClientMcpToolCall(tools, "constrained_search", { query: "todo_app", limit: 7 })).toBe("Invalid value for constrained_search.limit: expected a multiple of 5");
    expect(validateClientMcpToolCall(tools, "constrained_search", { query: "todo_app", limit: 10 })).toBe(null);
  });

  it("validates dynamic client MCP array membership constraints", () => {
    const tools = clientMcpToolDefinitions([
      {
        name: "run_steps",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            steps: {
              type: "array",
              items: { type: "string" },
              uniqueItems: true,
              contains: { const: "build" },
              minContains: 1,
              maxContains: 1
            },
            labels: {
              type: "array",
              items: { type: "string" },
              contains: { type: "string", pattern: "^release:" },
              minContains: 0,
              maxContains: 1
            }
          },
          required: ["steps"]
        }
      }
    ]);

    expect(validateClientMcpToolCall(tools, "run_steps", {
      steps: ["install", "build", "test"],
      labels: ["release:stable", "ui"]
    })).toBe(null);
    expect(validateClientMcpToolCall(tools, "run_steps", {
      steps: ["build", "build"]
    })).toBe("Invalid value for run_steps.steps: expected unique items");
    expect(validateClientMcpToolCall(tools, "run_steps", {
      steps: ["install", "test"]
    })).toBe("Invalid value for run_steps.steps: expected at least 1 matching item");
    expect(validateClientMcpToolCall(tools, "run_steps", {
      steps: ["build", "package", "build"]
    })).toBe("Invalid value for run_steps.steps: expected unique items");
    expect(validateClientMcpToolCall(tools, "run_steps", {
      steps: ["build"],
      labels: ["release:stable", "release:beta"]
    })).toBe("Invalid value for run_steps.labels: expected at most 1 matching item");
  });

  it("validates dynamic client MCP tuple array schemas", () => {
    const tools = clientMcpToolDefinitions([
      {
        name: "run_pipeline",
        parameters: {
          type: "object",
          properties: {
            steps: {
              type: "array",
              items: [
                { const: "install" },
                { const: "build" }
              ],
              additionalItems: false
            }
          },
          required: ["steps"]
        }
      }
    ]);

    expect(validateClientMcpToolCall(tools, "run_pipeline", {
      steps: ["install", "build"]
    })).toBe(null);
    expect(validateClientMcpToolCall(tools, "run_pipeline", {
      steps: ["install", "test"]
    })).toBe("Invalid value for run_pipeline.steps[1]: expected constant \"build\"");
    expect(validateClientMcpToolCall(tools, "run_pipeline", {
      steps: ["install", "build", "test"]
    })).toBe("Unexpected array item for run_pipeline.steps: 2");
  });

  it("validates dynamic client MCP unevaluated object properties", () => {
    const tools = clientMcpToolDefinitions([
      {
        name: "configure_deploy",
        parameters: {
          type: "object",
          allOf: [
            {
              properties: {
                command: { type: "string" }
              },
              required: ["command"]
            },
            {
              properties: {
                metadata: {
                  type: "object",
                  properties: {
                    owner: { type: "string" }
                  },
                  required: ["owner"],
                  unevaluatedProperties: false
                }
              },
              required: ["metadata"]
            }
          ],
          unevaluatedProperties: false
        }
      }
    ]);

    expect(validateClientMcpToolCall(tools, "configure_deploy", {
      command: "npm run build",
      metadata: { owner: "web" }
    })).toBe(null);
    expect(validateClientMcpToolCall(tools, "configure_deploy", {
      command: "npm run build",
      metadata: { owner: "web", extra: true }
    })).toBe("Unexpected argument for configure_deploy.metadata: extra");
    expect(validateClientMcpToolCall(tools, "configure_deploy", {
      command: "npm run build",
      metadata: { owner: "web" },
      debug: true
    })).toBe("Unexpected argument for configure_deploy: debug");
  });

  it("treats additionalProperties schemas as evaluated for unevaluated object properties", () => {
    const tools = clientMcpToolDefinitions([
      {
        name: "configure_env",
        parameters: {
          type: "object",
          properties: {
            command: { type: "string" }
          },
          required: ["command"],
          additionalProperties: { type: "string", minLength: 1 },
          unevaluatedProperties: false
        }
      }
    ]);

    expect(validateClientMcpToolCall(tools, "configure_env", {
      command: "npm run build",
      NODE_ENV: "production"
    })).toBe(null);
    expect(validateClientMcpToolCall(tools, "configure_env", {
      command: "npm run build",
      NODE_ENV: ""
    })).toBe("Invalid value for configure_env.NODE_ENV: expected at least 1 character(s)");
    expect(validateClientMcpToolCall(tools, "configure_env", {
      command: "npm run build",
      DEBUG: true
    })).toBe("Invalid value for configure_env.DEBUG: expected string");
  });

  it("treats dependentSchemas as evaluated for unevaluated object properties", () => {
    const tools = clientMcpToolDefinitions([
      {
        name: "run_command",
        parameters: {
          type: "object",
          properties: {
            command: { type: "string" }
          },
          required: ["command"],
          dependentSchemas: {
            command: {
              properties: {
                cwd: { type: "string" }
              },
              required: ["cwd"]
            }
          },
          unevaluatedProperties: false
        }
      }
    ]);

    expect(validateClientMcpToolCall(tools, "run_command", {
      command: "npm run build",
      cwd: "."
    })).toBe(null);
    expect(validateClientMcpToolCall(tools, "run_command", {
      command: "npm run build"
    })).toBe("Missing required argument for run_command: cwd");
    expect(validateClientMcpToolCall(tools, "run_command", {
      command: "npm run build",
      cwd: ".",
      debug: true
    })).toBe("Unexpected argument for run_command: debug");
  });

  it("treats contains matches as evaluated for unevaluated array items", () => {
    const tools = clientMcpToolDefinitions([
      {
        name: "run_pipeline",
        parameters: {
          type: "object",
          properties: {
            steps: {
              type: "array",
              prefixItems: [{ const: "install" }],
              contains: { const: "build" },
              minContains: 1,
              unevaluatedItems: false
            }
          },
          required: ["steps"]
        }
      }
    ]);

    expect(validateClientMcpToolCall(tools, "run_pipeline", {
      steps: ["install", "build"]
    })).toBe(null);
    expect(validateClientMcpToolCall(tools, "run_pipeline", {
      steps: ["install", "build", "test"]
    })).toBe("Unexpected array item for run_pipeline.steps: 2");
  });

  it("validates dynamic client MCP oneOf schemas exactly", () => {
    const tools = clientMcpToolDefinitions([
      {
        name: "deploy_target",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            target: {
              oneOf: [
                {
                  type: "object",
                  properties: { path: { type: "string" } },
                  required: ["path"]
                },
                {
                  type: "object",
                  properties: { path: { type: "string" }, mode: { const: "preview" } },
                  required: ["path", "mode"]
                }
              ]
            }
          },
          required: ["target"]
        }
      }
    ]);

    expect(validateClientMcpToolCall(tools, "deploy_target", {
      target: { path: "dist" }
    })).toBe(null);
    expect(validateClientMcpToolCall(tools, "deploy_target", {
      target: { path: "dist", mode: "preview" }
    })).toBe("Invalid value for deploy_target.target: matched more than one allowed schema");
    expect(validateClientMcpToolCall(tools, "deploy_target", {
      target: { mode: "preview" }
    })).toBe("Invalid value for deploy_target.target: did not match any allowed schema");
  });

  it("validates dynamic client MCP conditional schemas", () => {
    const tools = clientMcpToolDefinitions([
      {
        name: "send_notice",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            channel: { type: "string", enum: ["email", "slack"] },
            message: { type: "string" },
            email: { type: "string", minLength: 3 },
            channelId: { type: "string", pattern: "^C[A-Z0-9]+$" }
          },
          required: ["channel", "message"],
          if: {
            properties: { channel: { const: "email" } },
            required: ["channel"]
          },
          then: {
            required: ["email"]
          },
          else: {
            required: ["channelId"]
          }
        }
      }
    ]);

    expect(validateClientMcpToolCall(tools, "send_notice", {
      channel: "email",
      message: "Build passed",
      email: "dev@example.com"
    })).toBe(null);
    expect(validateClientMcpToolCall(tools, "send_notice", {
      channel: "slack",
      message: "Build passed",
      channelId: "C123"
    })).toBe(null);
    expect(validateClientMcpToolCall(tools, "send_notice", {
      channel: "email",
      message: "Build passed"
    })).toBe("Missing required argument for send_notice: email");
    expect(validateClientMcpToolCall(tools, "send_notice", {
      channel: "slack",
      message: "Build passed"
    })).toBe("Missing required argument for send_notice: channelId");
  });

  it("validates dynamic client MCP branch-specific conditional schemas", () => {
    const tools = clientMcpToolDefinitions([
      {
        name: "send_notice",
        parameters: {
          type: "object",
          unevaluatedProperties: false,
          properties: {
            channel: { type: "string", enum: ["email", "slack"] },
            message: { type: "string" }
          },
          required: ["channel", "message"],
          if: {
            properties: { channel: { const: "email" } },
            required: ["channel"]
          },
          then: {
            properties: { email: { type: "string", minLength: 3 } },
            required: ["email"]
          },
          else: {
            properties: { channelId: { type: "string", pattern: "^C[A-Z0-9]+$" } },
            required: ["channelId"]
          }
        }
      }
    ]);

    expect(validateClientMcpToolCall(tools, "send_notice", {
      channel: "email",
      message: "Build passed",
      email: "dev@example.com"
    })).toBe(null);
    expect(validateClientMcpToolCall(tools, "send_notice", {
      channel: "slack",
      message: "Build passed",
      channelId: "C123"
    })).toBe(null);
    expect(validateClientMcpToolCall(tools, "send_notice", {
      channel: "slack",
      message: "Build passed",
      channelId: "C123",
      email: "dev@example.com"
    })).toBe("Unexpected argument for send_notice: email");
    expect(validateClientMcpToolCall(tools, "send_notice", {
      channel: "email",
      message: "Build passed",
      email: "dev@example.com",
      channelId: "C123"
    })).toBe("Unexpected argument for send_notice: channelId");
  });

  it("validates dynamic client MCP pattern properties", () => {
    const tools = clientMcpToolDefinitions([
      {
        name: "run_with_env",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            command: { type: "string" },
            env: {
              type: "object",
              additionalProperties: false,
              patternProperties: {
                "^VITE_[A-Z0-9_]+$": { type: "string", minLength: 1 }
              }
            }
          },
          required: ["command", "env"]
        }
      }
    ]);

    expect(validateClientMcpToolCall(tools, "run_with_env", {
      command: "npm run build",
      env: { VITE_API_URL: "https://example.com" }
    })).toBe(null);
    expect(validateClientMcpToolCall(tools, "run_with_env", {
      command: "npm run build",
      env: { API_URL: "https://example.com" }
    })).toBe("Unexpected argument for run_with_env.env: API_URL");
    expect(validateClientMcpToolCall(tools, "run_with_env", {
      command: "npm run build",
      env: { VITE_API_URL: "" }
    })).toBe("Invalid value for run_with_env.env.VITE_API_URL: expected at least 1 character(s)");
  });

  it("validates dynamic client MCP object key constraints", () => {
    const tools = clientMcpToolDefinitions([
      {
        name: "configure_env",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            settings: {
              type: "object",
              minProperties: 1,
              maxProperties: 2,
              propertyNames: { type: "string", pattern: "^APP_[A-Z0-9_]+$" },
              patternProperties: {
                "^APP_SECRET$": false
              },
              additionalProperties: { type: "string", minLength: 1 },
              dependentRequired: {
                APP_TOKEN: ["APP_URL"]
              }
            }
          },
          required: ["settings"]
        }
      }
    ]);

    expect(validateClientMcpToolCall(tools, "configure_env", {
      settings: { APP_URL: "https://example.com", APP_TOKEN: "secret" }
    })).toBe(null);
    expect(validateClientMcpToolCall(tools, "configure_env", {
      settings: {}
    })).toBe("Invalid value for configure_env.settings: expected at least 1 property");
    expect(validateClientMcpToolCall(tools, "configure_env", {
      settings: { APP_URL: "https://example.com", APP_TOKEN: "secret", APP_MODE: "prod" }
    })).toBe("Invalid value for configure_env.settings: expected at most 2 properties");
    expect(validateClientMcpToolCall(tools, "configure_env", {
      settings: { API_URL: "https://example.com" }
    })).toContain("configure_env.settings property name API_URL");
    expect(validateClientMcpToolCall(tools, "configure_env", {
      settings: { APP_TOKEN: "secret" }
    })).toBe("Missing dependent argument for configure_env.settings: APP_URL");
    expect(validateClientMcpToolCall(tools, "configure_env", {
      settings: { APP_SECRET: "secret" }
    })).toBe("Invalid value for configure_env.settings.APP_SECRET: schema disallows value");
    expect(validateClientMcpToolCall(tools, "configure_env", {
      settings: { APP_URL: "" }
    })).toBe("Invalid value for configure_env.settings.APP_URL: expected at least 1 character(s)");
  });

  it("validates nested dynamic client MCP schemas before accepting forwarding calls", () => {
    const tools = clientMcpToolDefinitions([
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
                filePath: { type: "string" },
                content: { type: "string" },
                mode: { type: "string", enum: ["create", "overwrite"] },
                metadata: {
                  type: "object",
                  properties: {
                    tags: { type: "array", items: { type: "string" }, minItems: 1 }
                  },
                  required: ["tags"],
                  additionalProperties: false
                },
                format: { anyOf: [{ type: "string", enum: ["text", "markdown"] }, { type: "null" }] }
              },
              required: ["filePath", "content", "mode", "metadata"]
            }
          },
          required: ["serverName", "toolName", "input"]
        }
      }
    ]);

    expect(validateClientMcpToolCall(tools, "call_mcp_tool", {
      serverName: "filesystem",
      toolName: "write_file",
      input: { filePath: "src/App.tsx", content: "ok", mode: "create" }
    })).toBe("Missing required argument for call_mcp_tool.input: metadata");
    expect(validateClientMcpToolCall(tools, "call_mcp_tool", {
      serverName: "filesystem",
      toolName: "write_file",
      input: { filePath: "src/App.tsx", content: "ok", mode: "append", metadata: { tags: ["ui"] } }
    })).toContain("expected one of");
    expect(validateClientMcpToolCall(tools, "call_mcp_tool", {
      serverName: "filesystem",
      toolName: "write_file",
      input: { filePath: "src/App.tsx", content: "ok", mode: "create", metadata: { tags: [42] } }
    })).toBe("Invalid value for call_mcp_tool.input.metadata.tags[0]: expected string");
    expect(validateClientMcpToolCall(tools, "call_mcp_tool", {
      serverName: "filesystem",
      toolName: "write_file",
      input: { filePath: "src/App.tsx", content: "ok", mode: "create", metadata: { tags: ["ui"] }, extra: true }
    })).toBe("Unexpected argument for call_mcp_tool.input: extra");
    expect(validateClientMcpToolCall(tools, "call_mcp_tool", {
      serverName: "filesystem",
      toolName: "write_file",
      input: { filePath: "src/App.tsx", content: "ok", mode: "create", metadata: { tags: ["ui"] }, format: null }
    })).toBe(null);
  });

  it("bundles nested schema validation into the generated MCP forwarding server", () => {
    const source = clientForwardingMcpServerSource([
      {
        name: "call_mcp_tool",
        parameters: {
          type: "object",
          properties: {
            serverName: { type: "string" },
            input: {
              type: "object",
              properties: {
                mode: { type: "string", enum: ["create"] }
              },
              required: ["mode"]
            }
          },
          required: ["serverName", "input"]
        }
      }
    ]);
    const message = {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: {
        name: "call_mcp_tool",
        arguments: {
          serverName: "filesystem",
          input: { mode: "append" }
        }
      }
    };

    const result = spawnSync(process.execPath, ["-e", source], {
      input: `${JSON.stringify(message)}\n`,
      encoding: "utf8",
      timeout: 1000
    });

    expect(result.status).toBe(0);
    expect(result.stderr).toBe("");
    const response = JSON.parse(result.stdout.trim());
    expect(response.error.message).toContain("expected one of");
  });

  it("bundles referenced schema validation into the generated MCP forwarding server", () => {
    const source = clientForwardingMcpServerSource([
      {
        name: "ref_write_file",
        parameters: {
          type: "object",
          properties: {
            target: { $ref: "#/$defs/fileTarget" }
          },
          required: ["target"],
          $defs: {
            fileTarget: {
              type: "object",
              properties: {
                mode: { type: "string", enum: ["create"] }
              },
              required: ["mode"]
            }
          }
        }
      }
    ]);
    const message = {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: {
        name: "ref_write_file",
        arguments: {
          target: { mode: "append" }
        }
      }
    };

    const result = spawnSync(process.execPath, ["-e", source], {
      input: `${JSON.stringify(message)}\n`,
      encoding: "utf8",
      timeout: 1000
    });

    expect(result.status).toBe(0);
    expect(result.stderr).toBe("");
    const response = JSON.parse(result.stdout.trim());
    expect(response.error.message).toContain("expected one of");
  });

  it("does not fake a forwarded MCP result when the bridge callback is unavailable", () => {
    const source = clientForwardingMcpServerSource([]);
    const message = {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: {
        name: "client_shell",
        arguments: {
          command: "printf SHOULD_NOT_RUN"
        }
      }
    };

    const result = spawnSync(process.execPath, ["-e", source], {
      input: `${JSON.stringify(message)}\n`,
      encoding: "utf8",
      timeout: 3000,
      env: {
        ...process.env,
        CURSOR_SDK_BRIDGE_CALLBACK_URL: "http://127.0.0.1:1/client-tool-call",
        CURSOR_SDK_BRIDGE_AGENT_CACHE_KEY: "cache-key"
      }
    });

    expect(result.status).toBe(0);
    expect(result.stderr).toBe("");
    const response = JSON.parse(result.stdout.trim());
    expect(response.error.message).toContain("Outer client callback unavailable");
  });

  it("posts forwarded MCP tool calls to the bridge callback before returning success", async () => {
    let observedRequest;
    const callbackServer = http.createServer((request, response) => {
      let body = "";
      request.setEncoding("utf8");
      request.on("data", (chunk) => {
        body += chunk;
      });
      request.on("end", () => {
        observedRequest = {
          url: request.url,
          authorization: request.headers.authorization,
          body: JSON.parse(body)
        };
        response.writeHead(200, { "Content-Type": "application/json" });
        response.end(JSON.stringify({ ok: true, accepted: true }));
      });
    });

    await new Promise((resolve) => callbackServer.listen(0, "127.0.0.1", resolve));
    const address = callbackServer.address();
    const port = typeof address === "object" && address ? address.port : 0;
    const child = spawn(process.execPath, [bridgeScriptPath, "--client-mcp-server"], {
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        CURSOR_SDK_BRIDGE_CALLBACK_URL: `http://127.0.0.1:${port}/client-tool-call`,
        CURSOR_SDK_BRIDGE_CALLBACK_TOKEN: "bridge-token",
        CURSOR_SDK_BRIDGE_AGENT_CACHE_KEY: "cache-key",
        CURSOR_SDK_BRIDGE_CLIENT_TOOLS_JSON: JSON.stringify(clientMcpToolDefinitions([]))
      }
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });

    const message = {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: {
        name: "client_shell",
        arguments: {
          command: "printf CALLBACK_OK"
        }
      }
    };
    child.stdin.end(`${JSON.stringify(message)}\n`);

    const exitCode = await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        child.kill("SIGKILL");
        reject(new Error("generated MCP server did not exit"));
      }, 3000);
      child.on("error", (error) => {
        clearTimeout(timeout);
        reject(error);
      });
      child.on("exit", (code) => {
        clearTimeout(timeout);
        resolve(code);
      });
    });
    callbackServer.close();

    expect(exitCode).toBe(0);
    expect(stderr).toBe("");
    const response = JSON.parse(stdout.trim());
    expect(response.result.content[0].text).toBe("FORWARDED_TO_OUTER_CLIENT");
    expect(observedRequest).toEqual({
      url: "/client-tool-call",
      authorization: "Bearer bridge-token",
      body: {
        cacheKey: "cache-key",
        toolName: "client_shell",
        arguments: {
          command: "printf CALLBACK_OK"
        }
      }
    });
  });

  it("keeps exact custom harness MCP tools available in the subcommand server", async () => {
    let observedRequest;
    const callbackServer = http.createServer((request, response) => {
      let body = "";
      request.setEncoding("utf8");
      request.on("data", (chunk) => {
        body += chunk;
      });
      request.on("end", () => {
        observedRequest = {
          url: request.url,
          authorization: request.headers.authorization,
          body: JSON.parse(body)
        };
        setTimeout(() => {
          response.writeHead(200, { "Content-Type": "application/json" });
          response.end(JSON.stringify({ ok: true, accepted: true }));
        }, 50);
      });
    });

    await new Promise((resolve) => callbackServer.listen(0, "127.0.0.1", resolve));
    const address = callbackServer.address();
    const port = typeof address === "object" && address ? address.port : 0;
    const tools = clientMcpToolDefinitions([
      {
        name: "mcp__github__create_issue",
        description: "Create a GitHub issue through the outer harness MCP server.",
        parameters: {
          type: "object",
          properties: {
            owner: { type: "string" },
            repo: { type: "string" },
            title: { type: "string" },
            body: { type: "string" }
          },
          required: ["owner", "repo", "title", "body"],
          additionalProperties: false
        }
      }
    ]);
    const child = spawn(process.execPath, [bridgeScriptPath, "--client-mcp-server"], {
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        CURSOR_SDK_BRIDGE_CALLBACK_URL: `http://127.0.0.1:${port}/client-tool-call`,
        CURSOR_SDK_BRIDGE_CALLBACK_TOKEN: "bridge-token",
        CURSOR_SDK_BRIDGE_AGENT_CACHE_KEY: "cache-key",
        CURSOR_SDK_BRIDGE_CLIENT_TOOLS_JSON: JSON.stringify(tools)
      }
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });

    const listMessage = {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/list"
    };
    const callMessage = {
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: {
        name: "mcp__github__create_issue",
        arguments: {
          owner: "octo",
          repo: "hello",
          title: "Smoke",
          body: "OK"
        }
      }
    };
    child.stdin.end(`${JSON.stringify(listMessage)}\n${JSON.stringify(callMessage)}\n`);

    const exitCode = await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        child.kill("SIGKILL");
        reject(new Error("custom MCP forwarding server did not exit"));
      }, 3000);
      child.on("error", (error) => {
        clearTimeout(timeout);
        reject(error);
      });
      child.on("exit", (code) => {
        clearTimeout(timeout);
        resolve(code);
      });
    });
    callbackServer.close();

    expect(exitCode).toBe(0);
    expect(stderr).toBe("");
    const responses = stdout.trim().split(/\n+/).map((line) => JSON.parse(line));
    const listResponse = responses.find((response) => response.id === 1);
    const callResponse = responses.find((response) => response.id === 2);
    expect(listResponse.result.tools.some((tool) => tool.name === "mcp__github__create_issue")).toBe(true);
    expect(callResponse.result.content[0].text).toBe("FORWARDED_TO_OUTER_CLIENT");
    expect(observedRequest).toEqual({
      url: "/client-tool-call",
      authorization: "Bearer bridge-token",
      body: {
        cacheKey: "cache-key",
        toolName: "mcp__github__create_issue",
        arguments: {
          owner: "octo",
          repo: "hello",
          title: "Smoke",
          body: "OK"
        }
      }
    });
  });

  it("tells the SDK to forward compatible client tools through MCP", () => {
    const prompt = bridgePrompt("USER: create a file", [
      { name: "bash" },
      { name: "write" }
    ]);

    expect(prompt).toContain("outer client tools are: bash, write");
    expect(prompt).toContain("Use SDK mcp with providerIdentifier \"client\" for every local operation");
    expect(prompt).toContain("client_shell");
    expect(prompt).toContain("Prefer exact client tools and dedicated client MCP tools");
    expect(prompt).toContain("LOCAL TOOL RESULT records are present");
    expect(prompt).toContain("emit exactly one client MCP forwarding tool call and no prose");
  });

  it("uses SDK-compatible local options that do not wedge local runs", () => {
    const input = {
      apiKey: "test-key",
      model: "composer-2.5",
      workingDirectory: "/tmp/project",
      clientTools: []
    };

    const createOptions = localAgentCreateOptions(input);
    const sendOptions = localAgentSendOptions(input);

    expect(createOptions.local).toEqual({
      cwd: "/tmp/project"
    });
    expect(createOptions.model).toEqual({ id: "composer-2.5", params: [{ id: "fast", value: "false" }] });
    expect(createOptions).not.toHaveProperty("mcpServers");
    expect(createOptions.local).not.toHaveProperty("sandboxOptions");
    expect(createOptions.local).not.toHaveProperty("settingSources");
    expect(sendOptions.model).toEqual({ id: "composer-2.5", params: [{ id: "fast", value: "false" }] });
    expect(sendOptions).not.toHaveProperty("mcpServers");
    expect(sendOptions).not.toHaveProperty("local");
    expect(localAgentSendOptions(input, { force: true }).local).toEqual({ force: true });
  });

  it("routes the public Composer fast model through the SDK with the fast parameter", () => {
    const input = {
      apiKey: "test-key",
      model: "composer-2.5-fast",
      workingDirectory: "/tmp/project",
      clientTools: []
    };

    expect(localAgentCreateOptions(input).model).toEqual({ id: "composer-2.5", params: [{ id: "fast", value: "true" }] });
    expect(localAgentSendOptions(input).model).toEqual({ id: "composer-2.5", params: [{ id: "fast", value: "true" }] });
  });

  it("routes auto/default model through the SDK as the default selector", () => {
    const input = {
      apiKey: "test-key",
      model: "auto",
      workingDirectory: "/tmp/project",
      clientTools: []
    };

    expect(localAgentCreateOptions(input).model).toEqual({ id: "default" });
    expect(localAgentSendOptions(input).model).toEqual({ id: "default" });

    const defaultInput = { ...input, model: "default" };
    expect(localAgentCreateOptions(defaultInput).model).toEqual({ id: "default" });
    expect(localAgentSendOptions(defaultInput).model).toEqual({ id: "default" });
  });

  it("keeps SDK session affinity stable while sending client tools through MCP", () => {
    const baseInput = {
      apiKey: "test-key",
      model: "composer-2.5",
      workingDirectory: "/tmp/project",
      sessionKey: "shared-session",
      clientTools: [
        {
          name: "webfetch",
          parameters: {
            type: "object",
            properties: { url: { type: "string" } },
            required: ["url"]
          }
        }
      ]
    };
    const dynamicInput = {
      ...baseInput,
      clientTools: [
        {
          name: "webfetch",
          parameters: {
            type: "object",
            properties: { url: { type: "string" } },
            required: ["url"]
          }
        },
        {
          name: "probe_write_file",
          parameters: {
            type: "object",
            properties: {
              path: { type: "string" },
              content: { type: "string" }
            },
            required: ["path", "content"]
          }
        }
      ]
    };

    const baseSendOptions = localAgentSendOptions(baseInput);
    const dynamicSendOptions = localAgentSendOptions(dynamicInput);

    expect(dynamicSendOptions.mcpServers.client.env.CURSOR_SDK_BRIDGE_AGENT_CACHE_KEY).toEqual(
      baseSendOptions.mcpServers.client.env.CURSOR_SDK_BRIDGE_AGENT_CACHE_KEY
    );
    expect(baseSendOptions.mcpServers.client.env.CURSOR_SDK_BRIDGE_CLIENT_TOOLS_JSON).toContain("webfetch");
    expect(dynamicSendOptions.mcpServers.client.env.CURSOR_SDK_BRIDGE_CLIENT_TOOLS_JSON).toContain("webfetch");
    expect(dynamicSendOptions.mcpServers.client.env.CURSOR_SDK_BRIDGE_CLIENT_TOOLS_JSON).toContain("probe_write_file");
  });
});
