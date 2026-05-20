CREATE TABLE IF NOT EXISTS accounts (
  id TEXT PRIMARY KEY,
  cursor_user_id TEXT,
  cursor_email TEXT,
  cursor_name TEXT,
  cursor_api_key_ciphertext TEXT NOT NULL,
  cursor_api_key_iv TEXT NOT NULL,
  cursor_api_key_hint TEXT,
  waitlist_opt_in INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_cursor_user_id
ON accounts(cursor_user_id)
WHERE cursor_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_accounts_cursor_email
ON accounts(cursor_email);

CREATE TABLE IF NOT EXISTS api_keys (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  prefix TEXT NOT NULL,
  key_hash TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_used_at TEXT,
  revoked_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_api_keys_account_id
ON api_keys(account_id);

CREATE TABLE IF NOT EXISTS request_logs (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  endpoint TEXT NOT NULL,
  model TEXT,
  cursor_agent_id TEXT,
  cursor_run_id TEXT,
  status TEXT NOT NULL,
  prompt_chars INTEGER NOT NULL DEFAULT 0,
  completion_chars INTEGER NOT NULL DEFAULT 0,
  error TEXT,
  created_at TEXT NOT NULL,
  completed_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_request_logs_account_created
ON request_logs(account_id, created_at DESC);
