import { describe, expect, it } from "vitest";
import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

import {
  createCredentialCipher,
  credentialAad,
  CredentialOpenError,
  CredentialSealError,
  deriveWorkspaceDek,
  InvalidCredentialKeyError,
  secretsEqual,
  type CredentialIdentity,
} from "../src/crypto/credential-cipher.js";

/**
 * The seal that makes per-workspace credentials real (charter D35).
 *
 * The bar these tests hold the cipher to is NOT "it round-trips" — @chat-adapter/
 * shared's encryptToken round-trips too, and it is unsafe here precisely because
 * it never calls setAAD: a blob minted for tenant A decrypts cleanly in tenant B's
 * row. So the load-bearing assertions below are the NEGATIVE ones: change any part
 * of the row identity and the blob must FAIL CLOSED.
 */

const KEY_A = randomBytes(32).toString("base64");
const KEY_B = randomBytes(32).toString("base64");

const WS_ALPHA = "11111111-1111-4111-8111-111111111111";
const WS_BETA = "22222222-2222-4222-8222-222222222222";

const alpha: CredentialIdentity = {
  provider: "telegram",
  installKey: "bot-alpha",
  workspaceId: WS_ALPHA,
};

const beta: CredentialIdentity = {
  provider: "telegram",
  installKey: "bot-beta",
  workspaceId: WS_BETA,
};

const cipher = createCredentialCipher({ key: KEY_A });

describe("credential cipher — round trip", () => {
  it("opens what it sealed, for the same row identity", () => {
    const sealed = cipher.seal("123456789:AA-secret", alpha);

    expect(cipher.open(sealed, alpha)).toBe("123456789:AA-secret");
  });

  it("never stores the plaintext in the blob", () => {
    const sealed = cipher.seal("bp_chat_token_alpha", alpha);

    // The obvious failure mode of a "cipher" that is really base64.
    expect(sealed).not.toContain("bp_chat_token_alpha");
    expect(Buffer.from(sealed, "base64").toString("utf8")).not.toContain(
      "bp_chat_token_alpha",
    );
  });

  it("seals the same secret to different bytes each time (fresh IV, no equality leak)", () => {
    const first = cipher.seal("same-secret", alpha);
    const second = cipher.seal("same-secret", alpha);

    // Equal ciphertexts would let anyone with read access see that two tenants
    // share a token — without decrypting anything.
    expect(first).not.toBe(second);
    expect(cipher.open(first, alpha)).toBe("same-secret");
    expect(cipher.open(second, alpha)).toBe("same-secret");
  });

  it("survives unicode and long secrets verbatim", () => {
    const secret = `🔐 ${"x".repeat(4096)} slutt`;
    expect(cipher.open(cipher.seal(secret, alpha), alpha)).toBe(secret);
  });
});

describe("credential cipher — wire format (the LocalKek envelope layout)", () => {
  it("is Base64(iv(12) || tag(16) || ciphertext), sealed under the workspace DEK", () => {
    const plaintext = "the-secret";
    const sealed = cipher.seal(plaintext, alpha);
    const raw = Buffer.from(sealed, "base64");

    // 12 + 16 + len(plaintext): GCM is a stream cipher, so ct is the same length
    // as the plaintext. The envelope LAYOUT is LocalKek's, byte for byte.
    expect(raw.length).toBe(12 + 16 + Buffer.byteLength(plaintext, "utf8"));

    // Decrypt by hand, splitting exactly as api/lib/barkpark/crypto/local_kek.ex
    // does (<<iv::binary-size(12), tag::binary-size(16), ct::binary>>). If the
    // order of iv and tag ever flips, this is what catches it. What DIFFERS from
    // LocalKek: the key is the PER-WORKSPACE DEK, not the instance key straight,
    // and the AAD carries the v2 version prefix.
    const iv = raw.subarray(0, 12);
    const tag = raw.subarray(12, 28);
    const ct = raw.subarray(28);

    const dek = deriveWorkspaceDek(Buffer.from(KEY_A, "base64"), WS_ALPHA);
    const decipher = createDecipheriv("aes-256-gcm", dek, iv);
    decipher.setAAD(credentialAad(alpha)); // defaults to v2, the seal scheme
    decipher.setAuthTag(tag);
    const out = Buffer.concat([decipher.update(ct), decipher.final()]).toString(
      "utf8",
    );

    expect(out).toBe(plaintext);
  });

  it("binds the AAD to the FULL row identity, v2 version prefix included", () => {
    expect(credentialAad(alpha).toString("utf8")).toBe(
      'bpc2|["telegram","bot-alpha","11111111-1111-4111-8111-111111111111"]',
    );
    // The version tag is IN the AAD (authenticated by the GCM tag), never a
    // physical column — v1 and v2 differ only by prefix.
    expect(credentialAad(alpha, 1).toString("utf8")).toBe(
      'bpc1|["telegram","bot-alpha","11111111-1111-4111-8111-111111111111"]',
    );

    // JSON-encoded, so no separator can be smuggled: these two identities differ.
    const sneaky: CredentialIdentity = {
      provider: "telegram",
      installKey: 'bot-alpha","11111111-1111-4111-8111-111111111111',
      workspaceId: "",
    };
    expect(credentialAad(sneaky).toString("utf8")).not.toBe(
      credentialAad(alpha).toString("utf8"),
    );
  });
});

/**
 * PER-WORKSPACE DEK (V2). The AAD already fails a cross-tenant paste closed; the
 * DEK removes the ONE service-wide key that sat under every tenant, so these
 * assertions are about the KEY itself, independent of the AAD binding.
 */
describe("credential cipher — per-workspace DEK isolation", () => {
  it("derives a DIFFERENT key per workspace from the same instance KEK", () => {
    const kek = Buffer.from(KEY_A, "base64");
    const dekAlpha = deriveWorkspaceDek(kek, WS_ALPHA);
    const dekBeta = deriveWorkspaceDek(kek, WS_BETA);

    expect(dekAlpha.length).toBe(32);
    expect(dekBeta.length).toBe(32);
    // Two workspaces, one instance key, two DISTINCT data-encryption keys.
    expect(dekAlpha.equals(dekBeta)).toBe(false);
    // And neither is the instance key itself — the KEK never encrypts a row.
    expect(dekAlpha.equals(kek)).toBe(false);
    // Deterministic: the same (KEK, workspace) always derives the same DEK, or
    // a sealed row could never be re-opened.
    expect(deriveWorkspaceDek(kek, WS_ALPHA).equals(dekAlpha)).toBe(true);
  });

  it("workspace A's DEK cannot open a blob sealed for workspace B", () => {
    // Seal for beta (workspace B). Then try to decrypt the raw bytes with A's
    // DEK — GCM must reject it, even though we hand it B's AAD, because the KEY
    // is wrong. This is the property the AAD alone did not give: key isolation.
    const sealedForBeta = cipher.seal("beta-bot-token", beta);
    const raw = Buffer.from(sealedForBeta, "base64");
    const iv = raw.subarray(0, 12);
    const tag = raw.subarray(12, 28);
    const ct = raw.subarray(28);

    const dekAlpha = deriveWorkspaceDek(Buffer.from(KEY_A, "base64"), WS_ALPHA);
    const decipher = createDecipheriv("aes-256-gcm", dekAlpha, iv);
    decipher.setAAD(credentialAad(beta)); // B's own AAD — only the KEY is A's
    decipher.setAuthTag(tag);
    expect(() => Buffer.concat([decipher.update(ct), decipher.final()])).toThrow();

    // And B's own DEK opens it, so the failure above is the key, not the bytes.
    const dekBeta = deriveWorkspaceDek(Buffer.from(KEY_A, "base64"), WS_BETA);
    const good = createDecipheriv("aes-256-gcm", dekBeta, iv);
    good.setAAD(credentialAad(beta));
    good.setAuthTag(tag);
    expect(Buffer.concat([good.update(ct), good.final()]).toString("utf8")).toBe(
      "beta-bot-token",
    );
  });

  it("a v2 blob is reported current; a v1 (pre-DEK) blob is not, yet still opens", () => {
    // Seal a legacy v1 blob by hand: instance KEY straight (no DEK), v1 AAD.
    const kek = Buffer.from(KEY_A, "base64");
    const iv = randomBytes(12);
    const enc = createCipheriv("aes-256-gcm", kek, iv);
    enc.setAAD(credentialAad(alpha, 1));
    const body = Buffer.concat([enc.update("v1-secret", "utf8"), enc.final()]);
    const legacyBlob = Buffer.concat([iv, enc.getAuthTag(), body]).toString(
      "base64",
    );

    // It still OPENS (rotation-safe, so no flag day) but is NOT current — the
    // sweep must rewrap it. This is exactly the old-key-drain condition.
    expect(cipher.open(legacyBlob, alpha)).toBe("v1-secret");
    expect(cipher.isSealedWithCurrentKey(legacyBlob, alpha)).toBe(false);

    // A freshly-sealed (v2) blob is current.
    const v2 = cipher.seal("v2-secret", alpha);
    expect(cipher.isSealedWithCurrentKey(v2, alpha)).toBe(true);

    // Under a DIFFERENT current key it is no longer current (needs rewrap) but
    // still opens via the previous key — the whole point of the sweep.
    const rotated = createCredentialCipher({ key: KEY_B, previousKeys: [KEY_A] });
    expect(rotated.isSealedWithCurrentKey(v2, alpha)).toBe(false);
    expect(rotated.open(v2, alpha)).toBe("v2-secret");
  });
});

/**
 * THE POINT OF THE MODULE. Each of these is a way a sealed blob could be moved
 * between tenants — by a bad migration, a compromised install path, or a hostile
 * write. Every one of them must fail CLOSED.
 */
describe("credential cipher — AAD binding (the cross-tenant seal)", () => {
  it("REFUSES to open tenant A's blob under tenant B's identity", () => {
    const sealed = cipher.seal("alpha-bot-token", alpha);

    // This is the exact attack @chat-adapter/shared's encryptToken permits: paste
    // A's ciphertext into B's row and read it back. Here it throws.
    expect(() => cipher.open(sealed, beta)).toThrow(CredentialOpenError);
    expect(cipher.opens(sealed, beta)).toBe(false);
    expect(cipher.opens(sealed, alpha)).toBe(true);
  });

  it("REFUSES to open when ONLY workspace_id is flipped (the PK stays intact)", () => {
    // The whole reason workspace_id is in the AAD. (provider, install_key) is the
    // PRIMARY KEY — an attacker who repoints a row at their own workspace leaves
    // the PK untouched. Seal on the PK alone and the row would still open, and the
    // victim's token would now serve the attacker's tenant.
    const sealed = cipher.seal("alpha-bot-token", alpha);
    const stolen: CredentialIdentity = { ...alpha, workspaceId: WS_BETA };

    expect(() => cipher.open(sealed, stolen)).toThrow(CredentialOpenError);
  });

  it("REFUSES to open when only the provider is changed", () => {
    const sealed = cipher.seal("alpha-bot-token", alpha);
    expect(() => cipher.open(sealed, { ...alpha, provider: "slack" })).toThrow(
      CredentialOpenError,
    );
  });

  it("REFUSES to open when only the install key is changed", () => {
    const sealed = cipher.seal("alpha-bot-token", alpha);
    expect(() => cipher.open(sealed, { ...alpha, installKey: "bot-zzz" })).toThrow(
      CredentialOpenError,
    );
  });

  it("names the row it failed on, and never leaks the blob", () => {
    const sealed = cipher.seal("alpha-bot-token", alpha);
    const err = (() => {
      try {
        cipher.open(sealed, beta);
        return null;
      } catch (e) {
        return e as CredentialOpenError;
      }
    })();

    expect(err).toBeInstanceOf(CredentialOpenError);
    expect(err?.message).toContain("bot-beta");
    expect(err?.message).toContain(WS_BETA);
    // An error message is a log line. It must not carry the ciphertext.
    expect(err?.message).not.toContain(sealed);
  });
});

describe("credential cipher — tamper and corruption", () => {
  it("REFUSES a flipped ciphertext byte (GCM tag fails)", () => {
    const sealed = cipher.seal("alpha-bot-token", alpha);
    const raw = Buffer.from(sealed, "base64");
    raw.writeUInt8(raw.readUInt8(raw.length - 1) ^ 0xff, raw.length - 1);

    expect(() => cipher.open(raw.toString("base64"), alpha)).toThrow(
      CredentialOpenError,
    );
  });

  it("REFUSES a flipped auth tag", () => {
    const sealed = cipher.seal("alpha-bot-token", alpha);
    const raw = Buffer.from(sealed, "base64");
    raw.writeUInt8(raw.readUInt8(15) ^ 0x01, 15); // inside the 12..28 tag window

    expect(() => cipher.open(raw.toString("base64"), alpha)).toThrow(
      CredentialOpenError,
    );
  });

  it("REFUSES a truncated blob", () => {
    const sealed = cipher.seal("alpha-bot-token", alpha);
    const raw = Buffer.from(sealed, "base64").subarray(0, 20);

    expect(() => cipher.open(raw.toString("base64"), alpha)).toThrow(/truncated/);
  });

  it("REFUSES a plaintext value sitting in the column (a pre-D35 row)", () => {
    // A row written by the P2 code holds the raw bot token. It must not be
    // mistaken for a sealed one, and it must never be handed back as plaintext.
    expect(() => cipher.open("123456789:AAHfake-plaintext-token", alpha)).toThrow(
      CredentialOpenError,
    );
  });

  it("REFUSES a blob sealed under a DIFFERENT key", () => {
    const other = createCredentialCipher({ key: KEY_B });
    const sealed = other.seal("alpha-bot-token", alpha);

    expect(() => cipher.open(sealed, alpha)).toThrow(CredentialOpenError);
  });
});

describe("credential cipher — key handling (no plaintext fallback, ever)", () => {
  it("rejects a key that is not 32 bytes", () => {
    expect(() =>
      createCredentialCipher({ key: randomBytes(16).toString("base64") }),
    ).toThrow(InvalidCredentialKeyError);
  });

  it("rejects an empty key at construction — i.e. at BOOT, not mid-turn", () => {
    expect(() => createCredentialCipher({ key: "" })).toThrow(
      InvalidCredentialKeyError,
    );
    expect(() => createCredentialCipher({ key: "   " })).toThrow(
      InvalidCredentialKeyError,
    );
  });

  it("rejects a malformed previous key just as hard as the current one", () => {
    expect(() =>
      createCredentialCipher({ key: KEY_A, previousKeys: ["not-a-key"] }),
    ).toThrow(InvalidCredentialKeyError);
  });

  it("refuses to seal an empty secret (absence is NULL, not a seal of nothing)", () => {
    expect(() => cipher.seal("", alpha)).toThrow(CredentialSealError);
  });

  it("refuses to seal against an incomplete row identity", () => {
    expect(() => cipher.seal("x", { ...alpha, workspaceId: "" })).toThrow(
      CredentialSealError,
    );
    expect(() => cipher.seal("x", { ...alpha, installKey: "" })).toThrow(
      CredentialSealError,
    );
  });
});

describe("credential cipher — rotation (CONNECTORS_CREDENTIAL_KEY_PREVIOUS)", () => {
  it("opens a blob sealed under the PREVIOUS key, and re-seals under the current one", () => {
    const oldCipher = createCredentialCipher({ key: KEY_B });
    const legacy = oldCipher.seal("alpha-bot-token", alpha);

    const rotated = createCredentialCipher({
      key: KEY_A,
      previousKeys: [KEY_B],
    });

    // The rotation window: old rows still open…
    expect(rotated.open(legacy, alpha)).toBe("alpha-bot-token");

    // …and anything it seals is sealed under the CURRENT key, so the window
    // drains as rows are rewritten rather than living forever.
    const resealed = rotated.seal("alpha-bot-token", alpha);
    expect(createCredentialCipher({ key: KEY_A }).open(resealed, alpha)).toBe(
      "alpha-bot-token",
    );
    expect(() => oldCipher.open(resealed, alpha)).toThrow(CredentialOpenError);
  });

  it("the previous key does NOT weaken the AAD binding", () => {
    const oldCipher = createCredentialCipher({ key: KEY_B });
    const legacy = oldCipher.seal("alpha-bot-token", alpha);

    const rotated = createCredentialCipher({
      key: KEY_A,
      previousKeys: [KEY_B],
    });

    // A rotation must not become a hole: the old key opens the blob only for the
    // row it was sealed for.
    expect(() => rotated.open(legacy, beta)).toThrow(CredentialOpenError);
  });
});

describe("secretsEqual", () => {
  it("compares equal secrets true and different secrets false", () => {
    expect(secretsEqual("abc", "abc")).toBe(true);
    expect(secretsEqual("abc", "abd")).toBe(false);
    expect(secretsEqual("abc", "abcd")).toBe(false);
    expect(secretsEqual("", "")).toBe(true);
  });
});
