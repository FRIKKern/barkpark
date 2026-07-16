/**
 * The thread<->session map: the ONLY per-conversation state the bridge holds
 * (charter D6/D28). It maps a channel's (workspace_id, thread_id) to a Barkpark
 * Session UUID (chat_sessions.id) — minted on the first message of a thread,
 * resumed on every message thereafter. Same-channel continuity falls out for
 * free; true cross-CHANNEL identity-linking is deferred to P4 (D31).
 *
 * `POST /v1/chat/sessions` ALWAYS mints a fresh UUID — there is no find-or-create
 * server-side — so this map is what makes a conversation continuous at all.
 *
 * Persistence is a bridge-OWNED `chat_bridge.thread_session_map` row, NOT
 * `thread.setState`: the Chat SDK's thread state hardcodes a 30-day TTL
 * (THREAD_STATE_TTL_MS, index.js:510), which would silently drop the Session of
 * any conversation that goes quiet for a month, and the next message would start
 * a brand-new Session with no memory. A plain indexed row has no TTL. The D28
 * invariant test enforces this against the source.
 *
 * `mint` is a CALLBACK rather than an injected ChatClient because the bridge is
 * multi-tenant (D1): the Session must be minted with THAT workspace's token, and
 * the map itself must stay tenant-agnostic.
 */

import type { BridgePool } from "../db/pool.js";

/** The persistence seam. Faked at this boundary in unit tests; Postgres in prod. */
export interface ThreadSessionStore {
  get(workspaceId: string, threadId: string): Promise<string | null>;
  /**
   * Insert the mapping. MUST be insert-if-absent and return the WINNING row's
   * session uuid, so two concurrent first-messages on one thread converge on a
   * single Session instead of one silently overwriting the other.
   */
  putIfAbsent(
    workspaceId: string,
    threadId: string,
    sessionUuid: string,
  ): Promise<string>;
}

export interface ResolvedSession {
  sessionUuid: string;
  /** True ONLY when this call created the thread's Session mapping. */
  minted: boolean;
}

export interface ThreadSessionMap {
  get(workspaceId: string, threadId: string): Promise<string | null>;
  /**
   * Resume the thread's Session, or mint one on first contact.
   *
   * `mint` is invoked ONLY on a miss — it is the caller's "create a Barkpark
   * Session with this tenant's token" call. If a racing writer wins the insert we
   * adopt the winner's uuid and report `minted: false`, so exactly one Session
   * becomes the thread's durable memory.
   */
  resolveOrMint(
    workspaceId: string,
    threadId: string,
    mint: () => Promise<string>,
  ): Promise<ResolvedSession>;
}

export function createThreadSessionMap(
  store: ThreadSessionStore,
): ThreadSessionMap {
  return {
    async get(workspaceId, threadId) {
      return store.get(workspaceId, threadId);
    },

    async resolveOrMint(workspaceId, threadId, mint) {
      const existing = await store.get(workspaceId, threadId);
      if (existing) return { sessionUuid: existing, minted: false };

      const fresh = await mint();
      const winner = await store.putIfAbsent(workspaceId, threadId, fresh);
      // A concurrent first-message may have inserted first. The store returns the
      // row that actually persisted; if it is not ours, we lost the race and did
      // not mint this thread's Session.
      //
      // The loser's freshly-minted Barkpark Session is then orphaned — a harmless
      // but real leak of one chat_sessions row, only ever on a thread's first
      // message. Tracked as `connectors-orphan-session-on-mint-race`.
      return { sessionUuid: winner, minted: winner === fresh };
    },
  };
}

/**
 * The production store: the bridge-owned `chat_bridge.thread_session_map`.
 *
 * Schema-QUALIFIED on purpose. The pool's `search_path` pin exists to corral
 * @chat-adapter/state-pg's five UNQUALIFIED `CREATE TABLE` statements (D28) — it
 * is not something the bridge's own SQL should quietly depend on. Qualifying here
 * means a drifted search_path can never silently point our reads and writes at a
 * different schema's table.
 */
export function createPgThreadSessionStore(pool: BridgePool): ThreadSessionStore {
  return {
    async get(workspaceId, threadId) {
      const { rows } = await pool.query(
        `SELECT session_uuid
           FROM chat_bridge.thread_session_map
          WHERE workspace_id = $1 AND thread_id = $2`,
        [workspaceId, threadId],
      );
      return (
        (rows[0] as { session_uuid: string } | undefined)?.session_uuid ?? null
      );
    },

    async putIfAbsent(workspaceId, threadId, sessionUuid) {
      // Insert-if-absent, race-safe: a concurrent first-message on the same thread
      // loses the INSERT (ON CONFLICT DO NOTHING) and RETURNING comes back EMPTY,
      // so we re-read the winner rather than clobbering it. Postgres semantics —
      // an in-memory fake that returns the conflicting row here would hide the bug.
      const inserted = await pool.query(
        `INSERT INTO chat_bridge.thread_session_map (workspace_id, thread_id, session_uuid)
              VALUES ($1, $2, $3)
         ON CONFLICT (workspace_id, thread_id) DO NOTHING
           RETURNING session_uuid`,
        [workspaceId, threadId, sessionUuid],
      );
      const won = (inserted.rows[0] as { session_uuid: string } | undefined)
        ?.session_uuid;
      if (won) return won;

      const existing = await pool.query(
        `SELECT session_uuid
           FROM chat_bridge.thread_session_map
          WHERE workspace_id = $1 AND thread_id = $2`,
        [workspaceId, threadId],
      );
      const winner = (existing.rows[0] as { session_uuid: string } | undefined)
        ?.session_uuid;
      if (!winner) {
        // Neither inserted nor present: the row was deleted between the two
        // statements. Fail loudly rather than invent a Session.
        throw new Error(
          `thread_session_map: lost the insert race for (${workspaceId}, ${threadId}) but no row is present`,
        );
      }
      return winner;
    },
  };
}

/**
 * Read a thread's current binding through any `query`-capable handle (the pool
 * for the lock-free resume path, or a checked-out client inside the mint txn).
 */
async function readBinding(
  q: (text: string, values?: unknown[]) => Promise<{ rows: unknown[] }>,
  workspaceId: string,
  threadId: string,
): Promise<string | null> {
  const { rows } = await q(
    `SELECT session_uuid
       FROM chat_bridge.thread_session_map
      WHERE workspace_id = $1 AND thread_id = $2`,
    [workspaceId, threadId],
  );
  return (rows[0] as { session_uuid: string } | undefined)?.session_uuid ?? null;
}

/**
 * The reserve-first, race-tight ThreadSessionMap: same interface as
 * {@link createThreadSessionMap}, but it closes the mint-race orphan
 * (`connectors-orphan-session-on-mint-race`).
 *
 * The plain {@link createPgThreadSessionStore} path mints BEFORE the insert, so
 * two inbound events for the same brand-new thread each mint a Barkpark Session
 * (POST /v1/chat/sessions always hands out a fresh UUID) and only one wins the
 * `ON CONFLICT DO NOTHING`. Correctness holds — both callers converge on the
 * winner's row — but the loser's Session is bound to nothing: a real leak of one
 * `chat_sessions` row, only ever on a thread's FIRST message.
 *
 * This factory serialises the mint under a per-thread transaction-scoped advisory
 * lock so exactly ONE racer ever calls `mint`:
 *
 *   1. Fast path — a lock-free read outside any transaction. The overwhelming
 *      common case is a RESUME (thread already bound); it must never pay for a
 *      checked-out connection or a lock.
 *   2. On a miss, check out one pool client and BEGIN.
 *   3. `pg_advisory_xact_lock(hashtext(workspace:thread))` — `hashtext` returns
 *      int4, which auto-promotes to the `bigint` overload (no cast needed). The
 *      lock is transaction-scoped: it releases at COMMIT/ROLLBACK, so the loser
 *      blocks HERE until the winner commits, then re-reads the winner's row.
 *   4. Re-read the binding inside the lock. If a racer already bound it, adopt
 *      that row and report `minted: false` — never mint.
 *   5. Still missing and holding the lock ⇒ we are the sole minter: mint, insert
 *      (no ON CONFLICT needed — the lock guarantees exclusivity), COMMIT.
 *
 * Accepted costs, all first-message-only:
 *   - `mint`'s HTTP round-trip (POST /v1/chat/sessions) runs while the advisory
 *     lock AND one pooled connection are held. That is deliberate: releasing the
 *     lock to mint would reopen the exact race this closes. A burst of >10 NEW
 *     threads at once queues on `pg.Pool` (max=10) until each mint returns — a
 *     first-contact-only backpressure, never on the hot resume path.
 *   - `hashtext` collisions merely over-serialise two unrelated threads that hash
 *     alike; they never bind the wrong Session, because step 4 keys the re-read on
 *     the exact (workspace_id, thread_id).
 *
 * The pool's `search_path=chat_bridge` pin is a libpq startup parameter
 * (pool.ts), so it holds for the manual BEGIN/COMMIT here exactly as it does for
 * pooled auto-commit queries.
 */
export function createPgLockedThreadSessionMap(pool: BridgePool): ThreadSessionMap {
  return {
    async get(workspaceId, threadId) {
      return readBinding((t, v) => pool.query(t, v), workspaceId, threadId);
    },

    async resolveOrMint(workspaceId, threadId, mint) {
      // Fast path: a lock-free read. A resume (already bound) is the common case
      // and must not check out a connection or take the lock.
      const existing = await readBinding(
        (t, v) => pool.query(t, v),
        workspaceId,
        threadId,
      );
      if (existing) return { sessionUuid: existing, minted: false };

      // Miss: serialise the mint under a per-thread advisory lock so exactly one
      // racer mints and the loser adopts the winner's row.
      const client = await pool.connect();
      try {
        await client.query("BEGIN");
        // hashtext($1) → int4 → auto-promotes to pg_advisory_xact_lock(bigint).
        // Transaction-scoped: released at COMMIT/ROLLBACK below.
        await client.query("SELECT pg_advisory_xact_lock(hashtext($1))", [
          `${workspaceId}:${threadId}`,
        ]);

        // Re-read INSIDE the lock. If we blocked behind a racer that already
        // bound the thread, adopt its Session and do NOT mint.
        const bound = await readBinding(
          (t, v) => client.query(t, v),
          workspaceId,
          threadId,
        );
        if (bound) {
          await client.query("COMMIT");
          return { sessionUuid: bound, minted: false };
        }

        // Still missing and we hold the lock ⇒ we are the sole minter.
        const fresh = await mint();
        await client.query(
          `INSERT INTO chat_bridge.thread_session_map (workspace_id, thread_id, session_uuid)
                VALUES ($1, $2, $3)`,
          [workspaceId, threadId, fresh],
        );
        await client.query("COMMIT");
        return { sessionUuid: fresh, minted: true };
      } catch (err) {
        try {
          await client.query("ROLLBACK");
        } catch {
          // A ROLLBACK can itself fail if the backend died mid-txn; the original
          // error is the one worth propagating.
        }
        throw err;
      } finally {
        client.release();
      }
    },
  };
}
