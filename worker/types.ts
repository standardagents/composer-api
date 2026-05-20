export interface Env {
  ASSETS: Fetcher;
  DB: D1Database;
  ENCRYPTION_KEY?: string;
  CURSOR_API_BASE?: string;
  WAITLIST_API_TOKEN?: string;
  WAITLIST_SOURCE?: string;
}

export interface Deps {
  fetch: typeof fetch;
  now: () => Date;
  randomUUID: () => `${string}-${string}-${string}-${string}-${string}`;
}

export interface CursorMe {
  apiKeyName: string;
  userId?: number;
  userEmail?: string;
  userFirstName?: string;
  userLastName?: string;
  createdAt: string;
}

export interface AccountRow {
  id: string;
  cursor_user_id: string | null;
  cursor_email: string | null;
  cursor_name: string | null;
  cursor_api_key_ciphertext: string;
  cursor_api_key_iv: string;
  cursor_api_key_hint: string | null;
  waitlist_opt_in: number;
  created_at: string;
  updated_at: string;
}

export interface ApiKeyRow {
  id: string;
  account_id: string;
  prefix: string;
  key_hash: string;
  name: string;
  created_at: string;
  last_used_at: string | null;
  revoked_at: string | null;
}

export interface AuthenticatedAccount {
  account: AccountRow;
  apiKey: ApiKeyRow;
  cursorApiKey: string;
}

export type CursorImage =
  | { url: string; dimension?: { width: number; height: number } }
  | { data: string; mimeType: string; dimension?: { width: number; height: number } };

export interface CursorPrompt {
  text: string;
  images?: CursorImage[];
}

export interface CursorRun {
  agentId: string;
  runId: string;
  stream: Response;
}

export interface CompletionResult {
  id: string;
  model: string;
  created: number;
  text: string;
  promptChars: number;
  completionChars: number;
  cursorAgentId?: string;
  cursorRunId?: string;
}
