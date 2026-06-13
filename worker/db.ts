import {
  accountIdForCursor,
  apiKeyPrefix,
  decryptText,
  encryptText,
  randomToken,
  sha256Hex,
} from "./crypto";
import type {
  AccountRow,
  ApiKeyRow,
  AuthenticatedAccount,
  CursorMe,
  Env,
} from "./types";

export interface SignupRecord {
  account: AccountRow;
  proxyApiKey: string;
}

export async function saveSignup(
  env: Env,
  cursorApiKey: string,
  me: CursorMe,
  input: { joinWaitlist: boolean },
): Promise<SignupRecord> {
  const secret = requireEncryptionSecret(env);
  const now = new Date().toISOString();
  const cursorUserId = me.userId === undefined ? null : String(me.userId);
  const cursorEmail = me.userEmail || null;
  const cursorName =
    [me.userFirstName, me.userLastName].filter(Boolean).join(" ").trim() ||
    me.apiKeyName ||
    null;
  const accountId = await accountIdForCursor(
    cursorUserId,
    cursorEmail,
    await sha256Hex(cursorApiKey),
  );
  const encrypted = await encryptText(cursorApiKey, secret);
  const hint = cursorApiKey.slice(-4);
  const account: AccountRow = {
    id: accountId,
    cursor_user_id: cursorUserId,
    cursor_email: cursorEmail,
    cursor_name: cursorName,
    cursor_api_key_ciphertext: encrypted.ciphertext,
    cursor_api_key_iv: encrypted.iv,
    cursor_api_key_hint: hint,
    waitlist_opt_in: input.joinWaitlist ? 1 : 0,
    created_at: now,
    updated_at: now,
  };

  await env.DB.prepare(
    `INSERT INTO accounts (
      id, cursor_user_id, cursor_email, cursor_name, cursor_api_key_ciphertext,
      cursor_api_key_iv, cursor_api_key_hint, waitlist_opt_in, created_at, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      cursor_user_id = excluded.cursor_user_id,
      cursor_email = excluded.cursor_email,
      cursor_name = excluded.cursor_name,
      cursor_api_key_ciphertext = excluded.cursor_api_key_ciphertext,
      cursor_api_key_iv = excluded.cursor_api_key_iv,
      cursor_api_key_hint = excluded.cursor_api_key_hint,
      waitlist_opt_in = excluded.waitlist_opt_in,
      updated_at = excluded.updated_at`,
  )
    .bind(
      account.id,
      account.cursor_user_id,
      account.cursor_email,
      account.cursor_name,
      account.cursor_api_key_ciphertext,
      account.cursor_api_key_iv,
      account.cursor_api_key_hint,
      account.waitlist_opt_in,
      account.created_at,
      account.updated_at,
    )
    .run();

  const proxyApiKey = randomToken("cmp");
  const keyHash = await sha256Hex(proxyApiKey);
  await env.DB.prepare(
    `INSERT INTO api_keys (id, account_id, prefix, key_hash, name, created_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      `key_${crypto.randomUUID()}`,
      account.id,
      apiKeyPrefix(proxyApiKey),
      keyHash,
      "default",
      now,
    )
    .run();

  return { account, proxyApiKey };
}

export async function authenticateProxyKey(
  env: Env,
  proxyApiKey: string,
): Promise<AuthenticatedAccount | null> {
  const keyHash = await sha256Hex(proxyApiKey);
  const apiKey = await env.DB.prepare(
    `SELECT * FROM api_keys WHERE key_hash = ? AND revoked_at IS NULL LIMIT 1`,
  )
    .bind(keyHash)
    .first<ApiKeyRow>();
  if (!apiKey) return null;

  const account = await env.DB.prepare(
    `SELECT * FROM accounts WHERE id = ? LIMIT 1`,
  )
    .bind(apiKey.account_id)
    .first<AccountRow>();
  if (!account) return null;

  const cursorApiKey = await decryptText(
    account.cursor_api_key_ciphertext,
    account.cursor_api_key_iv,
    requireEncryptionSecret(env),
  );
  await env.DB.prepare(`UPDATE api_keys SET last_used_at = ? WHERE id = ?`)
    .bind(new Date().toISOString(), apiKey.id)
    .run();

  return { account, apiKey, cursorApiKey };
}

export async function createRequestLog(
  env: Env,
  input: {
    accountId: string;
    endpoint: string;
    model?: string;
    status: string;
    promptChars?: number;
    completionChars?: number;
    cursorAgentId?: string;
    cursorRunId?: string;
    error?: string;
    completedAt?: string;
  },
): Promise<string> {
  const id = `req_${crypto.randomUUID()}`;
  await env.DB.prepare(
    `INSERT INTO request_logs (
      id, account_id, endpoint, model, cursor_agent_id, cursor_run_id, status,
      prompt_chars, completion_chars, error, created_at, completed_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      id,
      input.accountId,
      input.endpoint,
      input.model ?? null,
      input.cursorAgentId ?? null,
      input.cursorRunId ?? null,
      input.status,
      input.promptChars ?? 0,
      input.completionChars ?? 0,
      input.error ?? null,
      new Date().toISOString(),
      input.completedAt ?? null,
    )
    .run();
  return id;
}

export async function completeRequestLog(
  env: Env,
  id: string,
  input: {
    status: string;
    completionChars?: number;
    cursorAgentId?: string;
    cursorRunId?: string;
    error?: string;
  },
): Promise<void> {
  await env.DB.prepare(
    `UPDATE request_logs
     SET status = ?, completion_chars = ?, cursor_agent_id = COALESCE(?, cursor_agent_id),
         cursor_run_id = COALESCE(?, cursor_run_id), error = ?, completed_at = ?
     WHERE id = ?`,
  )
    .bind(
      input.status,
      input.completionChars ?? 0,
      input.cursorAgentId ?? null,
      input.cursorRunId ?? null,
      input.error ?? null,
      new Date().toISOString(),
      id,
    )
    .run();
}

function requireEncryptionSecret(env: Env): string {
  if (!env.ENCRYPTION_KEY || env.ENCRYPTION_KEY.trim().length < 16) {
    throw new Error(
      "ENCRYPTION_KEY must be configured before storing Cursor API keys",
    );
  }
  return env.ENCRYPTION_KEY;
}
