/**
 * Credential sealing for `chat_bridge.connector_installs` (charter D1/D35).
 *
 * Two secrets per install row, and BOTH are sealed at rest:
 *
 *   credential_ref   the provider secret (a Telegram BotFather token, a Slack
 *                    bot token, a Discord bot token …)
 *   chat_token_ref   THAT workspace's Barkpark `chat`-permission ApiToken — the
 *                    bearer the bridge presents to /v1/chat for this tenant
 *
 * ## Why not `@chat-adapter/shared`'s `encryptToken`
 *
 * It is AES-256-GCM too, and it is NOT good enough here: it never calls
 * `setAAD`. GCM without associated data authenticates only the BYTES, never
 * WHERE they were stored — so a ciphertext minted for tenant A decrypts cleanly
 * when pasted into tenant B's row. Anyone who can write a row (the future OAuth
 * install path, a compromised Studio action, a bad migration) could then move a
 * sealed blob across tenants and the cipher would happily hand back the
 * plaintext. Binding the ciphertext to its ROW IDENTITY is the whole point of
 * this module.
 *
 * ## AAD — the row identity, not the primary key
 *
 *     AAD = "bpc1|" + JSON.stringify([provider, install_key, workspace_id])
 *
 * `workspace_id` is IN the AAD even though it is not in the primary key. The PK
 * alone is insufficient: `(provider, install_key)` stays intact while an attacker
 * flips `workspace_id` to their own workspace — the row would still open, and the
 * victim's sealed token would now serve the attacker's tenant. With `workspace_id`
 * in the AAD, that flip makes the row un-openable: GCM fails closed, the install
 * is dropped, and no plaintext is ever produced. JSON-encoding the triple means
 * there is no delimiter to smuggle (`["a","b|c"]` ≠ `["a|b","c"]`).
 *
 * ## Wire format — byte-identical to `api/lib/barkpark/crypto/local_kek.ex`
 *
 *     Base64( iv(12) ‖ tag(16) ‖ ciphertext )
 *
 * Same layout as the BEAM side on purpose: one wire format across the codebase,
 * so a blob is legible from either language and a future move of this table into
 * Ecto needs no re-encryption.
 *
 * ## Keys
 *
 * `CONNECTORS_CREDENTIAL_KEY` is an INDEPENDENT key (base64, 32 bytes) — not
 * `BARKPARK_KEK`, not the API token. Missing key = BOOT FAILURE (see config.ts's
 * `required()`); there is deliberately NO plaintext fallback path in this module,
 * because a fallback is how "encrypted at rest" quietly becomes "sometimes".
 * `CONNECTORS_CREDENTIAL_KEY_PREVIOUS` is tried only AFTER the current key fails,
 * so a key rotation can re-seal rows without a flag day.
 *
 * Zero new dependencies: `node:crypto` only.
 */
import {
  createCipheriv,
  createDecipheriv,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";

const ALGORITHM = "aes-256-gcm";
const KEY_BYTES = 32;
const IV_BYTES = 12;
const TAG_BYTES = 16;

/** Version tag on the AAD. Bump only for a genuine format break. */
const AAD_PREFIX = "bpc1|";

/** The row identity a sealed blob is bound to. All three fields are load-bearing. */
export interface CredentialIdentity {
  provider: string;
  installKey: string;
  workspaceId: string;
}

/** Base class so a caller can catch every cipher failure with one `instanceof`. */
export class CredentialCipherError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CredentialCipherError";
  }
}

/** The configured key is missing, malformed, or the wrong length. Boot-fatal. */
export class InvalidCredentialKeyError extends CredentialCipherError {
  constructor(reason: string) {
    super(
      `connectors: CONNECTORS_CREDENTIAL_KEY is unusable — ${reason}. ` +
        "Generate one with: openssl rand -base64 32",
    );
    this.name = "InvalidCredentialKeyError";
  }
}

/** Refused to seal. Sealing nothing produces a blob that looks provisioned. */
export class CredentialSealError extends CredentialCipherError {
  constructor(message: string) {
    super(`connectors: refusing to seal — ${message}`);
    this.name = "CredentialSealError";
  }
}

/**
 * The blob did not open under ANY configured key with THIS row's identity.
 *
 * Tamper, truncation, a wrong key, or — the one that matters — a ciphertext
 * sealed for a DIFFERENT (provider, install_key, workspace_id). Fail closed:
 * this throws, and no partial plaintext ever escapes. The message deliberately
 * carries the identity but never a byte of the blob.
 */
export class CredentialOpenError extends CredentialCipherError {
  readonly identity: CredentialIdentity;

  constructor(identity: CredentialIdentity, reason: string) {
    super(
      `connectors: sealed credential did not open for ` +
        `provider=${identity.provider} install=${identity.installKey} ` +
        `workspace=${identity.workspaceId} — ${reason}`,
    );
    this.name = "CredentialOpenError";
    this.identity = identity;
  }
}

/**
 * The associated data a blob is bound to.
 *
 * Exported because the negative tests assert on it directly: the AAD is the
 * security boundary, so it is worth being able to see it.
 */
export function credentialAad(identity: CredentialIdentity): Buffer {
  return Buffer.from(
    AAD_PREFIX +
      JSON.stringify([
        identity.provider,
        identity.installKey,
        identity.workspaceId,
      ]),
    "utf8",
  );
}

/** Decode a base64 32-byte key, or explain exactly why it is unusable. */
function decodeKey(encoded: string, label: string): Buffer {
  const trimmed = encoded.trim();
  if (trimmed === "") {
    throw new InvalidCredentialKeyError(`${label} is empty`);
  }

  const key = Buffer.from(trimmed, "base64");
  if (key.length !== KEY_BYTES) {
    // Buffer.from(_, 'base64') is lenient: junk decodes to short garbage rather
    // than throwing. The length check is what actually catches a bad key.
    throw new InvalidCredentialKeyError(
      `${label} decoded to ${key.length} bytes, expected ${KEY_BYTES} (AES-256)`,
    );
  }
  return key;
}

/**
 * Reject a blob that is not canonical base64 before spending a decrypt on it.
 * Node decodes leniently (it skips invalid characters), so a corrupt column
 * would otherwise silently become a short buffer and produce a confusing tag
 * failure instead of an honest "this is not a sealed credential".
 */
function decodeSealed(sealed: string, identity: CredentialIdentity): Buffer {
  const raw = Buffer.from(sealed, "base64");
  if (raw.toString("base64") !== sealed) {
    throw new CredentialOpenError(identity, "not canonical base64");
  }
  if (raw.length < IV_BYTES + TAG_BYTES) {
    throw new CredentialOpenError(
      identity,
      `truncated (${raw.length} bytes, need at least ${IV_BYTES + TAG_BYTES})`,
    );
  }
  return raw;
}

export interface CredentialCipher {
  /** Seal a secret against a row identity. Fresh IV per call (no equality leak). */
  seal(plaintext: string, identity: CredentialIdentity): string;
  /**
   * Open a sealed secret for a row identity. Throws {@link CredentialOpenError}
   * when the blob was not sealed for exactly THIS identity — never returns
   * plaintext on a mismatch, and never falls back to returning the input.
   */
  open(sealed: string, identity: CredentialIdentity): string;
  /** True when `sealed` opens for `identity`. The non-throwing probe. */
  opens(sealed: string, identity: CredentialIdentity): boolean;
}

export interface CredentialCipherOptions {
  /** Base64 32-byte key. `CONNECTORS_CREDENTIAL_KEY`. */
  key: string;
  /**
   * Base64 keys tried, in order, ONLY after the current key fails to open a blob
   * (`CONNECTORS_CREDENTIAL_KEY_PREVIOUS`). Never used to seal — new blobs always
   * take the current key, so a rotation drains as rows are rewritten.
   */
  previousKeys?: readonly string[];
}

/**
 * Build the cipher. Key material is validated HERE, at construction — which is
 * boot — so a malformed key can never surface as a mysterious decrypt failure
 * halfway through a tenant's turn.
 */
// @canonical capability:connector-credential-sealing aka:encrypt,cipher,aead,aad,credential_ref,chat_token_ref,seal doc:.claude/workflows/bp-connectors-charter.md
export function createCredentialCipher(
  options: CredentialCipherOptions,
): CredentialCipher {
  const current = decodeKey(options.key, "CONNECTORS_CREDENTIAL_KEY");
  const previous = (options.previousKeys ?? [])
    .filter((k) => k.trim() !== "")
    .map((k) => decodeKey(k, "CONNECTORS_CREDENTIAL_KEY_PREVIOUS"));

  // Current key first, then each previous key — the rotation order (mirrors
  // LocalKek.try_keys/4). A key that appears twice costs one wasted decrypt and
  // changes nothing, so we do not dedupe by identity.
  const keys = [current, ...previous];

  const openWith = (
    key: Buffer,
    iv: Buffer,
    tag: Buffer,
    ciphertext: Buffer,
    aad: Buffer,
  ): string | null => {
    try {
      const decipher = createDecipheriv(ALGORITHM, key, iv);
      decipher.setAAD(aad);
      decipher.setAuthTag(tag);
      const plaintext = Buffer.concat([
        decipher.update(ciphertext),
        decipher.final(), // throws when the tag (or the AAD) does not check out
      ]);
      return plaintext.toString("utf8");
    } catch {
      return null;
    }
  };

  // Declared as a closure, not a method: `cipher.opens` must keep working when
  // the cipher is destructured (`const { open } = cipher`), and a `this.open()`
  // call would silently break that.
  const open = (sealed: string, identity: CredentialIdentity): string => {
    const raw = decodeSealed(sealed, identity);
    const iv = raw.subarray(0, IV_BYTES);
    const tag = raw.subarray(IV_BYTES, IV_BYTES + TAG_BYTES);
    const ciphertext = raw.subarray(IV_BYTES + TAG_BYTES);
    const aad = credentialAad(identity);

    for (const key of keys) {
      const plaintext = openWith(key, iv, tag, ciphertext, aad);
      if (plaintext !== null) return plaintext;
    }

    throw new CredentialOpenError(
      identity,
      "wrong key, tampered bytes, or sealed for a DIFFERENT row identity",
    );
  };

  return {
    seal(plaintext, identity) {
      if (plaintext === "") {
        // A sealed empty string is a blob that LOOKS provisioned and opens to
        // nothing — the exact shape of a credential that silently does not work.
        // Absence is expressed as SQL NULL, never as a seal of "".
        throw new CredentialSealError(
          "an empty secret. Store SQL NULL for 'not provisioned' instead.",
        );
      }
      if (
        identity.provider === "" ||
        identity.installKey === "" ||
        identity.workspaceId === ""
      ) {
        throw new CredentialSealError(
          "an incomplete row identity. provider, installKey and workspaceId are " +
            "ALL part of the AAD; a blank one would bind the blob to nothing.",
        );
      }

      const iv = randomBytes(IV_BYTES);
      const cipher = createCipheriv(ALGORITHM, current, iv);
      cipher.setAAD(credentialAad(identity));
      const ciphertext = Buffer.concat([
        cipher.update(plaintext, "utf8"),
        cipher.final(),
      ]);
      const tag = cipher.getAuthTag();

      // iv ‖ tag ‖ ct — the LocalKek layout, byte for byte.
      return Buffer.concat([iv, tag, ciphertext]).toString("base64");
    },

    open,

    opens(sealed, identity) {
      try {
        open(sealed, identity);
        return true;
      } catch {
        return false;
      }
    },
  };
}

/**
 * Constant-time comparison of two secrets. Used by tests and by any future
 * verification path; never compare a token with `===`, which leaks its prefix
 * through timing.
 */
export function secretsEqual(a: string, b: string): boolean {
  const left = Buffer.from(a, "utf8");
  const right = Buffer.from(b, "utf8");
  if (left.length !== right.length) return false;
  return timingSafeEqual(left, right);
}
