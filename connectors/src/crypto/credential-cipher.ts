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
 * ## Wire format — the LocalKek envelope layout, byte for byte
 *
 *     Base64( iv(12) ‖ tag(16) ‖ ciphertext )
 *
 * Same envelope layout as `api/lib/barkpark/crypto/local_kek.ex` on purpose: one
 * wire LAYOUT across the codebase, so a blob is legible byte-for-byte from either
 * language. What differs from LocalKek is the KEY and the AAD: a V2 blob is
 * sealed under a PER-WORKSPACE derived key (see "## Keys") with the `bpc2|` AAD
 * prefix as its version tag, and nothing on the Elixir side decodes it (V2 proved
 * the read path is Node-only). The version is not a stored byte — it is the AAD
 * prefix, recovered at open time by trying each scheme.
 *
 * ## Keys
 *
 * `CONNECTORS_CREDENTIAL_KEY` is an INDEPENDENT instance key (base64, 32 bytes) —
 * not `BARKPARK_KEK`, not the API token. It is the KEK: it never encrypts a row
 * directly. Every V2 seal runs it through
 * `HKDF-SHA256(KEK, salt, "workspace|"+workspaceId)` first, so each workspace has
 * its OWN data-encryption key and a single leaked row-key compromises one tenant,
 * not the instance. Missing key = BOOT FAILURE (see config.ts's `required()`);
 * there is deliberately NO plaintext fallback path in this module, because a
 * fallback is how "encrypted at rest" quietly becomes "sometimes".
 *
 * `CONNECTORS_CREDENTIAL_KEY_PREVIOUS` is tried only AFTER the current key fails,
 * so a key rotation opens old rows without a flag day. New rows always take the
 * current key; a full rotation completes when `tenant/rewrap.ts` re-seals every
 * row under the current per-workspace DEK, after which the previous key can
 * retire. Legacy V1 rows (sealed under the instance key directly, pre-DEK) still
 * open, and the same sweep upgrades them to V2.
 *
 * Zero new dependencies: `node:crypto` only.
 */
import {
  createCipheriv,
  createDecipheriv,
  hkdfSync,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";

const ALGORITHM = "aes-256-gcm";
const KEY_BYTES = 32;
const IV_BYTES = 12;
const TAG_BYTES = 16;

/**
 * The AAD version prefix IS the key-version tag, and it lives INSIDE the sealed
 * envelope: the AAD is authenticated by the GCM tag, so flipping the version a
 * blob was sealed with makes it fail closed. It is NOT a physical column
 * (`connector_installs` is unchanged, and no Elixir decodes the blob — V2). A
 * blob's version is recovered at open time by trying each scheme and letting GCM
 * reject the wrong one, so nothing has to be stored to tell them apart and old
 * V1 rows still open unchanged. See the "## Keys" section above.
 *
 *   V1  the instance key sealed the row directly (pre-DEK, before this wave).
 *   V2  a PER-WORKSPACE key seals the row (this wave). New seals are always V2.
 */
const AAD_PREFIX_V1 = "bpc1|";
const AAD_PREFIX_V2 = "bpc2|";

/** The scheme every NEW seal uses. Opening still accepts V1. */
const CURRENT_VERSION = 2 as const;
type SealVersion = 1 | 2;

/**
 * Per-workspace DEK derivation (V2, charter D37 follow-through).
 *
 * Each workspace's data-encryption key is
 * `HKDF-SHA256(instanceKEK, salt, "workspace|"+workspaceId)` — so the instance
 * key in `.env` never directly encrypts a row, and a ciphertext leaked for one
 * tenant is bound to a key that no other tenant's identity can derive. The AAD
 * already fails a cross-tenant paste closed; the DEK removes the shared key that
 * sat under every tenant, so a single leaked row-key compromises ONE workspace,
 * not the instance.
 *
 * The salt is a fixed domain-separation constant, not a stored random: the KEK
 * is already 32 bytes of entropy, so a per-row random salt would add nothing and
 * would have to be persisted alongside the blob. HKDF's `info` carries the
 * workspace, which is what actually separates the keys.
 */
const DEK_HKDF_SALT = Buffer.from("barkpark/connectors/credential-dek/v2", "utf8");
const DEK_HKDF_INFO_PREFIX = "workspace|";

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
export function credentialAad(
  identity: CredentialIdentity,
  version: SealVersion = CURRENT_VERSION,
): Buffer {
  const prefix = version === 1 ? AAD_PREFIX_V1 : AAD_PREFIX_V2;
  return Buffer.from(
    prefix +
      JSON.stringify([
        identity.provider,
        identity.installKey,
        identity.workspaceId,
      ]),
    "utf8",
  );
}

/**
 * Derive a workspace's V2 data-encryption key from the instance KEK.
 *
 * Exported so the negative test can prove DEK isolation directly: workspace A's
 * DEK and workspace B's DEK are different bytes, and A's DEK cannot open a blob
 * sealed for B — independently of the AAD binding. Callers that seal or open do
 * NOT call this; it lives inside the cipher closure.
 */
export function deriveWorkspaceDek(
  instanceKey: Buffer,
  workspaceId: string,
): Buffer {
  return Buffer.from(
    hkdfSync(
      "sha256",
      instanceKey,
      DEK_HKDF_SALT,
      DEK_HKDF_INFO_PREFIX + workspaceId,
      KEY_BYTES,
    ),
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
  /**
   * True when `sealed` opens under the CURRENT key using the CURRENT scheme
   * (V2 per-workspace DEK) — i.e. it does NOT need rewrapping. A blob sealed
   * under a PREVIOUS key, or in the legacy V1 scheme, returns false even though
   * `open` would still recover it. `tenant/rewrap.ts` uses this to skip
   * already-current rows (idempotency / resumability) and to know that a row
   * still binds the old key.
   */
  isSealedWithCurrentKey(sealed: string, identity: CredentialIdentity): boolean;
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
    const aadV2 = credentialAad(identity, 2);
    const aadV1 = credentialAad(identity, 1);

    // For each candidate KEK (current, then each previous — the rotation order),
    // try the CURRENT scheme first (V2 per-workspace DEK) and fall back to the
    // legacy V1 scheme (instance key straight). GCM fails closed on the wrong
    // key OR the wrong AAD prefix, so at most one (key, scheme) pair opens a blob
    // — that IS how the version is recovered without storing a version byte.
    for (const key of keys) {
      const dek = deriveWorkspaceDek(key, identity.workspaceId);
      const v2 = openWith(dek, iv, tag, ciphertext, aadV2);
      if (v2 !== null) return v2;

      const v1 = openWith(key, iv, tag, ciphertext, aadV1);
      if (v1 !== null) return v1;
    }

    throw new CredentialOpenError(
      identity,
      "wrong key, tampered bytes, or sealed for a DIFFERENT row identity",
    );
  };

  // Does this blob already carry the CURRENT key + CURRENT scheme? The rewrap
  // sweep's idempotency hinges on it: a row every present blob of which answers
  // true is already rewrapped and must be left byte-for-byte alone. Only the
  // current KEK's V2 DEK is tried — a previous-key or V1 blob answers false and
  // gets rewrapped, which is exactly the condition that lets the old key retire.
  const isSealedWithCurrentKey = (
    sealed: string,
    identity: CredentialIdentity,
  ): boolean => {
    let raw: Buffer;
    try {
      raw = decodeSealed(sealed, identity);
    } catch {
      return false;
    }
    const iv = raw.subarray(0, IV_BYTES);
    const tag = raw.subarray(IV_BYTES, IV_BYTES + TAG_BYTES);
    const ciphertext = raw.subarray(IV_BYTES + TAG_BYTES);
    const dek = deriveWorkspaceDek(current, identity.workspaceId);
    return openWith(dek, iv, tag, ciphertext, credentialAad(identity, 2)) !== null;
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

      // V2: seal under this workspace's DERIVED key, never the instance KEK
      // directly. The version tag rides the AAD prefix (bpc2|).
      const dek = deriveWorkspaceDek(current, identity.workspaceId);
      const iv = randomBytes(IV_BYTES);
      const cipher = createCipheriv(ALGORITHM, dek, iv);
      cipher.setAAD(credentialAad(identity, CURRENT_VERSION));
      const ciphertext = Buffer.concat([
        cipher.update(plaintext, "utf8"),
        cipher.final(),
      ]);
      const tag = cipher.getAuthTag();

      // iv ‖ tag ‖ ct — the LocalKek envelope layout, byte for byte.
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

    isSealedWithCurrentKey,
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
