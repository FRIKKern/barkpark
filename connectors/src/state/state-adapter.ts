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
import type { Lock, StateAdapter } from "chat";
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

/**
 * Namespace a StateAdapter to ONE install: every key and thread id the SDK
 * hands it is prefixed `${connectorId}:${installKey}:` before touching storage
 * (charter D160).
 *
 * WHY: state-pg's `keyPrefix` above is built ONCE at boot (startBridge) and is
 * the only tenant column in all five chat_state_* tables — so without this,
 * two installs whose provider thread ids collide (the same human talking to
 * two Telegram bots, or any provider whose ids are only workspace-unique)
 * share subscriptions, cache entries, and locks. The bridge's own
 * thread_session_map is composite-PK-safe (D28/D31); this closes the same
 * hole one layer down, inside the SDK's state. The prefix is
 * connector.id + installKey — NOT workspace-only, which still collides two
 * installs of one provider in one workspace (connector_installs' PK is
 * (provider, install_key), globally unique).
 *
 * Every method of the SDK's StateAdapter interface is wrapped — the object
 * literal is typed as StateAdapter, so a new interface method fails the build
 * here instead of silently bypassing the namespace. Methods that RETURN ids
 * are inverse-mapped: acquireLock strips the prefix from Lock.threadId so the
 * caller sees the id it asked about, and releaseLock/extendLock re-apply it
 * on the way in. QueueEntry carries no thread id (audited against chat's
 * .d.ts), so dequeue needs no inverse map.
 *
 * NO data migration accompanies this: the five tables hold ephemeral
 * coordination state; rows under the old un-scoped keys go dead harmlessly
 * and state reconstructs on the next inbound event per thread.
 */
export function scopeStateAdapter(
  adapter: StateAdapter,
  connectorId: string,
  installKey: string,
): StateAdapter {
  const prefix = `${connectorId}:${installKey}:`;
  const scope = (id: string): string => `${prefix}${id}`;
  const unscope = (id: string): string =>
    id.startsWith(prefix) ? id.slice(prefix.length) : id;
  const scopeLock = (lock: Lock): Lock => ({
    ...lock,
    threadId: scope(lock.threadId),
  });

  return {
    // Lifecycle: the underlying adapter is shared across installs (one pool,
    // one state-pg instance); connect/disconnect stay theirs to manage.
    connect: () => adapter.connect(),
    disconnect: () => adapter.disconnect(),

    // Subscriptions.
    subscribe: (threadId) => adapter.subscribe(scope(threadId)),
    unsubscribe: (threadId) => adapter.unsubscribe(scope(threadId)),
    isSubscribed: (threadId) => adapter.isSubscribed(scope(threadId)),

    // Locks. The Lock object round-trips through the caller, so the prefix is
    // stripped on the way out and re-applied on the way in — the token, which
    // is what actually guards ownership, passes through untouched.
    acquireLock: async (threadId, ttlMs) => {
      const lock = await adapter.acquireLock(scope(threadId), ttlMs);
      return lock === null ? null : { ...lock, threadId: unscope(lock.threadId) };
    },
    extendLock: (lock, ttlMs) => adapter.extendLock(scopeLock(lock), ttlMs),
    releaseLock: (lock) => adapter.releaseLock(scopeLock(lock)),
    forceReleaseLock: (threadId) => adapter.forceReleaseLock(scope(threadId)),

    // Key/value cache.
    get: <T = unknown>(key: string) => adapter.get<T>(scope(key)),
    set: <T = unknown>(key: string, value: T, ttlMs?: number) =>
      adapter.set(scope(key), value, ttlMs),
    setIfNotExists: (key, value, ttlMs) =>
      adapter.setIfNotExists(scope(key), value, ttlMs),
    delete: (key) => adapter.delete(scope(key)),

    // Lists.
    appendToList: (key, value, options) =>
      adapter.appendToList(scope(key), value, options),
    getList: <T = unknown>(key: string) => adapter.getList<T>(scope(key)),

    // Queues. QueueEntry carries no thread id, so nothing to inverse-map.
    enqueue: (threadId, entry, maxSize) =>
      adapter.enqueue(scope(threadId), entry, maxSize),
    dequeue: (threadId) => adapter.dequeue(scope(threadId)),
    queueDepth: (threadId) => adapter.queueDepth(scope(threadId)),
  };
}
