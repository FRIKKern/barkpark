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

export function useChatRollup(connection: InstanceConnection | undefined): ChatRollup | undefined {
  const [rollup, setRollup] = useState<ChatRollup | undefined>(undefined)

  useEffect(() => {
    if (connection === undefined) return
    let alive = true
    const load = async () => {
      try {
        const r = await fetchChatRollup(connection)
        if (alive) setRollup(r)
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

  // A disconnected app carries no badge (and a stale rollup from a previous
  // server never leaks across a reconnect).
  return connection === undefined ? undefined : rollup
}
