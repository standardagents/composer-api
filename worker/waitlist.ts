import type { Deps, Env } from "./types";

const WAITLIST_API = "https://agents.standardagentbuilder.com/api/waitlist";
const WAITLIST_FALLBACK_API =
  "https://token-costs.standardagents.ai/api/early-access";

export async function submitWaitlist(
  env: Env,
  deps: Deps,
  input: { name?: string; email?: string; source?: string },
): Promise<boolean> {
  const name = input.name?.trim();
  const email = input.email?.trim();
  if (!name || !email) return false;
  try {
    if (!env.WAITLIST_API_TOKEN) {
      const fallback = await deps.fetch(WAITLIST_FALLBACK_API, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name, email }),
      });
      return fallback.ok;
    }
    const response = await deps.fetch(WAITLIST_API, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${env.WAITLIST_API_TOKEN}`,
      },
      body: JSON.stringify({
        name,
        email,
        source: input.source || env.WAITLIST_SOURCE || "cursor-api",
      }),
    });
    return response.ok;
  } catch {
    return false;
  }
}
