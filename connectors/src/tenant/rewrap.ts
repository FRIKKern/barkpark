/**
 * Rewrap sweep — re-seal every `connector_installs` row under the CURRENT
 * per-workspace DEK, so an old credential key can actually retire (charter
 * D37 follow-through).
 *
 * ## Why a sweep exists at all
 *
 * `credential-cipher.ts` re-seals a row only when the row is REWRITTEN (a
 * re-connect, an OAuth callback). So after a key rotation the previous key
 * cannot be dropped until every install happens to be touched — which, for a
 * BYO-token bot that just sits and works, is never. This sweep is the missing
 * "touch every row once": it opens each blob under whatever key still opens it
 * (current or previous, V1 or V2) and writes it back sealed under the CURRENT
 * per-workspace DEK. Run it after a rotation, then delete
 * `CONNECTORS_CREDENTIAL_KEY_PREVIOUS`.
 *
 * ## Bridge-owned, never external raw SQL
 *
 * The bridge is the ONLY writer of `chat_bridge.connector_installs` (D51/D52).
 * This module imports the bridge's own pool (`createBridgePool`) and cipher and
 * writes through them — it does not hand an operator a `psql` recipe, because a
 * hand-written re-seal is exactly the way an unsealed or mis-AAD'd blob lands.
 * The cross-provider list query lives HERE (not in `installs.ts`, which reads
 * one provider at a time on the hot path) because a sweep is the only caller
 * that wants every row of every provider at once.
 *
 * ## Idempotent + resumable
 *
 * A row whose every present blob already opens under the current key + current
 * scheme (`cipher.isSealedWithCurrentKey`) is SKIPPED, byte-for-byte untouched.
 * So a second run is a no-op, and a run interrupted halfway resumes cleanly —
 * the rows it already did are recognised as done and the rest get finished. No
 * cursor to persist.
 *
 * ## Concurrency-safe — a pinned-bytes UPDATE, never a rollback
 *
 * The sweep reads a row's OLD ciphertext, computes the re-seal in memory, then
 * UPDATEs `WHERE credential_ref IS NOT DISTINCT FROM $old AND chat_token_ref IS
 * NOT DISTINCT FROM $old`. If a concurrent install write (an OAuth callback, a
 * re-connect) changed either blob in between, the UPDATE matches zero rows and
 * the sweep leaves the newer write in place — the concurrent write is SKIPPED,
 * never rolled back. `IS NOT DISTINCT FROM` is null-safe, so a NULL column pins
 * as NULL rather than never matching. A skipped row is picked up by the next
 * run, whose read sees the newer bytes.
 *
 * Deliberately NOT a `WHERE key_version = $old` compare-and-swap: there is no
 * key_version column (the version is blob-internal, V2), and CASing on a version
 * alone would happily overwrite a concurrent write that shares the old version —
 * the rollback bug this pinning avoids.
 */
import type {
  CredentialCipher,
  CredentialIdentity,
} from "../crypto/credential-cipher.js";
import { CredentialOpenError } from "../crypto/credential-cipher.js";

/**
 * The slice of `pg.Pool` the sweep needs. Structural so a test can wrap the real
 * pool to interleave a concurrent write, and so this compiles without a database.
 * A real `pg.Pool` satisfies it (it reports `rowCount`); a bare `Queryable`
 * double that does not is treated conservatively — see {@link rewrapAllInstalls}.
 */
export interface RewrapQueryable {
  query<R extends object = Record<string, unknown>>(
    text: string,
    values?: unknown[],
  ): Promise<{ rows: R[]; rowCount?: number | null }>;
}

/** One raw row, blobs unopened. */
interface RewrapRow {
  provider: string;
  install_key: string;
  workspace_id: string | null;
  credential_ref: string | null;
  chat_token_ref: string | null;
}

/**
 * Every install of every provider — the sweep's one read. Ordered so a run is
 * deterministic and a resumed run walks the same order.
 */
const SELECT_ALL_INSTALLS = `
  SELECT provider, install_key, workspace_id, credential_ref, chat_token_ref
    FROM chat_bridge.connector_installs
   ORDER BY provider, install_key
`;

/**
 * Re-seal ONE row, pinning the exact OLD bytes it was read with. A concurrent
 * write that changed either blob makes the WHERE fail (null-safe), so the newer
 * write survives untouched. Returns the affected row count via `pg`'s rowCount.
 */
const REWRAP_ROW = `
  UPDATE chat_bridge.connector_installs
     SET credential_ref = $3,
         chat_token_ref = $4
   WHERE provider = $1
     AND install_key = $2
     AND credential_ref IS NOT DISTINCT FROM $5
     AND chat_token_ref IS NOT DISTINCT FROM $6
`;

function isBlankSecret(value: string | null | undefined): boolean {
  return value === null || value === undefined || value.trim() === "";
}

/** What one sweep did — every row lands in exactly one bucket. */
export interface RewrapResult {
  /** Rows examined. */
  scanned: number;
  /** Rows re-sealed under the current per-workspace DEK. */
  rewrapped: number;
  /** Already current (both present blobs open under the current key/scheme). */
  alreadyCurrent: number;
  /** No workspace_id — cannot form an identity, so cannot be re-sealed. */
  noWorkspace: number;
  /** A present blob did not open under ANY key — left alone, logged. */
  unopenable: number;
  /** A concurrent write changed the row between read and update — left alone. */
  raced: number;
}

/** Optional hooks — a logger for the runnable script, silent by default. */
export interface RewrapOptions {
  /** Called once per row that could not be re-sealed. Defaults to console.error. */
  onSkip?: (
    identity: CredentialIdentity,
    reason: "no_workspace" | "unopenable" | "raced",
    detail: string,
  ) => void;
}

/**
 * Re-seal every install under the current per-workspace DEK. Returns a tally.
 *
 * @param db a `pg.Pool` from {@link import("../db/pool.js").createBridgePool} —
 *   the bridge's own writer, never external SQL.
 * @param cipher the bridge's cipher, its current key being the one to rotate TO.
 */
export async function rewrapAllInstalls(
  db: RewrapQueryable,
  cipher: CredentialCipher,
  options: RewrapOptions = {},
): Promise<RewrapResult> {
  const onSkip =
    options.onSkip ??
    ((identity, reason, detail) =>
      console.error(
        `[rewrap] skipped provider=${identity.provider} ` +
          `install=${identity.installKey} workspace=${identity.workspaceId} ` +
          `(${reason}): ${detail}`,
      ));

  const { rows } = await db.query<RewrapRow>(SELECT_ALL_INSTALLS);

  const result: RewrapResult = {
    scanned: rows.length,
    rewrapped: 0,
    alreadyCurrent: 0,
    noWorkspace: 0,
    unopenable: 0,
    raced: 0,
  };

  for (const row of rows) {
    // No workspace ⇒ no identity ⇒ the blobs cannot be opened OR re-sealed
    // (workspace_id is in the AAD and derives the DEK). Leave it; a workspaceless
    // row is already unroutable — installs.ts drops it — so nothing regresses.
    if (isBlankSecret(row.workspace_id)) {
      const identity: CredentialIdentity = {
        provider: row.provider,
        installKey: row.install_key,
        workspaceId: row.workspace_id ?? "",
      };
      result.noWorkspace += 1;
      onSkip(identity, "no_workspace", "row has no workspace_id");
      continue;
    }

    const identity: CredentialIdentity = {
      provider: row.provider,
      installKey: row.install_key,
      workspaceId: row.workspace_id as string,
    };

    const hasCred = !isBlankSecret(row.credential_ref);
    const hasToken = !isBlankSecret(row.chat_token_ref);

    // Already done? Every PRESENT blob under the current key + current scheme.
    // A row with no secrets at all (both NULL) is trivially current: nothing to
    // re-seal, so it counts as alreadyCurrent, not rewrapped.
    const credCurrent =
      !hasCred ||
      cipher.isSealedWithCurrentKey(row.credential_ref as string, identity);
    const tokenCurrent =
      !hasToken ||
      cipher.isSealedWithCurrentKey(row.chat_token_ref as string, identity);
    if (credCurrent && tokenCurrent) {
      result.alreadyCurrent += 1;
      continue;
    }

    // Open each present blob under whatever key still opens it (current or
    // previous, V1 or V2). A blob that opens for NOBODY is either corrupt or
    // sealed under a key that is no longer configured — leave the row untouched
    // (re-sealing garbage would just relabel it) and report it loudly.
    let credPlain: string | null = null;
    let tokenPlain: string | null = null;
    try {
      if (hasCred) credPlain = cipher.open(row.credential_ref as string, identity);
      if (hasToken)
        tokenPlain = cipher.open(row.chat_token_ref as string, identity);
    } catch (err) {
      const why = err instanceof CredentialOpenError ? err.message : String(err);
      result.unopenable += 1;
      onSkip(identity, "unopenable", why);
      continue;
    }

    // Re-seal under the CURRENT per-workspace DEK. A NULL blob stays NULL — the
    // sweep never invents a secret where there was none (a Teams row legitimately
    // has no credential; a not-yet-provisioned row has no chat token).
    const newCred = credPlain === null ? null : cipher.seal(credPlain, identity);
    const newToken = tokenPlain === null ? null : cipher.seal(tokenPlain, identity);

    // Pin the OLD bytes: a concurrent install write loses this row to the newer
    // value and is picked up next run, never rolled back.
    const update = await db.query(REWRAP_ROW, [
      row.provider,
      row.install_key,
      newCred,
      newToken,
      row.credential_ref,
      row.chat_token_ref,
    ]);

    // `pg` reports rowCount. A structural double that does not is assumed to have
    // applied the write (the real production pool always reports it).
    const applied =
      update.rowCount === undefined || update.rowCount === null
        ? true
        : update.rowCount > 0;
    if (applied) {
      result.rewrapped += 1;
    } else {
      result.raced += 1;
      onSkip(
        identity,
        "raced",
        "a concurrent install write changed the row between read and update — " +
          "the newer write was kept; re-run to finish this row",
      );
    }
  }

  return result;
}
