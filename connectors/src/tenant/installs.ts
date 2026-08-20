/**
 * `chat_bridge.connector_installs` — the tenant map (charter D29/D35).
 *
 *     connector_installs (provider, install_key, workspace_id,
 *                         credential_ref, chat_token_ref,
 *                         PRIMARY KEY (provider, install_key))
 *
 * The table is bridge-owned (created by db/schema.ts). ONE row is the whole of a
 * tenant's isolation: it says which workspace owns the install, which PROVIDER
 * secret mounts its adapter, and which BARKPARK chat token its traffic travels
 * on. Both secrets are SEALED at rest (AES-256-GCM, AAD-bound to this row's
 * (provider, install_key, workspace_id) — see `crypto/credential-cipher.ts`) and
 * are opened here, on the way out of SQL, and nowhere else.
 *
 * That the token and the routing key come from the SAME row is the point. The P2
 * bridge resolved a workspace from this table and then used one process-wide
 * operator token for every tenant — the routing was per-tenant and the credential
 * was not. Deriving both from one row makes a cross-tenant token impossible to
 * express, rather than merely discouraged.
 *
 * Every read is FAIL-CLOSED, mirroring `Content.Scope.scope_to_workspace/3`:
 * a null/blank/unknown install key yields `null`, never a fallback to some
 * "default" or "only" workspace. A blob that does not open for THIS row's
 * identity yields `null` too — a sealed credential moved between tenants drops
 * the event instead of serving it. A miss must DROP, not leak.
 */
import type {
  CredentialCipher,
  CredentialIdentity,
} from "../crypto/credential-cipher.js";
import { CredentialOpenError } from "../crypto/credential-cipher.js";
import type {
  ConnectorInstall,
  InstallsLookup,
  MutableInstallsLookup,
  WorkspaceId,
} from "../connector/types.js";

/**
 * The slice of `pg.Pool` this module needs.
 *
 * Declared structurally rather than importing the concrete Pool, so the tenant
 * layer compiles and tests without a database. A real `pg.Pool` (or `PoolClient`,
 * or a transaction handle) satisfies it as-is — `test/tenant.test.ts` pins that
 * assignability at compile time, so the production Pool is guaranteed to drop in.
 */
export interface Queryable {
  query<R extends object = Record<string, unknown>>(
    text: string,
    values?: unknown[],
  ): Promise<{ rows: R[] }>;
}

/** One row of `chat_bridge.connector_installs` as read by this module. */
interface InstallRow {
  provider: string;
  install_key: string;
  workspace_id: string | null;
  /** SEALED. Base64(iv‖tag‖ct). Never plaintext. */
  credential_ref: string | null;
  /** SEALED, and NULL until a chat token is provisioned for this install. */
  chat_token_ref: string | null;
}

/**
 * The tenant-ROUTING query: which workspace owns this install?
 *
 * Deliberately reads `workspace_id` ALONE. Routing an inbound event to its tenant
 * does not require a secret — only MOUNTING an adapter and CALLING /v1/chat do
 * (see `lookupInstall`). It also cannot: `workspace_id` is part of the AAD, so
 * the row must be located before either blob can be opened at all.
 *
 * `(provider, install_key)` is the PRIMARY KEY, so this is a point lookup and can
 * return at most one row — `LIMIT 1` is belt-and-braces.
 */
const SELECT_WORKSPACE = `
  SELECT workspace_id
    FROM chat_bridge.connector_installs
   WHERE provider = $1
     AND install_key = $2
   LIMIT 1
`;

/** The full install — what `adapterFactory` and the ChatClient need. */
const SELECT_INSTALL = `
  SELECT provider, install_key, workspace_id, credential_ref, chat_token_ref
    FROM chat_bridge.connector_installs
   WHERE provider = $1
     AND install_key = $2
   LIMIT 1
`;

/** Every install of one provider — the boot path mounts one Chat per row. */
const SELECT_INSTALLS_FOR_PROVIDER = `
  SELECT provider, install_key, workspace_id, credential_ref, chat_token_ref
    FROM chat_bridge.connector_installs
   WHERE provider = $1
   ORDER BY install_key
`;

/**
 * The TOOL-connector lookup (charter D69): which install does THIS workspace hold
 * of THIS provider? A tool connector (GitHub) is one-per-workspace — the workspace
 * IS the tenant key, not a provider-side install key — so the `tool-headers` route
 * keys on `(provider, workspace_id)` after proving the workspace from a signed
 * ticket. `LIMIT 1` because a workspace holds at most one install of a tool
 * provider (nothing enforces it in the PK, so this is belt-and-braces + a stable
 * pick by `install_key` if a stray duplicate ever exists).
 */
const SELECT_INSTALL_BY_WORKSPACE = `
  SELECT provider, install_key, workspace_id, credential_ref, chat_token_ref
    FROM chat_bridge.connector_installs
   WHERE provider = $1
     AND workspace_id = $2
   ORDER BY install_key
   LIMIT 1
`;

/**
 * The write path (charter D52) — one atomic statement, NO read-modify-write.
 *
 * A NULL parameter now means PRESERVE, not "wipe" — but ONLY where preserving is
 * possible. Both blobs are AAD-bound to `(provider, install_key, workspace_id)`
 * (D37), so a preserved blob is openable exactly when the workspace has not
 * changed. The two constraints — "don't clobber a sibling secret" and "never carry
 * a secret across a tenant move" — therefore collapse onto ONE predicate, and the
 * whole fix is a CASE per column:
 *
 *   EXCLUDED not null  -> take the new blob            (the caller supplied one)
 *   same workspace     -> keep the stored blob         (AAD unchanged: it opens)
 *   otherwise          -> NULL                         (a moved tenant loses it)
 *
 * WHY NOT `COALESCE(EXCLUDED.x, connector_installs.x)`, the obvious one-liner: it
 * is WORSE THAN THE BUG. On a workspace change it retains a blob sealed under the
 * OLD identity, which can never be opened again — `toInstall()` fails closed on it
 * and the ENTIRE install disappears from every read. An unrecoverable ciphertext
 * has replaced a recoverable NULL.
 *
 * WHY NOT "re-seal both blobs under the new workspace": re-sealing a
 * WORKSPACE-BOUND chat token under B's AAD hands B a token that still
 * AUTHENTICATES AS A. That is the cross-tenant leak D35 exists to prevent, rebuilt
 * inside its own fix, with the AAD defence disabled because we disabled it
 * ourselves. A tenant move drops the secrets; it does not launder them.
 *
 * Note the ELSE-NULL arm is not merely "safe", it is the ONLY honest answer: after
 * a workspace move the operator MUST re-paste, because nobody — including us — can
 * open what the old identity sealed.
 */
const UPSERT_INSTALL = `
  INSERT INTO chat_bridge.connector_installs
    (provider, install_key, workspace_id, credential_ref, chat_token_ref)
  VALUES ($1, $2, $3, $4, $5)
  ON CONFLICT (provider, install_key)
  DO UPDATE SET
    workspace_id   = EXCLUDED.workspace_id,
    credential_ref = CASE
                       WHEN EXCLUDED.credential_ref IS NOT NULL
                         THEN EXCLUDED.credential_ref
                       WHEN connector_installs.workspace_id = EXCLUDED.workspace_id
                         THEN connector_installs.credential_ref
                       ELSE NULL
                     END,
    chat_token_ref = CASE
                       WHEN EXCLUDED.chat_token_ref IS NOT NULL
                         THEN EXCLUDED.chat_token_ref
                       WHEN connector_installs.workspace_id = EXCLUDED.workspace_id
                         THEN connector_installs.chat_token_ref
                       ELSE NULL
                     END
`;

/**
 * The disconnect path (D51/D52). The bridge had no SQL DELETE at all before this
 * wave: `Bridge.removeInstall` unmounts in memory, so the row survived and the
 * next restart mounted the "disconnected" bot straight back.
 */
const DELETE_INSTALL = `
  DELETE FROM chat_bridge.connector_installs
   WHERE provider = $1
     AND install_key = $2
`;

/**
 * True when an install key is unusable as a tenant key. A blank key must never
 * reach SQL: `install_key = ''` could match a malformed row, and matching
 * "nothing" against a real row is exactly the cross-tenant leak this prevents.
 */
function isBlankKey(installKey: string | null | undefined): boolean {
  return (
    installKey === null || installKey === undefined || installKey.trim() === ""
  );
}

function isBlankSecret(value: string | null | undefined): boolean {
  return value === null || value === undefined || value.trim() === "";
}

/** The identity a row's blobs are sealed against. */
export function installIdentity(
  install: Pick<ConnectorInstall, "provider" | "installKey" | "workspaceId">,
): CredentialIdentity {
  return {
    provider: install.provider,
    installKey: install.installKey,
    workspaceId: install.workspaceId,
  };
}

/**
 * Coerce a SEALED row to a usable, OPENED install — or null.
 *
 * Fails closed on:
 *   - no workspace  (cannot be routed to a tenant)
 *   - a blob (either column) that does not open for THIS row's identity
 *
 * The second case is the cross-tenant one. A blob sealed for workspace A, pasted
 * into workspace B's row, does not open: `workspace_id` is in the AAD. The row is
 * dropped, and B never gets A's bot. That is a `null` here, not an exception —
 * a corrupt or hostile row must not take down the poll loop that read it — but it
 * IS logged, because a failing open is either an incident or a botched rotation
 * and silence would hide both.
 *
 * A row missing its CREDENTIAL does NOT fail closed (D42). `credential_ref` is
 * nullable by design: Teams serves every customer org from ONE operator Azure app,
 * so a Teams install genuinely has no per-workspace provider secret. Dropping
 * those rows here would make Teams invisible to `listInstalls` — it would register,
 * route, and then silently never mount. A connector that DOES need a credential
 * rejects the null in its own `adapterFactory` (Telegram, Discord and WhatsApp all
 * do, loudly, at mount) — which is where the error belongs, because only the
 * connector knows whether it needs one. The tenant-safety fail-closed rule lives on
 * `workspace_id`, not on the credential.
 *
 * `chat_token_ref` NULL is likewise NOT a failure: it means "not provisioned yet".
 * The install comes back with `chatToken: null` and dispatch drops it with a typed
 * `dropped_no_chat_token`. A token blob that fails to OPEN, however, is treated
 * exactly like a credential one: the row is unusable.
 */
function toInstall(
  row: InstallRow | undefined,
  cipher: CredentialCipher,
): ConnectorInstall | null {
  if (!row) return null;

  const workspaceId = row.workspace_id;
  if (isBlankKey(workspaceId)) return null;

  const identity: CredentialIdentity = {
    provider: row.provider,
    installKey: row.install_key,
    workspaceId: workspaceId as string,
  };

  // Absent OR blank both mean "no credential" — two spellings of nothing is one
  // too many for a fail-closed check to get right.
  let credentialRef: string | null = null;
  if (!isBlankSecret(row.credential_ref)) {
    try {
      credentialRef = cipher.open(row.credential_ref as string, identity);
    } catch (err) {
      logOpenFailure("credential_ref", identity, err);
      return null;
    }
  }

  let chatToken: string | null = null;
  if (!isBlankSecret(row.chat_token_ref)) {
    try {
      chatToken = cipher.open(row.chat_token_ref as string, identity);
    } catch (err) {
      logOpenFailure("chat_token_ref", identity, err);
      return null;
    }
  }

  return {
    provider: row.provider,
    installKey: row.install_key,
    workspaceId: workspaceId as string,
    credentialRef,
    chatToken,
  };
}

/** Loud, and free of secrets — the identity is the whole of what is printed. */
function logOpenFailure(
  column: string,
  identity: CredentialIdentity,
  err: unknown,
): void {
  const why =
    err instanceof CredentialOpenError
      ? err.message
      : err instanceof Error
        ? err.message
        : String(err);
  console.error(
    `[bridge] connector_installs.${column} did NOT open for ` +
      `provider=${identity.provider} install=${identity.installKey} ` +
      `workspace=${identity.workspaceId} — dropping this install. ` +
      `Either the row was sealed under a different key (rotate: set ` +
      `CONNECTORS_CREDENTIAL_KEY_PREVIOUS) or its identity was altered after ` +
      `sealing (a moved credential — investigate). ${why}`,
  );
}

/**
 * Build the production `InstallsLookup` over `chat_bridge.connector_installs`.
 *
 * @param db a `pg.Pool` or anything else that can run the query.
 * @param cipher opens the row's sealed secrets. REQUIRED — there is no
 *   plaintext-passthrough mode, by design.
 */
export function createInstallsLookup(
  db: Queryable,
  cipher: CredentialCipher,
): MutableInstallsLookup {
  return {
    async deleteInstall(provider, installKey) {
      return deleteInstall(db, provider, installKey);
    },

    async lookupInstall(provider, installKey) {
      // Fail closed BEFORE touching the database.
      if (isBlankKey(provider) || isBlankKey(installKey)) return null;

      const { rows } = await db.query<InstallRow>(SELECT_INSTALL, [
        provider,
        installKey,
      ]);

      // Unknown install, or one whose seals do not open for its own row -> null.
      return toInstall(rows[0], cipher);
    },

    async resolveWorkspace(provider, installKey) {
      // Fail closed BEFORE touching the database.
      if (isBlankKey(provider) || isBlankKey(installKey)) return null;

      const { rows } = await db.query<{ workspace_id: string | null }>(
        SELECT_WORKSPACE,
        [provider, installKey],
      );

      // Unknown install -> null. No "did you mean" and no default tenant.
      const workspaceId = rows[0]?.workspace_id;
      if (isBlankKey(workspaceId)) return null;
      return workspaceId as WorkspaceId;
    },

    async listInstalls(provider) {
      if (isBlankKey(provider)) return [];
      const { rows } = await db.query<InstallRow>(SELECT_INSTALLS_FOR_PROVIDER, [
        provider,
      ]);
      return rows
        .map((row) => toInstall(row, cipher))
        .filter((install): install is ConnectorInstall => install !== null);
    },

    async lookupByWorkspace(provider, workspaceId) {
      // Fail closed BEFORE touching the database — a blank workspace must never
      // match a NULL-workspace half-row and hand out its credential.
      if (isBlankKey(provider) || isBlankKey(workspaceId)) return null;

      const { rows } = await db.query<InstallRow>(SELECT_INSTALL_BY_WORKSPACE, [
        provider,
        workspaceId,
      ]);

      // Unknown pair, or a row whose seal does not open for its own identity -> null.
      return toInstall(rows[0], cipher);
    },
  };
}

/**
 * Register (or update) ONE install — the operator/OAuth/connect write path
 * (D35/D52).
 *
 * Seals BOTH secrets against this row's identity before they touch SQL, so
 * `connector_installs` never holds a plaintext provider secret or a plaintext
 * chat token. There is no code path in this module that writes either column
 * unsealed.
 *
 * THE THREE-WAY MEANING OF A SECRET FIELD, and it is the whole of D52:
 *
 *   - a NON-BLANK string  => seal it and STORE it.
 *   - ABSENT (`undefined`) => "I am not touching this column."
 *         On INSERT that lands NULL (there is nothing to preserve). On UPDATE the
 *         stored blob is PRESERVED — but only when the workspace is unchanged, so
 *         a preserved blob is always one that can still be opened (its AAD holds).
 *   - `null` / `""`       => the same as absent, deliberately: `isBlankSecret`
 *         cannot tell them apart and neither can any caller, so treating them
 *         differently would be a distinction nobody could rely on. To REVOKE a
 *         secret, delete the row ({@link deleteInstall}) and re-connect. That is
 *         what DISCONNECT does.
 *
 * The bug this replaces: the old `ON CONFLICT DO UPDATE` set all three columns
 * unconditionally, and `isBlankSecret(undefined)` is true — so the Slack OAuth
 * callback (which builds its install with NO `chatToken` key: `oauth/slack-oauth.ts`,
 * the ONLY production caller) silently WIPED `chat_token_ref` to NULL on every
 * re-auth. Routing kept working, the agent went unreachable, and nothing errored.
 *
 * `credentialRef` absent is ALSO a legitimate steady state (D42): a Teams install
 * has NO per-workspace provider secret — one operator Azure app serves every
 * customer org — so a fresh Teams row lands `credential_ref` NULL and stays that
 * way. A connector that DOES need a credential rejects the null at mount, in its
 * own `adapterFactory`.
 *
 * NOTE the seal is IDENTITY-BOUND: an install MOVED to another `workspace_id`
 * cannot carry its old blobs (they would never open again) and must not be re-sealed
 * into the new tenant (that would hand B a token authenticating as A). Both
 * un-supplied secrets are therefore NULLed by the move, and the operator re-pastes.
 * See {@link UPSERT_INSTALL}.
 */
export async function upsertInstall(
  db: Queryable,
  cipher: CredentialCipher,
  install: ConnectorInstall,
): Promise<void> {
  if (
    isBlankKey(install.provider) ||
    isBlankKey(install.installKey) ||
    isBlankKey(install.workspaceId)
  ) {
    throw new Error(
      "upsertInstall: provider, installKey and workspaceId are all required — " +
        "an install without a workspace could never be routed to a tenant, and " +
        "all three are part of the seal's AAD.",
    );
  }

  const identity = installIdentity(install);
  const sealedCredential = isBlankSecret(install.credentialRef)
    ? null
    : cipher.seal(install.credentialRef as string, identity);
  const sealedChatToken = isBlankSecret(install.chatToken)
    ? null
    : cipher.seal(install.chatToken as string, identity);

  await db.query(UPSERT_INSTALL, [
    install.provider,
    install.installKey,
    install.workspaceId,
    sealedCredential,
    sealedChatToken,
  ]);
}

/**
 * DELETE one install row — the durable half of a disconnect (D51).
 *
 * Returns `true` when a row was actually removed. The caller (the disconnect
 * route) has already checked that the row belongs to the ticket's workspace: this
 * function is keyed by the PRIMARY KEY alone and is NOT a tenant boundary. Do not
 * call it with an unverified `(provider, installKey)` pair.
 *
 * Deliberately unconditional on the secrets: the row IS the install, and dropping
 * it drops both sealed blobs with it. There is no "revoke the credential but keep
 * the row" state, because since D52 a null secret means PRESERVE — so revocation
 * has to be a DELETE or it is nothing at all.
 */
export async function deleteInstall(
  db: Queryable,
  provider: string,
  installKey: string,
): Promise<boolean> {
  if (isBlankKey(provider) || isBlankKey(installKey)) return false;
  const result = (await db.query(DELETE_INSTALL, [provider, installKey])) as {
    rows: unknown[];
    rowCount?: number | null;
  };
  // `pg` reports rowCount; a structural `Queryable` (a test double) may not, in
  // which case "a delete was attempted against a real row" is the best we can say.
  return result.rowCount === undefined || result.rowCount === null
    ? true
    : result.rowCount > 0;
}

/**
 * Build the composite key for the in-memory table.
 *
 * JSON-encodes the pair rather than joining on a separator character, so there is
 * no delimiter to collide on: ('a', 'b:c') and ('a:b', 'c') are distinct keys, and
 * no provider or install key can forge another's entry by embedding the separator.
 */
function installKeyOf(provider: string, installKey: string): string {
  return JSON.stringify([provider, installKey]);
}

/**
 * An `InstallsLookup` backed by a plain map. Used by tests and by the local
 * no-database path; keeps the fail-closed contract IDENTICAL to the SQL one, so a
 * test that passes here means the same thing it would against Postgres.
 *
 * No cipher: there is no rest to encrypt at. The installs handed in are already
 * the OPENED shape the SQL lookup returns.
 */
export function createInMemoryInstallsLookup(
  installs: Iterable<ConnectorInstall>,
): MutableInstallsLookup {
  const table = new Map<string, ConnectorInstall>();
  for (const install of installs) {
    table.set(installKeyOf(install.provider, install.installKey), install);
  }

  const find = (
    provider: string,
    installKey: string | null | undefined,
  ): ConnectorInstall | null => {
    if (isBlankKey(provider) || isBlankKey(installKey)) return null;
    return table.get(installKeyOf(provider, installKey as string)) ?? null;
  };

  return {
    async lookupInstall(provider, installKey) {
      return find(provider, installKey);
    },

    /** Same contract as the SQL one: `true` only when a row was really there. */
    async deleteInstall(provider, installKey) {
      if (isBlankKey(provider) || isBlankKey(installKey)) return false;
      return table.delete(installKeyOf(provider, installKey));
    },

    async resolveWorkspace(provider, installKey) {
      // Routing keys on the workspace alone — same as the SQL lookup.
      const workspaceId = find(provider, installKey)?.workspaceId;
      return workspaceId === undefined || workspaceId === "" ? null : workspaceId;
    },

    async listInstalls(provider) {
      if (isBlankKey(provider)) return [];
      return [...table.values()].filter((install) => install.provider === provider);
    },

    async lookupByWorkspace(provider, workspaceId) {
      if (isBlankKey(provider) || isBlankKey(workspaceId)) return null;
      // Same fail-closed contract as the SQL lookup: the workspace is the key.
      return (
        [...table.values()].find(
          (install) =>
            install.provider === provider && install.workspaceId === workspaceId,
        ) ?? null
      );
    },
  };
}
