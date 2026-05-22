import { describe, expect, it } from "vitest";
import { handleRequest } from "./index";
import { FakeD1, fakeCtx } from "./test-helpers";
import type { Deps, Env } from "./types";

function makeEnv(db: FakeD1, assetsFetch: Fetcher["fetch"] = () => Promise.resolve(new Response("asset"))): Env {
  return {
    DB: db as unknown as D1Database,
    ASSETS: { fetch: assetsFetch } as unknown as Fetcher,
    ENCRYPTION_KEY: "test-encryption-secret-with-enough-entropy",
    CURSOR_API_BASE: "https://api.cursor.test",
    CURSOR_BACKEND_BASE_URL: "https://cursor-backend.test",
    CURSOR_CHAT_ENDPOINT: "/test-cursor-chat"
  };
}

describe("Worker", () => {
  it("serves current stable Vite assets for stale hashed asset URLs", async () => {
    const db = new FakeD1();
    const requested: string[] = [];
    const env = makeEnv(db, (input) => {
      const url = new URL(input instanceof Request ? input.url : input.toString());
      requested.push(url.pathname);
      if (url.pathname === "/assets/index.css") {
        return Promise.resolve(new Response("body { color: red; }", { headers: { "content-type": "text/css" } }));
      }
      return Promise.resolve(new Response(null, { status: 404 }));
    });
    const { deps } = fakeDeps();

    const response = await handleRequest(
      new Request("https://composer.test/assets/index-OLDHASH.css"),
      env,
      fakeCtx(),
      deps
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("text/css");
    await expect(response.text()).resolves.toContain("color: red");
    expect(requested).toContain("/assets/index.css");
  });

  it("signs up a Cursor API key and serves chat completions", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps } = fakeDeps();

    const signup = await handleRequest(
      new Request("https://composer.test/api/signup", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ cursorApiKey: "cursor_key", name: "Ada", email: "ada@example.com", joinWaitlist: true })
      }),
      env,
      fakeCtx(),
      deps
    );
    expect(signup.status).toBe(200);
    const signupBody = (await signup.json()) as { apiKey: string; endpoints: { chatCompletions: string } };
    expect(signupBody.apiKey).toMatch(/^cmp_/);
    expect(signupBody.endpoints.chatCompletions).toContain("/u/acct_");

    const completion = await handleRequest(
      new Request(signupBody.endpoints.chatCompletions, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${signupBody.apiKey}`
        },
        body: JSON.stringify({
          model: "composer-2.5",
          messages: [{ role: "user", content: "Say hello" }]
        })
      }),
      env,
      fakeCtx(),
      deps
    );
    expect(completion.status).toBe(200);
    await expect(completion.json()).resolves.toMatchObject({
      object: "chat.completion",
      choices: [{ message: { content: "Hello from Composer" } }]
    });
    expect([...db.requestLogs.values()].at(-1)).toMatchObject({
      status: "completed",
      completion_chars: "Hello from Composer".length
    });
  });

  it("serves bare /v1/chat/completions with a direct Cursor key and writes no request log", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps, exchangeAuthHeaders } = fakeDeps();

    const completion = await handleRequest(
      new Request("https://composer.test/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer cursor_direct_key"
        },
        body: JSON.stringify({
          model: "composer-2.5",
          messages: [{ role: "user", content: "Say hello" }]
        })
      }),
      env,
      fakeCtx(),
      deps
    );
    expect(completion.status).toBe(200);
    await expect(completion.json()).resolves.toMatchObject({
      object: "chat.completion",
      choices: [{ message: { content: "Hello from Composer" } }]
    });

    // Direct mode must not persist anything to D1.
    expect(db.requestLogs.size).toBe(0);
    expect(db.accounts.size).toBe(0);
    expect(db.apiKeys.size).toBe(0);

    // The caller's own key is forwarded only to Cursor's key-exchange endpoint.
    expect(exchangeAuthHeaders).toContain("Bearer cursor_direct_key");
  });

  it("keeps the Cursor machine identity stable across API key rotations for the same account", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps, chatRequestHeaders } = fakeDeps();

    for (const key of ["cursor_direct_key_one", "cursor_direct_key_two"]) {
      const completion = await handleRequest(
        new Request("https://composer.test/v1/chat/completions", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${key}`
          },
          body: JSON.stringify({
            model: "composer-2.5",
            messages: [{ role: "user", content: "Say hello" }]
          })
        }),
        env,
        fakeCtx(),
        deps
      );
      expect(completion.status).toBe(200);
      await completion.json();
    }

    expect(chatRequestHeaders).toHaveLength(2);
    const machineIds = chatRequestHeaders.map((headers) => headers.get("x-cursor-checksum")?.slice(-64));
    expect(machineIds[0]).toBe(machineIds[1]);
    expect(chatRequestHeaders[0].get("x-cursor-config-version")).toBe(chatRequestHeaders[1].get("x-cursor-config-version"));
  });

  it("streams SSE chat chunks in direct mode when stream is true", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps, exchangeAuthHeaders } = fakeDeps();

    const response = await handleRequest(
      new Request("https://composer.test/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer cursor_direct_key"
        },
        body: JSON.stringify({
          model: "composer-2.5",
          stream: true,
          messages: [{ role: "user", content: "Say hello" }]
        })
      }),
      env,
      fakeCtx(),
      deps
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("text/event-stream");
    const body = await response.text();
    expect(body).toContain('"object":"chat.completion.chunk"');
    expect(body).toContain('"content":"Hello from Composer"');
    expect(body).toContain('"finish_reason":"stop"');
    expect(body).toContain("data: [DONE]");

    expect(db.requestLogs.size).toBe(0);
    expect(exchangeAuthHeaders).toContain("Bearer cursor_direct_key");
  });

  it("streams Composer tool-call markers as OpenAI chat tool calls", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps } = fakeDeps();

    const response = await handleRequest(
      new Request("https://composer.test/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer cursor_direct_key"
        },
        body: JSON.stringify({
          model: "composer-2.5",
          stream: true,
          messages: [{ role: "user", content: "List files" }],
          tools: [
            {
              type: "function",
              function: {
                name: "glob",
                description: "Find files by glob",
                parameters: { type: "object", properties: { glob_pattern: { type: "string" } } }
              }
            }
          ]
        })
      }),
      env,
      fakeCtx(),
      deps
    );

    expect(response.status).toBe(200);
    const body = await response.text();
    expect(body).toContain('"content":"Checking the workspace.\\n"');
    expect(body).toContain('"tool_calls"');
    expect(body).toContain('"name":"glob"');
    expect(body).toContain('"arguments":"{\\"glob_pattern\\":\\"*\\"}"');
    expect(body).toContain('"finish_reason":"tool_calls"');
    expect(body).not.toContain("tool_calls_begin");
  });

  it("buffers Composer tool-call markers as OpenAI chat tool calls", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps } = fakeDeps();

    const response = await handleRequest(
      new Request("https://composer.test/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer cursor_direct_key"
        },
        body: JSON.stringify({
          model: "composer-2.5",
          messages: [{ role: "user", content: "List files" }],
          tools: [{ type: "function", function: { name: "glob" } }]
        })
      }),
      env,
      fakeCtx(),
      deps
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      choices: [
        {
          message: {
            content: "Checking the workspace.\n",
            tool_calls: [{ type: "function", function: { name: "glob", arguments: "{\"glob_pattern\":\"*\"}" } }]
          },
          finish_reason: "tool_calls"
        }
      ]
    });
  });

  it("serves a separate OpenCode chat route with tool calls", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps } = fakeDeps();

    const response = await handleRequest(
      new Request("https://composer.test/opencode/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer cursor_direct_key"
        },
        body: JSON.stringify({
          model: "composer-2.5",
          stream: true,
          messages: [{ role: "user", content: "List files" }],
          tools: [{ type: "function", function: { name: "glob" } }]
        })
      }),
      env,
      fakeCtx(),
      deps
    );

    expect(response.status).toBe(200);
    const body = await response.text();
    expect(body).toContain('"object":"chat.completion.chunk"');
    expect(body).toContain('"tool_calls"');
    expect(body).toContain('"name":"glob"');
    expect(body).toContain('"finish_reason":"tool_calls"');
    expect(db.requestLogs.size).toBe(0);
  });

  it("labels the OpenCode model without changing the standard model list", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps } = fakeDeps();

    const standard = await handleRequest(
      new Request("https://composer.test/v1/models", {
        headers: { Authorization: "Bearer cursor_direct_key" }
      }),
      env,
      fakeCtx(),
      deps
    );
    const opencode = await handleRequest(
      new Request("https://composer.test/opencode/v1/models", {
        headers: { Authorization: "Bearer cursor_direct_key" }
      }),
      env,
      fakeCtx(),
      deps
    );

    expect(standard.status).toBe(200);
    expect(opencode.status).toBe(200);
    const standardBody = (await standard.json()) as { data: Array<{ id: string; name: string }> };
    const opencodeBody = (await opencode.json()) as { data: Array<{ id: string; name: string }> };
    expect(standardBody.data.find((model) => model.id === "composer-2.5")?.name).toBe("Cursor Composer 2.5");
    expect(opencodeBody.data.find((model) => model.id === "composer-2.5")?.name).toBe("Composer 2.5 via Cursor API");
  });

  it("streams SSE response events in direct mode for /v1/responses", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps } = fakeDeps();

    const response = await handleRequest(
      new Request("https://composer.test/v1/responses", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer cursor_direct_key"
        },
        body: JSON.stringify({ model: "composer-2.5", stream: true, input: "Say hello" })
      }),
      env,
      fakeCtx(),
      deps
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("text/event-stream");
    const body = await response.text();
    expect(body).toContain("event: response.created");
    expect(body).toContain("event: response.output_text.delta");
    expect(body).toContain("event: response.completed");
    expect(body).toContain("Hello from Composer");
    expect(db.requestLogs.size).toBe(0);
  });

  it("returns a buffered JSON response for /v1/responses when stream is absent", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps } = fakeDeps();

    const response = await handleRequest(
      new Request("https://composer.test/v1/responses", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer cursor_direct_key"
        },
        body: JSON.stringify({ model: "composer-2.5", input: "Say hello" })
      }),
      env,
      fakeCtx(),
      deps
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("application/json");
    await expect(response.json()).resolves.toMatchObject({
      object: "response",
      output: [{ type: "message", content: [{ type: "output_text", text: "Hello from Composer" }] }]
    });
  });

  it("streams SSE chat chunks in legacy cmp_ proxy mode and still writes a request log", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps } = fakeDeps();

    const signup = await handleRequest(
      new Request("https://composer.test/api/signup", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ cursorApiKey: "cursor_key" })
      }),
      env,
      fakeCtx(),
      deps
    );
    const signupBody = (await signup.json()) as { apiKey: string; endpoints: { chatCompletions: string } };

    const response = await handleRequest(
      new Request(signupBody.endpoints.chatCompletions, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${signupBody.apiKey}`
        },
        body: JSON.stringify({
          model: "composer-2.5",
          stream: true,
          messages: [{ role: "user", content: "Say hello" }]
        })
      }),
      env,
      fakeCtx(),
      deps
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("text/event-stream");
    const body = await response.text();
    expect(body).toContain('"object":"chat.completion.chunk"');
    expect(body).toContain('"content":"Hello from Composer"');
    expect(body).toContain("data: [DONE]");

    // Proxy mode still records a request log; streaming completes it asynchronously.
    expect(db.requestLogs.size).toBe(1);
  });

  it("streams Cursor errors as SSE errors instead of assistant text", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps } = fakeDeps();

    const response = await handleRequest(
      new Request("https://composer.test/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer cursor_direct_key"
        },
        body: JSON.stringify({
          model: "composer-2.5",
          stream: true,
          messages: [{ role: "user", content: "Trigger Cursor error" }]
        })
      }),
      env,
      fakeCtx(),
      deps
    );

    expect(response.status).toBe(200);
    const body = await response.text();
    expect(body).toContain("event: error");
    expect(body).toContain("Too many computers used within the last 24 hours");
    expect(body).not.toContain("[composer-api error]");
  });

  it("requires a bearer token for /v1/models", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps } = fakeDeps();

    const noAuth = await handleRequest(
      new Request("https://composer.test/v1/models"),
      env,
      fakeCtx(),
      deps
    );
    expect(noAuth.status).toBe(401);

    const withAuth = await handleRequest(
      new Request("https://composer.test/v1/models", {
        headers: { Authorization: "Bearer cursor_direct_key" }
      }),
      env,
      fakeCtx(),
      deps
    );
    expect(withAuth.status).toBe(200);
    const body = (await withAuth.json()) as { object: string; data: Array<{ id: string }> };
    expect(body).toMatchObject({
      object: "list",
      data: expect.arrayContaining([
        expect.objectContaining({ id: "composer-2.5" }),
        expect.objectContaining({ id: "composer-2.5-fast" }),
        expect.objectContaining({ id: "gpt-5.3-codex" }),
        expect.objectContaining({ id: "gemini-3.1-pro" }),
        expect.objectContaining({ id: "default" })
      ])
    });
    expect(body.data.map((model) => model.id)).not.toContain("gpt-5.5");
  });

  it("rejects an unknown cmp_ token without forwarding it to Cursor", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps, exchangeAuthHeaders } = fakeDeps();

    const completion = await handleRequest(
      new Request("https://composer.test/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer cmp_not_a_real_key"
        },
        body: JSON.stringify({ model: "composer-2.5", messages: [{ role: "user", content: "Hi" }] })
      }),
      env,
      fakeCtx(),
      deps
    );
    expect(completion.status).toBe(401);
    // An invalid cmp_ token is never forwarded to Cursor as a Cursor key.
    expect(exchangeAuthHeaders).toHaveLength(0);
  });
});

function fakeDeps(): { deps: Deps; exchangeAuthHeaders: string[]; chatAuthHeaders: string[]; chatRequestHeaders: Headers[] } {
  const exchangeAuthHeaders: string[] = [];
  const chatAuthHeaders: string[] = [];
  const chatRequestHeaders: Headers[] = [];
  const deps: Deps = {
    now: () => new Date("2026-05-20T12:00:00.000Z"),
    randomUUID: () => "00000000-0000-4000-8000-000000000000",
    fetch: async (input, init) => {
      const url = new URL(String(input));
      const auth = new Headers(init?.headers).get("authorization") || "";
      if (url.pathname === "/v1/me") {
        return Response.json({
          apiKeyName: "Test key",
          userId: 123,
          userEmail: "ada@example.com",
          userFirstName: "Ada",
          userLastName: "Lovelace",
          createdAt: "2026-05-20T00:00:00.000Z"
        });
      }
      if (url.pathname === "/auth/exchange_user_api_key" && init?.method === "POST") {
        exchangeAuthHeaders.push(auth);
        return Response.json({ accessToken: "cursor_access_token" });
      }
      if (url.pathname === "/test-cursor-chat" && init?.method === "POST") {
        const headers = new Headers(init.headers);
        chatAuthHeaders.push(auth);
        chatRequestHeaders.push(headers);
        expect(headers.get("content-type")).toContain("application/connect+proto");
        const requestText = decodeRequestBody(init.body);
        if (requestText.includes("Trigger Cursor error")) {
          return new Response(
            new ReadableStream<Uint8Array>({
              start(controller) {
                controller.enqueue(connectFrame(cursorError("Too many computers.", "Too many computers used within the last 24 hours."), 2));
                controller.close();
              }
            }),
            { headers: { "Content-Type": "application/connect+proto" } }
          );
        }
        if (requestText.includes("List files")) {
          return new Response(
            new ReadableStream<Uint8Array>({
              start(controller) {
                controller.enqueue(
                  connectFrame(
                    chatResponseText(
                      [
                        "Checking the workspace.\n",
                        "<|tool_calls_begin|><|tool_call_begin|>\n",
                        "Glob\n",
                        "<|tool_sep|>glob_pattern\n",
                        "*\n",
                        "<|tool_call_end|><|tool_calls_end|>"
                      ].join("")
                    )
                  )
                );
                controller.enqueue(connectFrame(new TextEncoder().encode("{}"), 2));
                controller.close();
              }
            }),
            { headers: { "Content-Type": "application/connect+proto" } }
          );
        }
        expect(requestText).toContain("Say hello");
        return new Response(
          new ReadableStream<Uint8Array>({
            start(controller) {
              controller.enqueue(connectFrame(chatResponseThinking("The answer is simple.</think>\nHello from Composer")));
              controller.enqueue(connectFrame(new TextEncoder().encode("{}"), 2));
              controller.close();
            }
          }),
          { headers: { "Content-Type": "application/connect+proto" } }
        );
      }
      return new Response("not found", { status: 404 });
    }
  };
  return { deps, exchangeAuthHeaders, chatAuthHeaders, chatRequestHeaders };
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

function decodeRequestBody(body: BodyInit | null | undefined): string {
  if (body instanceof Uint8Array) return new TextDecoder().decode(body);
  if (body instanceof ArrayBuffer) return new TextDecoder().decode(body);
  if (typeof body === "string") return body;
  return "";
}

function chatResponseThinking(text: string): Uint8Array {
  return protoMessage([protoField(2, protoMessage([protoField(25, protoMessage([protoField(1, text)]))]))]);
}

function chatResponseText(text: string): Uint8Array {
  return protoMessage([protoField(2, protoMessage([protoField(1, text)]))]);
}

function connectFrame(payload: Uint8Array, flags = 0): Uint8Array {
  const frame = new Uint8Array(5 + payload.length);
  frame[0] = flags;
  new DataView(frame.buffer).setUint32(1, payload.length, false);
  frame.set(payload, 5);
  return frame;
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
