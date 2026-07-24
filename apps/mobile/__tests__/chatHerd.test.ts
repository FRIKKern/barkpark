// The frozen-clock herd proofs — the TS port of internal/chat/herd_test.go
// (herd charter D52h/D53h): roster laws, flip idempotence, the title-null
// design fact, heartbeat semantics, fresh-computed stall, and the attention
// sort — all pure functions over HerdState, no IO, no real clock.
import {
  applyFleetFrame,
  emptyHerd,
  HERD_STALL_AFTER_MS,
  herdFlip,
  herdHeartbeat,
  herdOrder,
  herdRank,
  herdSeed,
  herdSnapshot,
  herdStalled,
  type HerdState,
} from '../src/chat/herd'
import type { ChatSessionSummary } from '../src/chat/wire'

const t0 = Date.UTC(2026, 6, 13, 12, 0, 0)
const iso = (ms: number): string => new Date(ms).toISOString()

// The cold mount: the list roster maps in with agent_state/agent_state_at;
// missing agent_state mounts honestly as "unknown".
test('herdSeed cold-mounts from the list', () => {
  const list: ChatSessionSummary[] = [
    { id: 'a', title: 'Alpha', agent_state: 'working', agent_state_at: iso(t0) },
    { id: 'b', title: 'Beta' }, // old server: no agent_state
  ]
  const h = herdSeed(emptyHerd(), list)
  expect(h.rows.a?.agentState).toBe('working')
  expect(h.rows.a?.title).toBe('Alpha')
  expect(h.rows.a?.lastFlipAtMs).toBe(t0)
  expect(h.rows.b?.agentState).toBe('unknown')
})

// A re-list (an older point-in-time read) never regresses live truth: a row
// that saw a NEWER live flip keeps its live state; titles still refresh.
test('herdSeed never regresses live truth', () => {
  let h = herdSeed(emptyHerd(), [
    { id: 'a', title: 'Alpha', agent_state: 'idle', agent_state_at: iso(t0) },
  ])
  h = herdFlip(h, { session_id: 'a', agent_state: 'blocked', ts: iso(t0 + 60_000), title: null })

  // The stale list read (agent_state_at older than the live flip).
  h = herdSeed(h, [{ id: 'a', title: 'Fresh Title', agent_state: 'idle', agent_state_at: iso(t0) }])
  expect(h.rows.a?.agentState).toBe('blocked') // live truth kept
  expect(h.rows.a?.lastFlipAtMs).toBe(t0 + 60_000)
  expect(h.rows.a?.title).toBe('Fresh Title') // titles are list-sourced

  // A list read at least as fresh as the flip IS adopted.
  h = herdSeed(h, [{ id: 'a', agent_state: 'idle', agent_state_at: iso(t0 + 120_000) }])
  expect(h.rows.a?.agentState).toBe('idle')
})

// The D52h roster law: a (50-capped) snapshot overlays state but NEVER
// truncates the list-sourced roster.
test('herdSnapshot overlays, never truncates', () => {
  let h = herdSeed(emptyHerd(), [
    { id: 'a', agent_state: 'idle', agent_state_at: iso(t0) },
    { id: 'b', agent_state: 'idle', agent_state_at: iso(t0) },
    { id: 'c', agent_state: 'idle', agent_state_at: iso(t0) },
  ])
  h = herdSnapshot(h, [{ session_id: 'a', agent_state: 'working', ts: iso(t0 + 1000), title: null }])
  expect(h.rows.a?.agentState).toBe('working')
  expect(Object.keys(h.rows).sort()).toEqual(['a', 'b', 'c']) // b and c KEPT
})

// A double-emitted flip lands the identical row (idempotent upsert).
test('herdFlip is an idempotent upsert', () => {
  const flip = { session_id: 'a', agent_state: 'blocked', ts: iso(t0), title: 'T' }
  const once = herdFlip(emptyHerd(), flip)
  const twice = herdFlip(once, flip)
  expect(twice.rows.a).toEqual(once.rows.a)
})

// The D45h title law: live flips carry title:null BY DESIGN — nil means "keep
// what you hold", never "blank the title".
test('herdFlip null title keeps the held title', () => {
  let h = herdFlip(emptyHerd(), { session_id: 'a', agent_state: 'idle', ts: iso(t0), title: 'Held' })
  h = herdFlip(h, { session_id: 'a', agent_state: 'working', ts: iso(t0 + 1000), title: null })
  expect(h.rows.a?.title).toBe('Held')
  expect(h.rows.a?.agentState).toBe('working')
})

// The heartbeat rule: lastFrameAtMs bumps, agentState and lastFlipAtMs never
// move; an unknown session's heartbeat is ignored (the roster is
// list-sourced).
test('herdHeartbeat bumps lastFrameAt only', () => {
  let h = herdFlip(emptyHerd(), { session_id: 'a', agent_state: 'working', ts: iso(t0), title: null })
  h = herdHeartbeat(h, 'a', t0 + 30_000)
  expect(h.rows.a?.agentState).toBe('working')
  expect(h.rows.a?.lastFlipAtMs).toBe(t0)
  expect(h.rows.a?.lastFrameAtMs).toBe(t0 + 30_000)

  const before = h
  h = herdHeartbeat(h, 'ghost', t0 + 30_000)
  expect(h).toEqual(before) // unknown session ignored
})

// The D53h stall proof: working + no frame past the threshold wears the
// badge; any fresh frame un-stalls for free; only working can stall; a row
// with no timestamp cannot honestly be called stalled.
test('herd stall is computed fresh from frames', () => {
  let h = herdFlip(emptyHerd(), { session_id: 'a', agent_state: 'working', ts: iso(t0), title: null })
  const later = t0 + HERD_STALL_AFTER_MS + 1000
  expect(herdStalled(h.rows.a!, later)).toBe(true)

  // A heartbeat un-stalls without any state change.
  h = herdHeartbeat(h, 'a', later - 1000)
  expect(herdStalled(h.rows.a!, later)).toBe(false)

  // Only working stalls.
  const blocked = herdFlip(emptyHerd(), {
    session_id: 'b',
    agent_state: 'blocked',
    ts: iso(t0),
    title: null,
  })
  expect(herdStalled(blocked.rows.b!, later)).toBe(false)

  // No timestamp → never stalled.
  const bare = { sessionId: 'c', agentState: 'working', title: '', lastFlipAtMs: 0, lastFrameAtMs: 0 }
  expect(herdStalled(bare, later)).toBe(false)
})

// The sort law: blocked > stalled > working > idle > unknown > anything-else;
// within a band the freshest flip reads first; id asc breaks exact ties —
// fully deterministic.
test('herd attention sort', () => {
  const now = t0 + HERD_STALL_AFTER_MS + 60_000
  let h: HerdState = emptyHerd()
  h = herdFlip(h, { session_id: 'idle1', agent_state: 'idle', ts: iso(now - 1000), title: null })
  h = herdFlip(h, { session_id: 'blocked1', agent_state: 'blocked', ts: iso(now - 5000), title: null })
  h = herdFlip(h, { session_id: 'stalled1', agent_state: 'working', ts: iso(t0), title: null }) // no frames since t0 → stalled
  h = herdFlip(h, { session_id: 'working1', agent_state: 'working', ts: iso(now - 2000), title: null })
  h = herdFlip(h, { session_id: 'unknown1', agent_state: 'unknown', ts: iso(now - 500), title: null })
  h = herdFlip(h, { session_id: 'weird1', agent_state: 'wat', ts: iso(now), title: null })

  const roster = ['idle1', 'weird1', 'working1', 'unknown1', 'stalled1', 'blocked1']
  expect(herdOrder(h, roster, now)).toEqual([
    'blocked1',
    'stalled1',
    'working1',
    'idle1',
    'unknown1',
    'weird1',
  ])

  // Exact-tie determinism: same state, same flip time → id asc.
  let tie: HerdState = emptyHerd()
  tie = herdFlip(tie, { session_id: 'z', agent_state: 'idle', ts: iso(t0), title: null })
  tie = herdFlip(tie, { session_id: 'a', agent_state: 'idle', ts: iso(t0), title: null })
  expect(herdOrder(tie, ['z', 'a'], now)).toEqual(['a', 'z'])

  // A roster id the herd has never seen sorts last (rank 5), never throws.
  expect(herdOrder(h, ['ghost', 'blocked1'], now)).toEqual(['blocked1', 'ghost'])
  expect(herdRank({ sessionId: 'g', agentState: '', title: '', lastFlipAtMs: 0, lastFrameAtMs: 0 }, now)).toBe(5)
})

// The D45h wire shapes decode: snapshot / state / heartbeat; unknown events
// and malformed JSON are not herd-shaped (ok:false, state unchanged).
test('applyFleetFrame parses the three shapes', () => {
  const snap = applyFleetFrame(
    emptyHerd(),
    'snapshot',
    JSON.stringify({
      sessions: [{ session_id: 'a', agent_state: 'working', ts: iso(t0), title: 'Alpha' }],
    }),
  )
  expect(snap.ok).toBe(true)
  expect(snap.state.rows.a?.agentState).toBe('working')
  expect(snap.state.rows.a?.title).toBe('Alpha')

  const flip = applyFleetFrame(
    snap.state,
    'state',
    JSON.stringify({ session_id: 'a', agent_state: 'blocked', ts: iso(t0 + 1000), title: null }),
  )
  expect(flip.ok).toBe(true)
  expect(flip.state.rows.a?.agentState).toBe('blocked')

  const beat = applyFleetFrame(
    flip.state,
    'heartbeat',
    JSON.stringify({ session_id: 'a', ts: iso(t0 + 2000) }),
  )
  expect(beat.ok).toBe(true)
  expect(beat.state.rows.a?.lastFrameAtMs).toBe(t0 + 2000)
  expect(beat.state.rows.a?.agentState).toBe('blocked')

  // Not herd-shaped: unknown event, malformed JSON, missing session_id.
  expect(applyFleetFrame(beat.state, 'title', '{}').ok).toBe(false)
  expect(applyFleetFrame(beat.state, 'state', 'not json').ok).toBe(false)
  expect(applyFleetFrame(beat.state, 'state', '{"agent_state":"idle"}').ok).toBe(false)
  expect(applyFleetFrame(beat.state, 'heartbeat', '{"ts":"2026-01-01T00:00:00Z"}').ok).toBe(false)
})
