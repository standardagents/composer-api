import { describe, expect, it } from "vitest";
import { spawnSync } from "node:child_process";
import {
  bridgePrompt,
  clientForwardingMcpServerSource,
  clientMcpToolDefinitions,
  localAgentCreateOptions,
  localAgentSendOptions,
  isForwardableSDKToolCall,
  normalizeSDKToolCall,
  toolCallFromDelta,
  validateClientMcpToolCall
} from "./cursor-sdk-local-agent-bridge.mjs";

describe("Cursor SDK local-agent bridge", () => {
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

  it("extracts partial tool calls without treating tool-call starts as complete", () => {
    const update = {
      type: "partial-tool-call",
      toolCall: {
        type: "glob",
        args: { targeting: "src" }
      }
    };
    const normalized = normalizeSDKToolCall(toolCallFromDelta(update));

    expect(normalized).toEqual({
      name: "glob",
      arguments: { targeting: "src" }
    });
    expect(isForwardableSDKToolCall(normalized)).toBe(false);
  });

  it("requires both provider and tool names for SDK MCP forwarding", () => {
    expect(isForwardableSDKToolCall({ name: "mcp", arguments: { providerIdentifier: "client" } })).toBe(false);
    expect(isForwardableSDKToolCall({ name: "mcp", arguments: { providerIdentifier: "client", toolName: "glob" } })).toBe(true);
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
    });

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
    expect(isForwardableSDKToolCall(normalized)).toBe(true);
  });

  it("keeps dynamic harness MCP tools with direct payload fields as client MCP calls", () => {
    const normalized = normalizeSDKToolCall({
      type: "mcp",
      args: {
        providerIdentifier: "client",
        toolName: "probe_write_file",
        file_path: "marker.txt",
        contents: "ok"
      }
    });

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
    expect(isForwardableSDKToolCall(normalized)).toBe(true);
  });

  it("normalizes direct dynamic harness MCP tool events to SDK MCP calls", () => {
    const normalized = normalizeSDKToolCall({
      type: "probe_write_file",
      args: {
        file_path: "marker.txt",
        contents: "ok"
      }
    }, [
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
    expect(isForwardableSDKToolCall(normalized)).toBe(true);
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
    expect(tools.find((tool) => tool.name === "probe_write_file")).toMatchObject({
      description: "Writes a marker through the harness MCP server.",
      inputSchema: {
        additionalProperties: false,
        required: ["file_path", "contents"]
      }
    });
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

  it("tells the SDK to use client MCP tools instead of built-in local tools", () => {
    const prompt = bridgePrompt("USER: create a file");

    expect(prompt).toContain("client_shell");
    expect(prompt).toContain("Do not use the SDK built-in shell");
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
    expect(createOptions.local).not.toHaveProperty("sandboxOptions");
    expect(createOptions.local).not.toHaveProperty("settingSources");
    expect(sendOptions).toEqual({
      model: { id: "composer-2.5" }
    });
    expect(sendOptions).not.toHaveProperty("local");
  });
});
