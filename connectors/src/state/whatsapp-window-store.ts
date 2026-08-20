/**
 * The production WhatsappWindowStore: the bridge-owned `chat_bridge.whatsapp_window`.
 *
 * Behind the interface declared in policy/whatsapp-window.ts, this replaces the
 * in-memory store's restart amnesia with a durable row. The in-memory store reads
 * every window as `no-inbound-recorded` (CLOSED) after a restart — the SAFE direction,
 * but it silently refuses a proactive/scheduled send after every deploy. This store
 * keeps the last-inbound-at across restarts so a business-initiated free-form send is
 * still allowed when Meta's 24h window is genuinely open.
 *
 * STORE-ONLY (charter D169): this ships the durable store and its table. Recording the
 * inbound timestamp from the webhook seam (index.ts/dispatch.ts/whatsapp.ts) is a
 * separate, sequenced slice (`connectors-whatsapp-window-wiring`); until it lands the
 * store is real but not yet fed.
 *
 * Schema-QUALIFIED on purpose, exactly as createPgThreadSessionStore is: the pool's
 * search_path pin exists to corral state-pg's unqualified DDL, and the bridge's own SQL
 * must not quietly depend on it. Qualifying here means a drifted search_path can never
 * silently point our reads and writes at a different schema's table.
 */

import type { BridgePool } from "../db/pool.js";
import type { WhatsappWindowStore } from "../policy/whatsapp-window.js";

export function createPgWhatsappWindowStore(pool: BridgePool): WhatsappWindowStore {
  return {
    async getLastInboundAt(workspaceId, threadId) {
      const { rows } = await pool.query(
        `SELECT last_inbound_at
           FROM chat_bridge.whatsapp_window
          WHERE workspace_id = $1 AND thread_id = $2`,
        [workspaceId, threadId],
      );
      // pg returns bigint as a string; a genuine miss is null, never NaN.
      const raw = (
        rows[0] as { last_inbound_at: string | number | null } | undefined
      )?.last_inbound_at;
      return raw === undefined || raw === null ? null : Number(raw);
    },

    async recordInbound(workspaceId, threadId, atMs) {
      // Monotonic upsert: an out-of-order webhook (a late-delivered EARLIER inbound)
      // must never move the window backwards. GREATEST keeps the max of the proposed
      // row and the existing one, so only a genuinely newer inbound advances it — the
      // same guarantee the in-memory store enforces with its `existing >= atMs` guard.
      await pool.query(
        `INSERT INTO chat_bridge.whatsapp_window (workspace_id, thread_id, last_inbound_at)
              VALUES ($1, $2, $3)
         ON CONFLICT (workspace_id, thread_id) DO UPDATE
            SET last_inbound_at =
                  GREATEST(excluded.last_inbound_at, whatsapp_window.last_inbound_at)`,
        [workspaceId, threadId, atMs],
      );
    },
  };
}
