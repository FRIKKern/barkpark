/**
 * THE PENDING-CONNECT JOIN (charter D63) — how Add-to-Slack's OAuth flow lands a
 * workspace-bound chat token that only Studio can mint.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * WHY THIS EXISTS (it is NOT the D52 wipe — that shipped fixed)
 * ─────────────────────────────────────────────────────────────────────────────
 * A Slack OAuth install crosses a browser REDIRECT: Studio starts the flow, Slack
 * bounces the operator through `slack.com`, and the PUBLIC callback lands back on
 * the bridge with a one-time `code`. Two facts collide there:
 *
 *   1. The bridge CANNOT MINT a Barkpark chat token — it holds no Barkpark
 *      credential (that is the whole D48 ruling). Only Studio (the BEAM) can.
 *   2. Studio cannot hand the token to the public callback directly: the callback
 *      is a browser redirect, and the raw token must NEVER ride the readable OAuth
 *      `state` (it traverses slack.com, the URL bar and every proxy log).
 *
 * So the token rides the LOOPBACK, ahead of the redirect, into a short-lived
 * bridge-owned row keyed by the ticket's `nonce`; the public callback JOINS that
 * row by the SAME nonce (carried, signed, in `state`) and writes the install ONCE
 * with BOTH secrets. Miss/expired ⇒ fail closed, no install.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE SEAL AT REST — a DISTINCT identity from the install row
 * ─────────────────────────────────────────────────────────────────────────────
 * The pending row is staged BEFORE the install key is known (the OAuth callback
 * learns `team_id`/`enterprise_id` only after the exchange). So it cannot be
 * sealed under the install identity `(provider, install_key, workspace_id)` the
 * way `connector_installs` is. It is sealed under the PENDING identity
 * `(provider, "pending:<nonce>", workspace_id)` instead — a blob that, by
 * construction, does NOT open as an install blob and vice versa. On consume it is
 * opened here and handed to `upsertInstall` as PLAINTEXT, which re-seals it under
 * the real install identity. There is never a re-seal without a decrypt in
 * between, so a moved workspace still fails closed exactly as everywhere else.
 *
 * Single-use: consume is a `DELETE … RETURNING`, so a replayed callback (or two
 * racing ones) can consume the row at most once.
 */
import type {
  CredentialCipher,
  CredentialIdentity,
} from "../crypto/credential-cipher.js";
import type { Queryable } from "../tenant/installs.js";
import type { WorkspaceId } from "../connector/types.js";

/** The staged join. TTL reuses the OAuth state window (D63). */
export const PENDING_CONNECT_TTL_MS = 600_000;

/**
 * The row identity the staged chat token is sealed against.
 *
 * `install_key` is DELIBERATELY `pending:<nonce>` — the real install key is not
 * known yet, and using the nonce keeps a pending blob from ever opening as an
 * install blob (they carry different AAD). Never blank, so the cipher accepts it.
 */
export function pendingConnectIdentity(
  provider: string,
  nonce: string,
  workspaceId: WorkspaceId,
): CredentialIdentity {
  return { provider, installKey: `pending:${nonce}`, workspaceId };
}

const STAGE_SQL = `
  INSERT INTO chat_bridge.pending_connect
    (nonce, workspace_id, provider, chat_token_ref, expires_at)
  VALUES ($1, $2, $3, $4, $5)
  ON CONFLICT (nonce) DO UPDATE SET
    workspace_id   = EXCLUDED.workspace_id,
    provider       = EXCLUDED.provider,
    chat_token_ref = EXCLUDED.chat_token_ref,
    expires_at     = EXCLUDED.expires_at
`;

/**
 * Consume is a single atomic statement: DELETE the row and RETURN it, but only if
 * it has not expired. An expired row is left for the sweep and reported as a miss.
 * `DELETE … RETURNING` makes the row single-use even under a replayed callback.
 */
const CONSUME_SQL = `
  DELETE FROM chat_bridge.pending_connect
   WHERE nonce = $1
     AND expires_at > now()
  RETURNING workspace_id, provider, chat_token_ref
`;

export interface StagePendingConnectInput {
  nonce: string;
  workspaceId: WorkspaceId;
  provider: string;
  /** The RAW Barkpark chat token, minted by Studio. Sealed here, never stored plain. */
  chatToken: string;
  ttlMs?: number;
  now?: () => number;
}

/**
 * Stage a pending connect row: seal the raw chat token under the pending identity
 * and write it with a short expiry. Overwrites any prior row for the same nonce
 * (a nonce is unique per flow, so this only matters for a re-stage of the same one).
 */
export async function stagePendingConnect(
  db: Queryable,
  cipher: CredentialCipher,
  input: StagePendingConnectInput,
): Promise<void> {
  const nonce = input.nonce?.trim();
  const workspaceId = input.workspaceId?.trim();
  const provider = input.provider?.trim();
  const chatToken = input.chatToken?.trim();

  if (!nonce || !workspaceId || !provider || !chatToken) {
    throw new Error(
      "stagePendingConnect: nonce, workspaceId, provider and a non-empty chat token " +
        "are all required — a pending row with no token could never complete a connect.",
    );
  }

  const sealed = cipher.seal(
    chatToken,
    pendingConnectIdentity(provider, nonce, workspaceId),
  );
  const now = (input.now ?? Date.now)();
  const expiresAt = new Date(now + (input.ttlMs ?? PENDING_CONNECT_TTL_MS));

  await db.query(STAGE_SQL, [nonce, workspaceId, provider, sealed, expiresAt]);
}

export interface ConsumedPendingConnect {
  workspaceId: WorkspaceId;
  provider: string;
  /** The OPENED (plaintext) chat token, ready to hand to `upsertInstall`. */
  chatToken: string;
}

interface PendingRow {
  workspace_id: string | null;
  provider: string | null;
  chat_token_ref: string | null;
}

/**
 * Consume a pending row by nonce, atomically and once. Returns null for a missing
 * or expired row, or one whose sealed token does not open (tamper / wrong key) —
 * every one of those is a fail-closed drop, never an install.
 */
export async function consumePendingConnect(
  db: Queryable,
  cipher: CredentialCipher,
  nonce: string,
): Promise<ConsumedPendingConnect | null> {
  const key = nonce?.trim();
  if (!key) return null;

  const { rows } = await db.query<PendingRow>(CONSUME_SQL, [key]);
  const row = rows[0];
  if (!row) return null;

  const workspaceId = row.workspace_id?.trim();
  const provider = row.provider?.trim();
  const sealed = row.chat_token_ref?.trim();
  if (!workspaceId || !provider || !sealed) return null;

  try {
    const chatToken = cipher.open(
      sealed,
      pendingConnectIdentity(provider, key, workspaceId),
    );
    return { workspaceId, provider, chatToken };
  } catch {
    // A staged token that does not open is unusable — drop it. The row is already
    // deleted (single-use), so a retry starts a fresh flow.
    return null;
  }
}
