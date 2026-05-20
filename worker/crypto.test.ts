import { describe, expect, it } from "vitest";
import { decryptText, encryptText, randomToken, sha256Hex } from "./crypto";

describe("crypto helpers", () => {
  it("hashes deterministically", async () => {
    await expect(sha256Hex("cmp_test")).resolves.toBe(await sha256Hex("cmp_test"));
    expect(await sha256Hex("cmp_test")).toHaveLength(64);
  });

  it("encrypts and decrypts Cursor API keys", async () => {
    const secret = "test-encryption-secret-with-enough-entropy";
    const encrypted = await encryptText("cursor_key_123", secret);
    expect(encrypted.ciphertext).not.toContain("cursor_key_123");
    await expect(decryptText(encrypted.ciphertext, encrypted.iv, secret)).resolves.toBe("cursor_key_123");
  });

  it("generates proxy keys with the expected prefix", () => {
    expect(randomToken("cmp")).toMatch(/^cmp_[A-Za-z0-9_-]+$/);
  });
});
