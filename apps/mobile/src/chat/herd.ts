// The PURE herd reducer — the TypeScript port of internal/chat/herd.go
// (herd charter D52h): the sessions-list home screen's state machine, a
// sibling of reducer.ts that is deliberately NOT part of the single-session
// turn machine. Every rule is a named, frozen-clock-testable function over
// HerdState — the shell only parses wire frames (applyFleetFrame) and calls
// these; no IO, no real clock.
//
// The wire this reduces is the fleet stream (GET /v1/chat/events) plus the
// cold sessions list (GET /v1/chat/sessions, which carries agent_state /
// agent_state_at). Named wire residuals, each its own rule + test:
//
//   - a fleet SNAPSHOT overlays state but NEVER truncates the list-sourced
//     roster (the snapshot is 50-capped; the cold list is the full roster);
//   - FLIPS are idempotent upserts (a double-emitted flip is harmless);
//   - a NULL live-flip title keeps the held title (flips carry title:null by
//     design — the snapshot/list title is the one worth keeping);
//   - HEARTBEATS bump lastFrameAtMs only — never agentState, never
//     lastFlipAtMs;
//   - STALL is computed FRESH from lastFrameAtMs at sort/render time (D53h):
//     a fresh frame un-stalls for free, and there is no stored bool to go
//     stale.
import type { ChatSessionSummary } from './wire'

// The herd stall threshold (charter D53h): a WORKING session with no frame
// (flip or heartbeat) for this long wears the stall badge. 150s = 2.5× the
// server's 60s heartbeat.
export const HERD_STALL_AFTER_MS = 150_000

/** One session's herd truth: its four-state agent_state
 * (working|blocked|idle|unknown), the held title, and the two clocks the sort
 * and the stall badge read — lastFlipAtMs (the last STATE CHANGE, the
 * tie-break) and lastFrameAtMs (the last sign of life: flips AND heartbeats).
 * 0 means "no timestamp seen" (the Go zero time). */
export interface HerdRow {
  sessionId: string
  agentState: string
  title: string
  lastFlipAtMs: number
  lastFrameAtMs: number
}

/** The pure herd truth: rows keyed by session id. (The Go cursor field is a
 * keyboard-navigation concern the touch UI does not carry.) */
export interface HerdState {
  rows: Record<string, HerdRow>
}

export function emptyHerd(): HerdState {
  return { rows: {} }
}

/** Parses the wire's ISO8601 ts; 0 on failure (honest blank — the row still
 * sorts, it just carries no age). */
export function parseHerdTime(iso: string | undefined): number {
  if (iso === undefined || iso === '') return 0
  const t = Date.parse(iso)
  return Number.isNaN(t) ? 0 : t
}

// ── wire frame parsing ───────────────────────────────────────────────────────

interface FleetStateFrame {
  session_id?: string
  agent_state?: string
  ts?: string
  title?: string | null
}

/** Parses one fleet-stream frame (event name + data string) and reduces it.
 * `ok:false` means the frame was not herd-shaped (unknown event, malformed
 * JSON) — the caller ignores it. */
export function applyFleetFrame(
  h: HerdState,
  event: string,
  data: string,
): { state: HerdState; ok: boolean } {
  let parsed: unknown
  try {
    parsed = JSON.parse(data)
  } catch {
    return { state: h, ok: false }
  }
  if (parsed === null || typeof parsed !== 'object') return { state: h, ok: false }
  const obj = parsed as Record<string, unknown>

  switch (event) {
    case 'snapshot': {
      const sessions = Array.isArray(obj.sessions) ? (obj.sessions as FleetStateFrame[]) : undefined
      if (sessions === undefined) return { state: h, ok: false }
      return { state: herdSnapshot(h, sessions), ok: true }
    }
    case 'state': {
      const f = obj as FleetStateFrame
      if (typeof f.session_id !== 'string' || f.session_id === '') return { state: h, ok: false }
      return { state: herdFlip(h, f), ok: true }
    }
    case 'heartbeat': {
      const sid = obj.session_id
      if (typeof sid !== 'string' || sid === '') return { state: h, ok: false }
      const ts = typeof obj.ts === 'string' ? obj.ts : undefined
      return { state: herdHeartbeat(h, sid, parseHerdTime(ts)), ok: true }
    }
  }
  return { state: h, ok: false }
}

// ── the named reducer rules ──────────────────────────────────────────────────

/** Cold-mounts the herd from the sessions list. The list is the ROSTER —
 * every summary gets a row — but live truth wins: a row that already saw a
 * LIVE flip newer than the list's agent_state_at keeps its live state (the
 * list is a point-in-time read; the stream is fresher). A summary with no
 * agent_state (an old server) mounts honestly as "unknown". Titles are
 * list-sourced (flips carry title:null), so a non-empty list title always
 * refreshes the held one. */
export function herdSeed(h: HerdState, sessions: ChatSessionSummary[]): HerdState {
  const rows = { ...h.rows }
  for (const s of sessions) {
    const state = s.agent_state !== undefined && s.agent_state !== '' ? s.agent_state : 'unknown'
    const at = parseHerdTime(s.agent_state_at)
    let row = rows[s.id]
    if (row === undefined) {
      row = { sessionId: s.id, agentState: state, title: '', lastFlipAtMs: at, lastFrameAtMs: at }
    } else if (row.lastFlipAtMs <= at) {
      // the list read is at least as fresh as the last live flip → adopt it
      row = {
        ...row,
        agentState: state,
        lastFlipAtMs: at,
        lastFrameAtMs: Math.max(row.lastFrameAtMs, at),
      }
    } else {
      row = { ...row }
    }
    const t = trimTitle(s.title)
    if (t !== '') row.title = t
    rows[s.id] = row
  }
  return { rows }
}

/** Overlays a fleet snapshot: every listed session is upserted with the
 * server's current state, but rows NOT in the snapshot are KEPT — the snapshot
 * is 50-capped and must never truncate the list-sourced roster (D52h). */
export function herdSnapshot(h: HerdState, sessions: FleetStateFrame[]): HerdState {
  let out = h
  for (const s of sessions) {
    if (typeof s.session_id !== 'string' || s.session_id === '') continue
    out = herdFlip(out, s)
  }
  return out
}

/** Upserts one state flip. Idempotent by construction: re-applying the same
 * flip lands the identical row. A null (wire-null) or empty title keeps the
 * held title — the flip frame's title:null is a design fact, not an erase
 * instruction. lastFlipAtMs and lastFrameAtMs both advance to the flip's ts
 * (a flip IS a frame). */
export function herdFlip(h: HerdState, f: FleetStateFrame): HerdState {
  const sid = f.session_id ?? ''
  const ts = parseHerdTime(f.ts)
  const prev = h.rows[sid]
  const row: HerdRow =
    prev !== undefined
      ? { ...prev }
      : { sessionId: sid, agentState: '', title: '', lastFlipAtMs: 0, lastFrameAtMs: 0 }
  row.agentState = f.agent_state ?? ''
  row.lastFlipAtMs = ts
  if (ts > row.lastFrameAtMs) row.lastFrameAtMs = ts
  if (f.title !== null && f.title !== undefined) {
    const t = trimTitle(f.title)
    if (t !== '') row.title = t
  }
  return { rows: { ...h.rows, [sid]: row } }
}

/** Bumps lastFrameAtMs ONLY — never agentState, never lastFlipAtMs (charter
 * D41h: the tick proves a long tool call is not a dead runtime; it is not a
 * state change). A heartbeat for a session the herd does not hold is ignored —
 * the roster is list-sourced. */
export function herdHeartbeat(h: HerdState, sessionId: string, tsMs: number): HerdState {
  const prev = h.rows[sessionId]
  if (prev === undefined) return h
  const row = { ...prev }
  if (tsMs > row.lastFrameAtMs) row.lastFrameAtMs = tsMs
  return { rows: { ...h.rows, [sessionId]: row } }
}

/** The D53h stall badge, computed FRESH from lastFrameAtMs at sort/render
 * time — never a stored bool. Only a WORKING session can stall (blocked is
 * waiting on a human; idle/unknown carry no promise of frames), and a row
 * that never saw a timestamp cannot honestly be called stalled. */
export function herdStalled(row: HerdRow, nowMs: number): boolean {
  return (
    row.agentState === 'working' &&
    row.lastFrameAtMs !== 0 &&
    nowMs - row.lastFrameAtMs > HERD_STALL_AFTER_MS
  )
}

/** The attention sort's rank: blocked(0) > stalled(1) > working(2) > idle(3)
 * > unknown(4) > anything-else(5). Unknown ranks BELOW idle — it carries no
 * live signal and nothing actionable. Unknown wire values sort last
 * (forward-compat, never a crash). */
export function herdRank(row: HerdRow, nowMs: number): number {
  if (row.agentState === 'blocked') return 0
  if (herdStalled(row, nowMs)) return 1
  if (row.agentState === 'working') return 2
  if (row.agentState === 'idle') return 3
  if (row.agentState === 'unknown') return 4
  return 5
}

/** Resolves the herd row for a session id — a zero row (state ''), never a
 * throw, when the herd holds nothing for it. */
export function herdRowFor(h: HerdState, id: string): HerdRow {
  return (
    h.rows[id] ?? { sessionId: id, agentState: '', title: '', lastFlipAtMs: 0, lastFrameAtMs: 0 }
  )
}

/** Sorts the given roster ids by attention (charter D52h): rank asc, then
 * lastFlipAtMs DESC (the freshest flip reads first within a band), then
 * session id asc — fully deterministic, so equal-state rows never jitter. The
 * roster is the caller's (list-sourced) id set; the herd only supplies each
 * id's row. */
export function herdOrder(h: HerdState, roster: string[], nowMs: number): string[] {
  return [...roster].sort((a, b) => {
    const ra = herdRowFor(h, a)
    const rb = herdRowFor(h, b)
    const ka = herdRank(ra, nowMs)
    const kb = herdRank(rb, nowMs)
    if (ka !== kb) return ka - kb
    if (ra.lastFlipAtMs !== rb.lastFlipAtMs) return rb.lastFlipAtMs - ra.lastFlipAtMs
    return a < b ? -1 : a > b ? 1 : 0
  })
}

/** Shared title normalisation (blank-ish titles never overwrite a held one). */
function trimTitle(s: string | undefined): string {
  return (s ?? '').trim()
}
