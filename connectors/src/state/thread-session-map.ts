/**
 * The thread<->session map: the ONLY per-conversation state the bridge holds
 * (charter D28). It maps a channel's (workspace_id, thread_id) to a Barkpark
 * Session UUID (chat_sessions.id) — minted on the first message of a thread,
 * resumed on every message thereafter. Same-channel continuity falls out for
 * free; true cross-CHANNEL identity-linking is deferred to P4 (D31).
 *
 * Persistence is a bridge-OWNED `chat_bridge.thread_session_map` row, NOT
 * `thread.setState` — the Chat SDK's thread state hardcodes a 30-day TTL
 * (index.js:510), which would silently drop the Session of any dormant
 * conversation. A plain indexed table has no TTL and is explicit.
 */

import type { BridgePool } from "../db/pool.js";
import type { ChatClient } from "../chat-client/types.js";

interface SessionRow {
  session_uuid: string;
}

const SELECT_SQL =
  "SELECT session_uuid FROM thread_session_map WHERE workspace_id = $1 AND thread_id = $2";

// Insert-if-absent, race-safe: a concurrent first-message on the same thread
// loses the INSERT (ON CONFLICT DO NOTHING) and RETURNING comes back empty, so
// the caller re-reads the winner rather than clobbering it.
const UPSERT_SQL = `
INSERT INTO thread_session_map (workspace_id, thread_id, session_uuid)
VALUES ($1, $2, $3)
ON CONFLICT (workspace_id, thread_id) DO NOTHING
RETURNING session_uuid`;

export class ThreadSessionMap {
  constructor(
    private readonly pool: BridgePool,
    private readonly chat: ChatClient,
  ) {}

  /**
   * Return the Session UUID bound to (workspaceId, threadId), minting a new
   * Barkpark Session via the ChatClient the first time the pair is seen and
   * persisting the binding. Idempotent: every later call returns the SAME
   * UUID without minting again.
   */
  async resolveOrMint(workspaceId: string, threadId: string): Promise<string> {
    const found = await this.read(workspaceId, threadId);
    if (found !== null) {
      return found;
    }

    // First message on this thread — mint a fresh Session. /v1/chat derives the
    // workspace from the bearer token and always mints a NEW UUID (no
    // find-or-create), so idempotency is enforced here, by the map.
    const session = await this.chat.createSession();

    const claimed = await this.pool.query(UPSERT_SQL, [
      workspaceId,
      threadId,
      session.id,
    ]);
    if (claimed.rows.length > 0) {
      return (claimed.rows[0] as SessionRow).session_uuid;
    }

    // Lost a concurrent mint race: another caller already bound this thread.
    // The Session we just minted is orphaned (harmless); return the winner.
    const winner = await this.read(workspaceId, threadId);
    if (winner !== null) {
      return winner;
    }
    // Should be unreachable: the conflict implies a row exists.
    throw new Error(
      `thread_session_map: upsert conflicted but no row found for (${workspaceId}, ${threadId})`,
    );
  }

  private async read(
    workspaceId: string,
    threadId: string,
  ): Promise<string | null> {
    const result = await this.pool.query(SELECT_SQL, [workspaceId, threadId]);
    if (result.rows.length === 0) {
      return null;
    }
    return (result.rows[0] as SessionRow).session_uuid;
  }
}
