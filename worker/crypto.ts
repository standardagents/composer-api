const encoder = new TextEncoder();
const decoder = new TextDecoder();

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function accountIdForCursor(userId: string | null, email: string | null, fallback: string): Promise<string> {
  const basis = userId ? `cursor-user:${userId}` : email ? `cursor-email:${email.toLowerCase()}` : `cursor-key:${fallback}`;
  return `acct_${(await sha256Hex(basis)).slice(0, 24)}`;
}

export function randomToken(prefix: string, bytes = 32): string {
  const values = new Uint8Array(bytes);
  crypto.getRandomValues(values);
  return `${prefix}_${base64UrlEncode(values)}`;
}

export function apiKeyPrefix(apiKey: string): string {
  return apiKey.slice(0, 14);
}

export async function encryptText(plaintext: string, secret: string): Promise<{ ciphertext: string; iv: string }> {
  const key = await importAesKey(secret);
  const iv = new Uint8Array(12);
  crypto.getRandomValues(iv);
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: toArrayBuffer(iv) },
    key,
    toArrayBuffer(encoder.encode(plaintext))
  );
  return {
    ciphertext: base64Encode(new Uint8Array(ciphertext)),
    iv: base64Encode(iv)
  };
}

export async function decryptText(ciphertext: string, iv: string, secret: string): Promise<string> {
  const key = await importAesKey(secret);
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: toArrayBuffer(base64Decode(iv)) },
    key,
    toArrayBuffer(base64Decode(ciphertext))
  );
  return decoder.decode(plaintext);
}

async function importAesKey(secret: string): Promise<CryptoKey> {
  const bytes = await normalizeKeyBytes(secret);
  return crypto.subtle.importKey("raw", toArrayBuffer(bytes), { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

async function normalizeKeyBytes(secret: string): Promise<Uint8Array> {
  const trimmed = secret.trim();
  if (/^[0-9a-f]{64}$/i.test(trimmed)) {
    return new Uint8Array(trimmed.match(/.{1,2}/g)?.map((part) => Number.parseInt(part, 16)) || []);
  }
  try {
    const decoded = base64Decode(trimmed);
    if (decoded.byteLength === 32) return decoded;
  } catch {
    // Fall through to hash derivation.
  }
  return new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(trimmed)));
}

function base64UrlEncode(bytes: Uint8Array): string {
  return base64Encode(bytes).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function base64Encode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function base64Decode(value: string): Uint8Array {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}
