/**
 * The Chat SDK's StateAdapter, pointed at Barkpark's Postgres but confined to
 * the bridge's own `chat_bridge` schema (charter D28).
 *
 * Verified against the installed @chat-adapter/state-pg@4.34.0 source:
 *   - It auto-creates FIVE tables — chat_state_subscriptions, chat_state_locks,
 *     chat_state_cache, chat_state_lists, chat_state_queues — with UNQUALIFIED
 *     `CREATE TABLE IF NOT EXISTS` (dist/index.js).
 *   - It exposes NO schema / searchPath / table-prefix option (grep: zero hits
 *     for search_path or CREATE SCHEMA in its dist).
 *   - `keyPrefix` (default "chat-sdk") namespaces ROW KEYS in a column — it is
 *     NOT a table-isolation mechanism and must not be relied on as one.
 *
 * Therefore the ONLY thing standing between the SDK's tables and Barkpark's
 * Ecto-owned `public` schema is the search_path of the pool it is handed. We
 * hand it the bridge pool from db/pool.ts, whose connections start in
 * `chat_bridge` — so all five land there. Passing a bare `url` instead would
 * silently create them in `public`, next to chat_sessions. Don't.
 */

import {
  createPostgresState,
  type PostgresStateAdapter,
} from "@chat-adapter/state-pg";
import type pg from "pg";

/** Row-key namespace for the SDK's own state rows (distinct from the schema). */
export const BRIDGE_KEY_PREFIX = "barkpark-bridge";

/**
 * Build the Chat SDK StateAdapter on the bridge's schema-pinned pool.
 *
 * @param pool a Pool from {@link createBridgePool} — its search_path MUST be
 *   `chat_bridge`, which is what keeps the SDK's five tables out of `public`.
 */
export function createBridgeState(pool: pg.Pool): PostgresStateAdapter {
  return createPostgresState({
    client: pool,
    keyPrefix: BRIDGE_KEY_PREFIX,
  });
}
