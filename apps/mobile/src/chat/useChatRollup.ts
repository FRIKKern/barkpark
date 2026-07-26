// The tab-bar needs-you badge feed — GET /v1/chat/rollup (herd charter D64h:
// agent_state counts + one precedence state, DB-scoped to the token's
// workspace floor). The badge number is counts.blocked: blocked sessions are
// the ones waiting on a human. Polled — the rollup is the aggregate twin of
// the fleet stream, and a poll is the honest floor for a tab badge (no
// stream to hold open from a background tab).
import { useEffect, useState } from 'react'

import type { InstanceConnection } from '../api/instance'
import { fetchChatRollup } from '../api/chat'
import type { ChatRollup } from './wire'

const POLL_MS = 60_000

/** A fetched rollup remembers WHICH connection it came from. */
interface RollupEntry {
  connection: InstanceConnection
  rollup: ChatRollup
}

/** Identity-keyed truth (polish AC4b), pure so it is jest-provable: a rollup
 * fetched from one connection is not another connection's badge — on a
 * connection change the badge disappears IMMEDIATELY (same render, no effect
 * timing window) and returns only when the new server's rollup lands. */
export function rollupFor(
  connection: InstanceConnection | undefined,
  entry: RollupEntry | undefined,
): ChatRollup | undefined {
  return connection !== undefined && entry !== undefined && entry.connection === connection
    ? entry.rollup
    : undefined
}

export function useChatRollup(connection: InstanceConnection | undefined): ChatRollup | undefined {
  const [entry, setEntry] = useState<RollupEntry | undefined>(undefined)

  useEffect(() => {
    if (connection === undefined) return
    let alive = true
    const load = async () => {
      try {
        const r = await fetchChatRollup(connection)
        if (alive) setEntry({ connection, rollup: r })
      } catch {
        // Honest degrade: keep the last-known badge; a dead rollup never
        // takes the tab bar down with it.
      }
    }
    void load()
    const timer = setInterval(() => void load(), POLL_MS)
    return () => {
      alive = false
      clearInterval(timer)
    }
  }, [connection])

  // A disconnected app carries no badge, and a stale rollup from a previous
  // connection never survives a reconnect — the entry is keyed to the
  // connection identity it was fetched from.
  return rollupFor(connection, entry)
}
