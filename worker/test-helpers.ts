import type { AccountRow, ApiKeyRow } from "./types";

export class FakeD1 {
  accounts = new Map<string, AccountRow>();
  apiKeys = new Map<string, ApiKeyRow>();
  requestLogs = new Map<string, Record<string, unknown>>();
  sdkSessions = new Map<string, Record<string, unknown>>();

  prepare(sql: string) {
    return new FakeStatement(this, sql);
  }
}

class FakeStatement {
  private values: unknown[] = [];

  constructor(
    private readonly db: FakeD1,
    private readonly sql: string,
  ) {}

  bind(...values: unknown[]) {
    this.values = values;
    return this;
  }

  async run() {
    const normalized = this.sql.replace(/\s+/g, " ").trim();
    if (normalized.startsWith("INSERT INTO accounts")) {
      const [
        id,
        cursorUserId,
        cursorEmail,
        cursorName,
        ciphertext,
        iv,
        hint,
        waitlist,
        createdAt,
        updatedAt,
      ] = this.values;
      const existing = this.db.accounts.get(String(id));
      this.db.accounts.set(String(id), {
        id: String(id),
        cursor_user_id: nullable(cursorUserId),
        cursor_email: nullable(cursorEmail),
        cursor_name: nullable(cursorName),
        cursor_api_key_ciphertext: String(ciphertext),
        cursor_api_key_iv: String(iv),
        cursor_api_key_hint: nullable(hint),
        waitlist_opt_in: Number(waitlist),
        created_at: existing?.created_at || String(createdAt),
        updated_at: String(updatedAt),
      });
    } else if (normalized.startsWith("INSERT INTO api_keys")) {
      const [id, accountId, prefix, keyHash, name, createdAt] = this.values;
      this.db.apiKeys.set(String(id), {
        id: String(id),
        account_id: String(accountId),
        prefix: String(prefix),
        key_hash: String(keyHash),
        name: String(name),
        created_at: String(createdAt),
        last_used_at: null,
        revoked_at: null,
      });
    } else if (normalized.startsWith("UPDATE api_keys SET last_used_at")) {
      const [lastUsedAt, id] = this.values;
      const row = this.db.apiKeys.get(String(id));
      if (row) row.last_used_at = String(lastUsedAt);
    } else if (normalized.startsWith("INSERT INTO request_logs")) {
      const [
        id,
        accountId,
        endpoint,
        model,
        cursorAgentId,
        cursorRunId,
        status,
        promptChars,
        completionChars,
        error,
        createdAt,
        completedAt,
      ] = this.values;
      this.db.requestLogs.set(String(id), {
        id,
        account_id: accountId,
        endpoint,
        model,
        cursor_agent_id: cursorAgentId,
        cursor_run_id: cursorRunId,
        status,
        prompt_chars: promptChars,
        completion_chars: completionChars,
        error,
        created_at: createdAt,
        completed_at: completedAt,
      });
    } else if (normalized.startsWith("UPDATE request_logs")) {
      const [
        status,
        completionChars,
        cursorAgentId,
        cursorRunId,
        error,
        completedAt,
        id,
      ] = this.values;
      const row = this.db.requestLogs.get(String(id));
      if (row) {
        row.status = status;
        row.completion_chars = completionChars;
        row.cursor_agent_id = cursorAgentId || row.cursor_agent_id;
        row.cursor_run_id = cursorRunId || row.cursor_run_id;
        row.error = error;
        row.completed_at = completedAt;
      }
    } else if (normalized.startsWith("INSERT INTO sdk_sessions")) {
      const [id, ownerHash, sessionHash, agentId, createdAt, updatedAt] =
        this.values;
      const existing = this.db.sdkSessions.get(String(id));
      this.db.sdkSessions.set(String(id), {
        id,
        owner_hash: ownerHash,
        session_hash: sessionHash,
        agent_id: agentId,
        created_at: existing?.created_at || createdAt,
        updated_at: updatedAt,
      });
    } else if (normalized.startsWith("DELETE FROM sdk_sessions")) {
      const [id] = this.values;
      this.db.sdkSessions.delete(String(id));
    }
    return { success: true };
  }

  async first<T>() {
    const normalized = this.sql.replace(/\s+/g, " ").trim();
    if (normalized.startsWith("SELECT * FROM api_keys WHERE key_hash")) {
      const [keyHash] = this.values;
      return ([...this.db.apiKeys.values()].find(
        (row) => row.key_hash === keyHash && !row.revoked_at,
      ) || null) as T | null;
    }
    if (normalized.startsWith("SELECT * FROM accounts WHERE id")) {
      const [id] = this.values;
      return (this.db.accounts.get(String(id)) || null) as T | null;
    }
    if (
      normalized.startsWith("SELECT agent_id, updated_at FROM sdk_sessions")
    ) {
      const [id] = this.values;
      return (this.db.sdkSessions.get(String(id)) || null) as T | null;
    }
    return null;
  }
}

function nullable(value: unknown): string | null {
  return value === null || value === undefined ? null : String(value);
}

export function fakeCtx(): ExecutionContext {
  return {
    waitUntil(promise: Promise<unknown>) {
      void promise.catch(() => undefined);
    },
    passThroughOnException() {
      return undefined;
    },
    props: {},
  } as ExecutionContext;
}
