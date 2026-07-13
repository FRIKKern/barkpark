/**
 * `chat_bridge.connector_installs` reads — the tenant map (charter D29).
 *
 *     connector_installs (provider, install_key, workspace_id, credential_ref,
 *                         PRIMARY KEY (provider, install_key))
 *
 * The table is bridge-owned and created by W3-1's bootstrap DDL. This module is
 * READ-ONLY: it answers "which workspace owns this install?" and nothing else.
 *
 * Every read is FAIL-CLOSED, mirroring `Content.Scope.scope_to_workspace/3`:
 * a null/blank/unknown install key yields `null`, never a fallback to some
 * "default" or "only" workspace. A miss must drop the event, not leak it into
 * another tenant's Session.
 */
import type { InstallsLookup, WorkspaceId } from '../connector/types.js';

/**
 * The slice of `pg.Pool` this module needs.
 *
 * Declared structurally rather than importing W3-1's `db/pool` module, so this
 * slice compiles and tests standalone. A real `pg.Pool` (or `PoolClient`, or a
 * transaction handle) satisfies it as-is — `test/tenant.test.ts` pins that
 * assignability at compile time so W3-1's Pool is guaranteed to drop in unchanged.
 */
export interface Queryable {
  query<R extends object = Record<string, unknown>>(
    text: string,
    values?: unknown[],
  ): Promise<{ rows: R[] }>;
}

/** One row of `chat_bridge.connector_installs` as read by this module. */
interface InstallRow {
  workspace_id: string | null;
}

/**
 * The single tenant-routing query. `(provider, install_key)` is the PRIMARY KEY, so
 * this is a point lookup and can return at most one row — `LIMIT 1` is belt-and-braces.
 */
const SELECT_WORKSPACE = `
  SELECT workspace_id
    FROM chat_bridge.connector_installs
   WHERE provider = $1
     AND install_key = $2
   LIMIT 1
`;

/**
 * True when an install key is unusable as a tenant key. A blank key must never reach
 * SQL: `install_key = ''` could match a malformed row, and matching "nothing" against
 * a real row is exactly the cross-tenant leak this guard exists to prevent.
 */
function isBlankKey(installKey: string | null | undefined): boolean {
  return installKey === null || installKey === undefined || installKey.trim() === '';
}

/**
 * Build the production `InstallsLookup` over `chat_bridge.connector_installs`.
 *
 * @param db a `pg.Pool` (W3-1) or anything else that can run the query.
 */
export function createInstallsLookup(db: Queryable): InstallsLookup {
  return {
    async resolveWorkspace(
      provider: string,
      installKey: string | null | undefined,
    ): Promise<WorkspaceId | null> {
      // Fail closed BEFORE touching the database.
      if (isBlankKey(provider) || isBlankKey(installKey)) return null;

      const { rows } = await db.query<InstallRow>(SELECT_WORKSPACE, [provider, installKey]);

      // Unknown install → null. No "did you mean" and no default tenant.
      const workspaceId = rows[0]?.workspace_id;
      if (workspaceId === null || workspaceId === undefined || workspaceId === '') return null;

      return workspaceId;
    },
  };
}

/**
 * Build the composite key for the in-memory table.
 *
 * JSON-encodes the pair rather than joining on a separator character, so there is no
 * delimiter to collide on: ('a', 'b:c') and ('a:b', 'c') are distinct keys, and no
 * provider or install key can forge another's entry by embedding the separator.
 */
function installKeyOf(provider: string, installKey: string): string {
  return JSON.stringify([provider, installKey]);
}

/**
 * An `InstallsLookup` backed by a plain map. Used by tests and by the local
 * no-database smoke path; keeps the fail-closed contract identical to the SQL one
 * so a test that passes here means the same thing it would against Postgres.
 */
export function createInMemoryInstallsLookup(
  installs: Iterable<{ provider: string; installKey: string; workspaceId: WorkspaceId }>,
): InstallsLookup {
  const table = new Map<string, WorkspaceId>();
  for (const install of installs) {
    table.set(installKeyOf(install.provider, install.installKey), install.workspaceId);
  }

  return {
    async resolveWorkspace(provider, installKey) {
      if (isBlankKey(provider) || isBlankKey(installKey)) return null;
      return table.get(installKeyOf(provider, installKey as string)) ?? null;
    },
  };
}
