import type { Deps, Env } from "./types";

const WAITLIST_API = "https://agents.standardagentbuilder.com/api/waitlist";

export async function submitWaitlist(
  env: Env,
  deps: Deps,
  input: { name?: string; email?: string; source?: string }
): Promise<boolean> {
  const name = input.name?.trim();
  const email = input.email?.trim();
  if (!name || !email || !env.WAITLIST_API_TOKEN) return false;
  try {
    const response = await deps.fetch(WAITLIST_API, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${env.WAITLIST_API_TOKEN}`
      },
      body: JSON.stringify({
        name,
        email,
        source: input.source || env.WAITLIST_SOURCE || "composer-api"
      })
    });
    return response.ok;
  } catch {
    return false;
  }
}
