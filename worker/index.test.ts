import { describe, expect, it } from "vitest";
import { handleRequest } from "./index";
import { encodeSse } from "./sse";
import { FakeD1, fakeCtx } from "./test-helpers";
import type { Deps, Env } from "./types";

describe("Worker", () => {
  it("signs up a Cursor API key and serves chat completions", async () => {
    const db = new FakeD1();
    const env: Env = {
      DB: db as unknown as D1Database,
      ASSETS: { fetch: () => Promise.resolve(new Response("asset")) } as unknown as Fetcher,
      ENCRYPTION_KEY: "test-encryption-secret-with-enough-entropy",
      CURSOR_API_BASE: "https://api.cursor.test"
    };
    const deps = fakeDeps();

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
});

function fakeDeps(): Deps {
  return {
    now: () => new Date("2026-05-20T12:00:00.000Z"),
    randomUUID: () => "00000000-0000-4000-8000-000000000000",
    fetch: async (input, init) => {
      const url = new URL(String(input));
      if (url.pathname === "/v1/me") {
        expect(init?.headers).toBeTruthy();
        return Response.json({
          apiKeyName: "Test key",
          userId: 123,
          userEmail: "ada@example.com",
          userFirstName: "Ada",
          userLastName: "Lovelace",
          createdAt: "2026-05-20T00:00:00.000Z"
        });
      }
      if (url.pathname === "/v1/agents" && init?.method === "POST") {
        const body = JSON.parse(String(init.body || "{}")) as { prompt?: { text?: string }; model?: { id?: string } };
        expect(body.prompt?.text).toContain("Say hello");
        expect(body.model?.id).toBe("composer-latest");
        return Response.json({
          agent: { id: "bc-00000000-0000-4000-8000-000000000000", latestRunId: "run-00000000-0000-4000-8000-000000000000" },
          run: { id: "run-00000000-0000-4000-8000-000000000000", status: "RUNNING" }
        });
      }
      if (url.pathname.endsWith("/stream")) {
        return new Response(
          new ReadableStream<Uint8Array>({
            start(controller) {
              controller.enqueue(encodeSse({ type: "text-delta", text: "Hello from Composer" }, "interaction_update"));
              controller.enqueue(encodeSse({ status: "FINISHED", result: "Hello from Composer" }, "result"));
              controller.close();
            }
          }),
          { headers: { "Content-Type": "text/event-stream" } }
        );
      }
      return new Response("not found", { status: 404 });
    }
  };
}
