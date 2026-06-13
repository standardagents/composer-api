export interface Env {
  ASSETS: Fetcher;
  DB: D1Database;
  RELEASES?: R2Bucket;
  CURSOR_SDK_BRIDGE_CONTAINER?: DurableObjectNamespace;
  ENCRYPTION_KEY?: string;
  CURSOR_API_BASE?: string;
  CURSOR_BACKEND_BASE_URL?: string;
  CURSOR_CHAT_ENDPOINT?: string;
  CURSOR_CLIENT_VERSION?: string;
  CURSOR_LOCAL_AGENT_ENDPOINT?: string;
  CURSOR_SDK_BRIDGE_TOKEN?: string;
  CURSOR_SDK_BRIDGE_TIMEOUT_MS?: string;
  CURSOR_SDK_BRIDGE_URL?: string;
  CURSOR_SDK_CLIENT_VERSION?: string;
  GITHUB_RELEASE_DISPATCH_TOKEN?: string;
  GITHUB_RELEASE_REPOSITORY?: string;
  NOTARY_WEBHOOK_TOKEN?: string;
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
  | {
      url: string;
      dimension?: { width: number; height: number };
      uuid?: string;
    }
  | {
      data: string;
      mimeType: string;
      dimension?: { width: number; height: number };
      uuid?: string;
    };

export interface CursorPrompt {
  text: string;
  images?: CursorImage[];
  mode?: "ask" | "agent";
}

export interface CursorToolCall {
  name: string;
  arguments: Record<string, unknown>;
}

export interface CursorCompletion {
  requestId: string;
  conversationId: string;
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
