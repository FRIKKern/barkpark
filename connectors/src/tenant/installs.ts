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
): InstallsLookup {
  return {
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
  };
}

/**
 * Register (or update) ONE install — the operator/OAuth write path (D35).
 *
 * Seals BOTH secrets against this row's identity before they touch SQL, so
 * `connector_installs` never holds a plaintext provider secret or a plaintext
 * chat token. There is no code path in this module that writes either column
 * unsealed.
 *
 * `chatToken` is optional: an install may be created before its workspace-bound
 * `chat` ApiToken exists (the OAuth callback lands the provider secret first).
 * Absent => the column is set NULL, and the install is routable but not runnable
 * until a token is provisioned. It is never defaulted to an operator token.
 *
 * `credentialRef` is optional for the same structural reason (D42): a Teams
 * install has NO per-workspace provider secret — one operator Azure app serves
 * every customer org. Absent => the column is set NULL. A connector that needs a
 * credential rejects the null at mount, in its own `adapterFactory`.
 *
 * NOTE the seal is IDENTITY-BOUND: moving a row to another `workspace_id` (an
 * UPDATE that leaves the blobs alone) makes both blobs un-openable. That is the
 * intended behaviour — a stolen tenant is a dead tenant, not a served one.
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

  await db.query(
    `INSERT INTO chat_bridge.connector_installs
       (provider, install_key, workspace_id, credential_ref, chat_token_ref)
     VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (provider, install_key)
     DO UPDATE SET workspace_id   = EXCLUDED.workspace_id,
                   credential_ref = EXCLUDED.credential_ref,
                   chat_token_ref = EXCLUDED.chat_token_ref`,
    [
      install.provider,
      install.installKey,
      install.workspaceId,
      sealedCredential,
      sealedChatToken,
    ],
  );
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
): InstallsLookup {
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

    async resolveWorkspace(provider, installKey) {
      // Routing keys on the workspace alone — same as the SQL lookup.
      const workspaceId = find(provider, installKey)?.workspaceId;
      return workspaceId === undefined || workspaceId === "" ? null : workspaceId;
    },

    async listInstalls(provider) {
      if (isBlankKey(provider)) return [];
      return [...table.values()].filter((install) => install.provider === provider);
    },
  };
}
