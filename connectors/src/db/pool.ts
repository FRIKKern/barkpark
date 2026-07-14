/**
 * The bridge's Postgres Pool, pinned to the `chat_bridge` schema (charter D28).
 *
 * Why the search_path pin is load-bearing: @chat-adapter/state-pg issues five
 * UNQUALIFIED `CREATE TABLE IF NOT EXISTS` statements against whatever pool it
 * is handed. If that pool's connections default to `public`, the SDK's tables
 * would collide with Barkpark's Ecto-owned schema. By pinning search_path to
 * `chat_bridge` on the connection itself (`options=-c search_path=chat_bridge`,
 * a Postgres startup parameter applied before any query runs), every table —
 * the SDK's and the bridge's own — lands in `chat_bridge`. keyPrefix isolates
 * the SDK's row keys, NOT the schema, so it cannot do this job.
 */

import pg from "pg";
import {
  BRIDGE_TABLE_DDL,
  CHAT_BRIDGE_SCHEMA,
  CREATE_SCHEMA_SQL,
} from "./schema.js";

export { CHAT_BRIDGE_SCHEMA } from "./schema.js";

/**
 * The structural subset of `pg.Pool` the bridge's own modules depend on.
 * Depending on this rather than the concrete `pg.Pool` keeps the map and the
 * installs lookup honest about what they actually need (a `query`), and lets a
 * test substitute a store double at that seam. The schema-isolation proofs
 * themselves run against a REAL Postgres — see test/thread-session-map.test.ts
 * for why an in-memory fake cannot prove them.
 */
export interface BridgePool {
  query(text: string, values?: unknown[]): Promise<{ rows: unknown[] }>;
  connect(): Promise<BridgePoolClient>;
  end(): Promise<void>;
}

export interface BridgePoolClient {
  query(text: string, values?: unknown[]): Promise<{ rows: unknown[] }>;
  release(): void;
}

export interface CreateBridgePoolOptions {
  connectionString: string;
}

/**
 * Build a Pool whose every connection starts in the `chat_bridge` schema.
 * Does not touch the database yet — call {@link ensureBridgeSchema} once at
 * boot to create the schema + tables idempotently.
 */
export function createBridgePool(options: CreateBridgePoolOptions): pg.Pool {
  return new pg.Pool({
    connectionString: options.connectionString,
    // Startup parameter: server-side, applied at connection open, ahead of any
    // query. This is the guarantee that state-pg's unqualified DDL is isolated.
    options: `-c search_path=${CHAT_BRIDGE_SCHEMA}`,
  });
}

/**
 * Raised when a pool's connections are not actually pinned to `chat_bridge`.
 * Booting anyway would silently create the bridge's tables — and state-pg's
 * five — in Barkpark's Ecto-owned `public` schema, so we refuse instead.
 */
export class SchemaIsolationError extends Error {
  constructor(actual: string) {
    super(
      `connectors: refusing to boot — this pool's search_path is "${actual}", not "${CHAT_BRIDGE_SCHEMA}". ` +
        `Unqualified DDL (including @chat-adapter/state-pg's five tables) would land in the wrong schema. ` +
        `Build the pool with createBridgePool() so its connections carry options=-c search_path=${CHAT_BRIDGE_SCHEMA}.`,
    );
    this.name = "SchemaIsolationError";
  }
}

/**
 * Create the `chat_bridge` schema and the bridge-owned tables, idempotently.
 *
 * Deliberately does NOT `SET search_path` itself. The pin has to come from the
 * connection's startup options so that it holds for EVERY connection the pool
 * ever opens — including the ones state-pg gets. A `SET` here would fix up only
 * this one connection while masking a broken pin (a pooled connection is reused,
 * so even a verification query would read back the leftover `SET` and pass). We
 * verify the real thing instead, and fail closed if it is not in force.
 */
export async function ensureBridgeSchema(pool: BridgePool): Promise<void> {
  const client = await pool.connect();
  try {
    // Schema-qualified, so it works whatever the search_path is.
    await client.query(CREATE_SCHEMA_SQL);

    const result = await client.query("SHOW search_path");
    const actual = (result.rows[0] as { search_path?: string } | undefined)
      ?.search_path;
    if (actual !== CHAT_BRIDGE_SCHEMA) {
      throw new SchemaIsolationError(actual ?? "<unset>");
    }

    // Unqualified on purpose: these land wherever search_path points, exactly
    // as state-pg's do. Verified above to be `chat_bridge`.
    for (const ddl of BRIDGE_TABLE_DDL) {
      await client.query(ddl);
    }
  } finally {
    client.release();
  }
}
