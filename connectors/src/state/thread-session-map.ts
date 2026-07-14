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
