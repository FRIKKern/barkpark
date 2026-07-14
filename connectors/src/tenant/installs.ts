/**
 * `chat_bridge.connector_installs` reads — the tenant map (charter D29).
 *
 *     connector_installs (provider, install_key, workspace_id, credential_ref,
 *                         PRIMARY KEY (provider, install_key))
 *
 * The table is bridge-owned (created by db/schema.ts). This module is READ-ONLY:
 * it answers "which workspace owns this install, and with what credential?" and
 * nothing else. NOTHING writes it yet — a workspace cannot self-serve an install
 * today; the write path + credential encryption are filed as
 * `connectors-p3-install-write-credentials` and `connectors-encrypt-install-credentials`.
 *
 * Every read is FAIL-CLOSED, mirroring `Content.Scope.scope_to_workspace/3`:
 * a null/blank/unknown install key yields `null`, never a fallback to some
 * "default" or "only" workspace. A miss must DROP the event, not leak it into
 * another tenant's Session.
 */
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
  credential_ref: string | null;
}

/**
 * The tenant-ROUTING query: which workspace owns this install?
 *
 * Deliberately reads `workspace_id` ALONE. Routing an inbound event to its tenant
 * does not require the provider secret — only MOUNTING an adapter does (see
 * `lookupInstall`). Coupling the two would mean an install whose credential lives
 * elsewhere (a future OAuth flow) could not be routed at all.
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

/** The full install — what `adapterFactory` needs, credential included. */
const SELECT_INSTALL = `
  SELECT provider, install_key, workspace_id, credential_ref
    FROM chat_bridge.connector_installs
   WHERE provider = $1
     AND install_key = $2
   LIMIT 1
`;

/** Every install of one provider — the boot path mounts one Chat per row. */
const SELECT_INSTALLS_FOR_PROVIDER = `
  SELECT provider, install_key, workspace_id, credential_ref
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

/**
 * Coerce a row to a usable install, or null. A row missing its workspace or its
 * credential is NOT a tenant we can serve — it cannot be routed and cannot build
 * an adapter — so it fails closed rather than yielding a half-install.
 */
function toInstall(row: InstallRow | undefined): ConnectorInstall | null {
  if (!row) return null;
  const workspaceId = row.workspace_id;
  const credentialRef = row.credential_ref;
  if (workspaceId === null || workspaceId === undefined || workspaceId === "") {
    return null;
  }
  if (
    credentialRef === null ||
    credentialRef === undefined ||
    credentialRef === ""
  ) {
    return null;
  }
  return {
    provider: row.provider,
    installKey: row.install_key,
    workspaceId,
    credentialRef,
  };
}

/**
 * Build the production `InstallsLookup` over `chat_bridge.connector_installs`.
 *
 * @param db a `pg.Pool` or anything else that can run the query.
 */
export function createInstallsLookup(db: Queryable): InstallsLookup {
  return {
    async lookupInstall(provider, installKey) {
      // Fail closed BEFORE touching the database.
      if (isBlankKey(provider) || isBlankKey(installKey)) return null;

      const { rows } = await db.query<InstallRow>(SELECT_INSTALL, [
        provider,
        installKey,
      ]);

      // Unknown install, or one with no credential to build an adapter from -> null.
      return toInstall(rows[0]);
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
      if (workspaceId === null || workspaceId === undefined || workspaceId === "") {
        return null;
      }
      return workspaceId;
    },

    async listInstalls(provider) {
      if (isBlankKey(provider)) return [];
      const { rows } = await db.query<InstallRow>(SELECT_INSTALLS_FOR_PROVIDER, [
        provider,
      ]);
      return rows
        .map(toInstall)
        .filter((install): install is ConnectorInstall => install !== null);
    },
  };
}

/**
 * Register (or update) ONE install — the operator/smoke write path.
 *
 * This is deliberately the ONLY write in the tenant layer, and it is not part of
 * `InstallsLookup` (whose fail-closed read contract stays pure). Without it
 * `startBridge()` could never mount a single connector: nothing else writes
 * `connector_installs`, so the persistent process would boot with zero channels.
 *
 * NOT the self-serve install flow. A workspace cannot install a connector for
 * itself yet — the OAuth/connect UX is P3 (`connectors-p3-install-write-credentials`),
 * and `credential_ref` still stores the provider secret in PLAINTEXT
 * (`connectors-encrypt-install-credentials`). Both are filed, neither is done.
 */
export async function upsertInstall(
  db: Queryable,
  install: ConnectorInstall,
): Promise<void> {
  if (
    isBlankKey(install.provider) ||
    isBlankKey(install.installKey) ||
    isBlankKey(install.workspaceId)
  ) {
    throw new Error(
      "upsertInstall: provider, installKey and workspaceId are all required — " +
        "an install without a workspace could never be routed to a tenant.",
    );
  }

  await db.query(
    `INSERT INTO chat_bridge.connector_installs
       (provider, install_key, workspace_id, credential_ref)
     VALUES ($1, $2, $3, $4)
     ON CONFLICT (provider, install_key)
     DO UPDATE SET workspace_id   = EXCLUDED.workspace_id,
                   credential_ref = EXCLUDED.credential_ref`,
    [
      install.provider,
      install.installKey,
      install.workspaceId,
      install.credentialRef,
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
