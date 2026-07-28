// The tab-bar needs-you badge feed — GET /v1/chat/rollup (herd charter D64h:
// agent_state counts + one precedence state, DB-scoped to the token's
// workspace floor). The badge number is counts.blocked: blocked sessions are
// the ones waiting on a human. Polled — the rollup is the aggregate twin of
// the fleet stream, and a poll is the honest floor for a tab badge (no
// stream to hold open from a background tab).
//
// FRESHNESS IS PART OF THE FEED (last-mile wave): a poll that fails keeps the
// last-known count on screen, which is right — a dead rollup must not take the
// tab bar down with it — but painting that count identically to one fetched a
// second ago is the app claiming state it never confirmed. So the hook returns
// a FEED, not a bare rollup: the count plus how many consecutive polls have
// failed and how old the last confirmed answer is, and the badge paints
// differently once the app can no longer vouch for the number.
//
// MEASURED CLIENT-SIDE, deliberately: GET /v1/chat/rollup carries only counts
// and precedence (no timestamp) and api/chat.ts discards response.headers, so
// even the HTTP Date is out of reach. The clock that matters here is anyway the
// client's — "when did THIS app last hear back" — so no server field is needed
// and none is added.
import { useEffect, useRef, useState } from 'react'

import type { InstanceConnection } from '../api/instance'
import { fetchChatRollup } from '../api/chat'
import type { ChatRollup } from './wire'

export const POLL_MS = 60_000

/**
 * How many poll periods the badge may go unconfirmed before it stops claiming
 * to be current — as a COUNT OF POLLS, so the promise the badge makes is tied
 * to the poll rate rather than to a wall-clock number chosen next to it.
 *
 * Two, and it is a product choice nobody has ratified. One missed poll is a
 * blip — a radio waking up, a request that lost a race with a screen lock —
 * and the count is then at most one period old, which is inside the promise a
 * 60s poll already makes. Two consecutive misses mean the number on the tab bar
 * is at least two minutes old AND the app has failed to confirm it twice; at
 * that point "3 sessions need you" is a claim, not a reading.
 */
export const STALE_AFTER_POLLS = 2

/** Whether the app can still vouch for the number it is painting. */
export type BadgeFreshness = 'confirmed' | 'unconfirmed'

/** What the shell feeds the tab bar: the count AND what is known about it. */
export interface RollupFeed {
  /** The last rollup fetched from THIS connection, if any. */
  rollup?: ChatRollup
  freshness: BadgeFreshness
  /** ms since the last confirmed rollup; undefined when none ever landed. */
  ageMs?: number
  /** Consecutive failed polls since the last confirmed rollup. */
  failures: number
}

/** The freshness rule, pure so it is jest-provable and mutation-checkable.
 *
 * Two independent ways to go unconfirmed, and both are needed: failed polls
 * catch a server that answers with errors, elapsed age catches a poll that
 * never ran at all (a suspended app whose interval was frozen reports zero
 * failures while its number quietly rots). */
export function badgeFreshness(failures: number, ageMs: number | undefined): BadgeFreshness {
  if (failures >= STALE_AFTER_POLLS) return 'unconfirmed'
  if (ageMs !== undefined && ageMs >= STALE_AFTER_POLLS * POLL_MS) return 'unconfirmed'
  return 'confirmed'
}

/** A fetched rollup remembers WHICH connection it came from. */
interface RollupEntry {
  connection: InstanceConnection
  rollup: ChatRollup
}

/** Poll bookkeeping, keyed to the connection its numbers describe — another
 * server's failure count is not this server's doubt. */
interface RollupState {
  connection?: InstanceConnection
  entry?: RollupEntry
  failures: number
  lastOkMs?: number
}

const EMPTY: RollupState = { failures: 0 }

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

export function useChatRollup(
  connection: InstanceConnection | undefined,
  now: () => number = Date.now,
): RollupFeed {
  const [state, setState] = useState<RollupState>(EMPTY)

  // The clock is a seam for tests, NOT a dependency: putting it in the effect's
  // deps would re-key the poll on every render that passes an inline function —
  // the same re-subscription trap `connection`'s memo exists to avoid.
  const nowRef = useRef(now)
  nowRef.current = now

  useEffect(() => {
    if (connection === undefined) return
    let alive = true
    const load = async () => {
      try {
        const r = await fetchChatRollup(connection)
        // A confirmed answer resets the doubt: fresh entry, zero failures,
        // and the clock the age is measured from.
        if (alive) {
          setState({
            connection,
            entry: { connection, rollup: r },
            failures: 0,
            lastOkMs: nowRef.current(),
          })
        }
      } catch {
        // Honest degrade — the last-known badge stays, but it stops passing
        // for a reading: every dead poll is counted, and past the threshold
        // the badge says so on screen (TabBar's unconfirmed paint).
        if (alive) {
          setState((prev) =>
            prev.connection === connection
              ? { ...prev, failures: prev.failures + 1 }
              : { connection, failures: 1 },
          )
        }
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
  // connection identity it was fetched from. The bookkeeping is keyed the same
  // way, so a server switch starts from no count AND no inherited doubt.
  const rollup = rollupFor(connection, state.entry)
  const mine = connection !== undefined && state.connection === connection
  const failures = mine ? state.failures : 0
  // Recomputed at RENDER time, not at poll time, so age is what it is now —
  // a resumed app whose interval was frozen re-reads the clock on its first
  // paint rather than trusting the number the freeze left behind.
  const ageMs = mine && state.lastOkMs !== undefined ? Math.max(0, now() - state.lastOkMs) : undefined

  return { rollup, freshness: badgeFreshness(failures, ageMs), ageMs, failures }
}
