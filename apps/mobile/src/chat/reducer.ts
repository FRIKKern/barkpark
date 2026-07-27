// The PURE chat session state machine — the TypeScript port of the Go TUI's
// internal/chat/reduce.go (charter D17: parity where the Go semantics are
// load-bearing, idiomatic TS otherwise). Every SSE frame, user intent, and
// fetch result flows through reduce(state, event, nowMs) → { state, effects };
// the React shell only translates UI events into ChatEvents and executes
// ChatEffects as IO. Purity is the test seam: the acceptance criteria (D11
// interrupt truth, D12 queued steer, D8 tail settling, the D77 settle race)
// are all proven by driving reduce with recorded frame shapes — no device, no
// server, no clock.
//
// Deliberate deltas from reduce.go:
//   - D77 settle-race generation token is BUILT IN (the Go fix ships as its
//     own slice `ct-bl-tail-settle-gen`): `gen` increments per init frame,
//     `tailGen` stamps delta appends, fetch-tail effects/events carry the
//     issuing gen, and the tail-clear guard is `ev.gen === st.tailGen` — a
//     stale turn-1 refetch can never clear (or duplicate into) a streaming
//     turn-2 tail.
//   - Rail / workflow mission-control state (Rail, Workflow, LiveWorkflow) is
//     not ported: that richness stays a TUI+Studio surface this wave. The
//     `workflow` SSE frame is inert here (forward-compatible), like every
//     unknown frame.
import type { ChatMessage, ChatSession } from './wire'
import { approvalStatus, requestId } from './wire'

// The client-OWNED interrupt wedge (charter D11): if the terminal result frame
// never arrives within 8s of the interrupt, the client force-degrades locally
// instead of wedging in "interrupting…" forever.
export const WEDGE_TIMEOUT_MS = 8_000

/** Where the session's current turn stands, from the client's point of view.
 * The server does not carry this state (charter D12) — it is derived from the
 * frames we've seen. */
export type TurnPhase = 'idle' | 'waiting' | 'streaming' | 'interrupting'

/** An optimistic local echo of an outgoing user message — shown immediately,
 * badged queued while another turn is streaming (charter D12), and dropped
 * once the turn-boundary refetch returns its persisted row. */
export interface LocalSend {
  content: string
  queued: boolean
}

/** The whole reducible session state. `messages` are settled Postgres truth;
 * `tail` is the live-delta carve-out (charter D9); everything else is
 * client-derived turn/queue/notice state. */
export interface ChatState {
  sessionId: string
  title: string
  messages: ChatMessage[]
  lastSeq: number

  /** The OBSERVED wire model id off the system/init frame — fact, empty until
   * the first turn streams. */
  model: string
  /** The session's permission mode for DISPLAY: seeded from the session GET,
   * refreshed at every turn boundary and by the init frame's permissionMode. */
  mode: string

  phase: TurnPhase
  tail: string
  settling: boolean
  local: LocalSend[]
  /** interrupt wedge deadline, ms epoch (0 unless interrupting) */
  wedgeAtMs: number

  /** D77: the turn generation — incremented by every system/init frame. */
  gen: number
  /** D77: the generation the current tail's deltas belong to. */
  tailGen: number

  /** request_id → decision ("allow"/"deny") POSTed but not yet confirmed by a
   * refetch — the immediate-feedback layer. */
  answerInFlight: Record<string, string>

  notice: string
  exited: boolean
}

export function initialChatState(sessionId: string): ChatState {
  return {
    sessionId,
    title: '',
    messages: [],
    lastSeq: 0,
    model: '',
    mode: '',
    phase: 'idle',
    tail: '',
    settling: false,
    local: [],
    wedgeAtMs: 0,
    gen: 0,
    tailGen: 0,
    answerInFlight: {},
    notice: '',
    exited: false,
  }
}

// ── events ───────────────────────────────────────────────────────────────────

/** One SSE frame off the events stream (event name + raw data string). */
export type FrameEvent = { type: 'frame'; name: string; data: string }
/** The user submitting a non-empty composer. */
export type SendEvent = { type: 'send'; content: string }
/** The user tapping Stop/interrupt. */
export type InterruptEvent = { type: 'interrupt' }
/** The heartbeat — the wedge timer's clock. */
export type TickEvent = { type: 'tick' }
/** The turn-boundary GET landing. `gen` echoes the issuing FetchTailEffect's
 * gen (D77) — the guard deciding whether this fetch settles the painted tail. */
export type TailFetchedEvent = {
  type: 'tailFetched'
  gen: number
  session?: ChatSession
  error?: string
}
/** The user answering the focused card (charter D27/D28): decision is
 * "allow" or "deny" ONLY. */
export type AnswerEvent = { type: 'answer'; requestId: string; decision: string }
/** The answer POST completing. */
export type AnsweredEvent = { type: 'answered'; requestId: string; error?: string }

export type ChatEvent =
  | FrameEvent
  | SendEvent
  | InterruptEvent
  | TickEvent
  | TailFetchedEvent
  | AnswerEvent
  | AnsweredEvent

// ── effects ──────────────────────────────────────────────────────────────────

/** GET the session with ?since=sinceSeq. sinceSeq 0 is a FULL refetch (an
 * in-place metadata flip like a resolved approval is picked up); positive
 * returns only newer rows. `gen` is the issuing turn generation (D77) — echo
 * it back on the TailFetchedEvent. */
export type FetchTailEffect = { type: 'fetchTail'; sinceSeq: number; gen: number }
export type SendEffect = { type: 'sendMessage'; content: string }
export type InterruptEffect = { type: 'interruptTurn' }
export type AnswerEffect = { type: 'answerCard'; requestId: string; decision: string }

export type ChatEffect = FetchTailEffect | SendEffect | InterruptEffect | AnswerEffect

export interface ReduceResult {
  state: ChatState
  effects: ChatEffect[]
}

// ── the transition function ──────────────────────────────────────────────────

/** The single transition function. Never blocks, never does IO, and never
 * throws on malformed frames — an unknown or unparseable frame is simply
 * inert (forward-compatible, same tolerance as the Go decoder). */
export function reduce(st: ChatState, ev: ChatEvent, nowMs: number): ReduceResult {
  switch (ev.type) {
    case 'frame':
      return reduceFrame(st, ev)
    case 'send':
      return reduceSend(st, ev)
    case 'interrupt':
      return reduceInterrupt(st, nowMs)
    case 'tick':
      return reduceTick(st, nowMs)
    case 'tailFetched':
      return reduceTailFetched(st, ev)
    case 'answer':
      return reduceAnswer(st, ev)
    case 'answered':
      return reduceAnswered(st, ev)
  }
}

const none: ChatEffect[] = []

// Records the in-flight decision (immediate feedback) and emits the POST.
// No-op for a blank request_id or a decision other than allow/deny (the scope
// fence, charter D28). The card's terminal flip is server truth, arriving on
// the AnsweredEvent's full refetch — never guessed locally, so a Studio answer
// and a mobile answer converge on the SAME row.
function reduceAnswer(st: ChatState, ev: AnswerEvent): ReduceResult {
  if (ev.requestId === '' || (ev.decision !== 'allow' && ev.decision !== 'deny')) {
    return { state: st, effects: none }
  }
  let notice = ev.decision === 'deny' ? 'denying…' : 'allowing…'
  // An approved plan card is the autopilot promise: say so now — the badge
  // lands on truth at the turn boundary / next init frame.
  if (ev.decision === 'allow') {
    for (const msg of st.messages) {
      if (requestId(msg) === ev.requestId && msg.role === 'plan') {
        notice = 'Plan approved — engaging ▶ Autopilot…'
        break
      }
    }
  }
  return {
    state: {
      ...st,
      answerInFlight: { ...st.answerInFlight, [ev.requestId]: ev.decision },
      notice,
    },
    effects: [{ type: 'answerCard', requestId: ev.requestId, decision: ev.decision }],
  }
}

// The answer POST completing. A transport error clears the in-flight badge and
// surfaces honestly (the card stays pending — retryable). On success it fires
// a FULL refetch (sinceSeq 0) so the resolved row's in-place metadata flip
// lands; the in-flight badge lingers until that refetch confirms the terminal
// status (reduceTailFetched drops it).
function reduceAnswered(st: ChatState, ev: AnsweredEvent): ReduceResult {
  if (ev.error !== undefined) {
    const inFlight = { ...st.answerInFlight }
    delete inFlight[ev.requestId]
    return {
      state: { ...st, answerInFlight: inFlight, notice: `answer failed — ${ev.error}` },
      effects: none,
    }
  }
  return {
    state: { ...st, settling: true },
    effects: [{ type: 'fetchTail', sinceSeq: 0, gen: st.gen }],
  }
}

// Appends the optimistic echo and always POSTs immediately — the server does
// not distinguish queued (charter D12); the queued badge is pure local turn
// state. A send during an active turn stays badged until the NEXT system/init
// frame proves a fresh turn started.
function reduceSend(st: ChatState, ev: SendEvent): ReduceResult {
  const content = ev.content.trim()
  if (content === '') return { state: st, effects: none }
  const midTurn = st.phase !== 'idle'
  return {
    state: {
      ...st,
      local: [...st.local, { content, queued: midTurn }],
      phase: midTurn ? st.phase : 'waiting',
      notice: '',
    },
    effects: [{ type: 'sendMessage', content }],
  }
}

// Charter D11: interrupt with no active turn is a SILENT no-op. With a turn
// active it flips to "interrupting" immediately — the control ack is
// semantically empty, so there is nothing to wait for — and arms the client's
// own 8s wedge timer. The truth arrives as the result frame.
function reduceInterrupt(st: ChatState, nowMs: number): ReduceResult {
  if (st.phase === 'idle') return { state: st, effects: none }
  if (st.phase === 'interrupting') {
    return { state: st, effects: none } // already asked; the wedge timer owns escalation
  }
  return {
    state: {
      ...st,
      phase: 'interrupting',
      wedgeAtMs: nowMs + WEDGE_TIMEOUT_MS,
      notice: 'interrupting…',
    },
    effects: [{ type: 'interruptTurn' }],
  }
}

// Fires the wedge: silence past the deadline force-degrades LOCALLY (charter
// D11) — the turn is declared over for this client, honestly labelled, and the
// session stays usable. If the server-side turn is in fact still running, the
// next frame or refetch re-syncs us.
function reduceTick(st: ChatState, nowMs: number): ReduceResult {
  if (st.phase === 'interrupting' && st.wedgeAtMs !== 0 && nowMs >= st.wedgeAtMs) {
    return {
      state: {
        ...st,
        phase: 'idle',
        wedgeAtMs: 0,
        settling: true,
        notice: 'interrupt unacknowledged after 8s — degraded locally; refetching',
      },
      effects: [{ type: 'fetchTail', sinceSeq: st.lastSeq, gen: st.gen }],
    }
  }
  return { state: st, effects: none }
}

function parseJson(data: string): Record<string, unknown> | undefined {
  try {
    const v: unknown = JSON.parse(data)
    return v !== null && typeof v === 'object' ? (v as Record<string, unknown>) : undefined
  } catch {
    return undefined
  }
}

// Dispatches one SSE frame.
function reduceFrame(st: ChatState, ev: FrameEvent): ReduceResult {
  switch (ev.name) {
    case 'message': {
      // Replay phase: a persisted row (reconnect catch-up). Same merge rule as
      // the tail refetch — seq must advance.
      const obj = parseJson(ev.data)
      if (obj === undefined) return { state: st, effects: none }
      const m = obj as unknown as ChatMessage
      if (typeof m.seq !== 'number' || m.seq <= st.lastSeq) return { state: st, effects: none }
      return {
        state: {
          ...st,
          messages: [...st.messages, m],
          lastSeq: m.seq,
          local: dropSettledLocal(st.local, [m]),
        },
        effects: none,
      }
    }
    case 'chat':
      return reduceClaudeFrame(st, ev.data)
    case 'permission':
      // The ask row is persisted by the Recorder — refetch the tail so the
      // answerable card renders from replay truth (request_id + pending status
      // in its metadata).
      return {
        state: { ...st, settling: true },
        effects: [{ type: 'fetchTail', sinceSeq: st.lastSeq, gen: st.gen }],
      }
    case 'exit': {
      // The public exit frame is EXACTLY {status, reason} (charter D23):
      // status is null for a non-integer exit (crash/reap); reason carries the
      // honest cause the notice surfaces.
      const obj = parseJson(ev.data) ?? {}
      const status = typeof obj.status === 'number' ? obj.status : null
      const reason = typeof obj.reason === 'string' ? obj.reason : ''
      return {
        state: {
          ...st,
          exited: true,
          phase: 'idle',
          wedgeAtMs: 0,
          notice: exitNotice(status, reason),
        },
        effects: none,
      }
    }
  }
  return { state: st, effects: none }
}

// Handles one raw claude stream-json frame (event: chat). Shapes mirror what
// reduce.go consumes — init, text deltas, and the terminal result. Everything
// else (thinking pulses, tool chatter, task_* system frames) is inert for the
// transcript: those rows arrive as persisted truth at the turn boundary.
function reduceClaudeFrame(st: ChatState, data: string): ReduceResult {
  const frame = parseJson(data)
  if (frame === undefined) return { state: st, effects: none }

  const type = typeof frame.type === 'string' ? frame.type : ''
  const subtype = typeof frame.subtype === 'string' ? frame.subtype : ''

  if (type === 'system' && subtype === 'init') {
    // A fresh turn began. Any queued sends' badges clear — the queue is now
    // draining, oldest first (charter D12). D77: the generation advances —
    // deltas from here on belong to this turn.
    const next: ChatState = { ...st, gen: st.gen + 1, local: st.local.map((l) => ({ ...l, queued: false })) }
    // The init frame carries the RESOLVED model and permission mode (a frame
    // missing either never blanks a known value). "default" is the CLI's own
    // post-plan flip — the turn-boundary refetch carries the real truth, so
    // don't paint the transient here.
    const model = typeof frame.model === 'string' ? frame.model : ''
    const mode = typeof frame.permissionMode === 'string' ? frame.permissionMode : ''
    if (model !== '') next.model = model
    if (mode !== '' && mode !== 'default') next.mode = mode
    if (next.phase === 'idle' || next.phase === 'waiting') next.phase = 'streaming'
    return { state: next, effects: none }
  }

  const event = (frame.event ?? {}) as Record<string, unknown>
  const delta = (event.delta ?? {}) as Record<string, unknown>
  if (
    type === 'stream_event' &&
    event.type === 'content_block_delta' &&
    delta.type === 'text_delta' &&
    typeof delta.text === 'string'
  ) {
    // D77 RESIDUAL (recorded, deliberately unfixed — mob-bl-chat-tab-polish
    // AC2): gen advances ONLY on system/init frames, so a turn whose deltas
    // arrive BEFORE its init shares the PRIOR turn's gen — a stale settle
    // issued for that prior gen could then clear this live tail. The wire
    // emits init first, so the window is theoretical today, and reduce.go
    // carries the equivalent weakness — any fix must land on both surfaces
    // together (parity-preserving). Do NOT re-add the removed phase guard
    // here; it was the wrong fix (it silently dropped streamed text).
    const next: ChatState = { ...st, tail: st.tail + delta.text, tailGen: st.gen }
    if (next.phase === 'idle' || next.phase === 'waiting') next.phase = 'streaming'
    // While interrupting, deltas may keep landing until the CLI actually
    // stops — keep accumulating (the truth is the result frame).
    return { state: next, effects: none }
  }

  if (type === 'result') {
    // The turn boundary — the ONLY interrupt truth (charter D11): an
    // interrupted turn is a NORMAL outcome, never an error, and the session
    // stays live.
    const interrupted = st.phase === 'interrupting' || frame.terminal_reason === 'aborted_streaming'
    let notice: string
    if (interrupted) notice = '⊘ Interrupted — session live'
    else if (frame.is_error === true) notice = `the turn ended with an error (${subtype})`
    else notice = ''
    // Settle: refetch the tail so the plain-text stream becomes persisted rows
    // AND the AI title lands (charter D8/D15). The tail stays painted until
    // the fetch returns — never a blank flash. The effect carries this turn's
    // gen (D77): only a fetch for the tail's own generation may clear it.
    return {
      state: { ...st, phase: 'idle', wedgeAtMs: 0, settling: true, notice },
      effects: [{ type: 'fetchTail', sinceSeq: st.lastSeq, gen: st.gen }],
    }
  }

  return { state: st, effects: none }
}

// Merges the turn-boundary GET: new rows append (seq-asc, monotonic), rows we
// already hold are UPDATED in place (an approval card flips its metadata
// WITHOUT changing seq), matching local echoes drop, and the title refreshes
// (charter D15). A failed fetch keeps the tail painted and says so — never
// silently drops streamed text. The tail clears ONLY when this fetch's gen
// matches the tail's generation (D77): a stale turn-1 settle landing after
// turn-2 started streaming must not clear — or duplicate against — turn-2's
// live tail.
function reduceTailFetched(st: ChatState, ev: TailFetchedEvent): ReduceResult {
  if (ev.error !== undefined) {
    return {
      state: { ...st, settling: false, notice: `refetch failed — transcript may lag (${ev.error})` },
      effects: none,
    }
  }
  const session = ev.session
  if (session === undefined) return { state: { ...st, settling: false }, effects: none }

  const bySeq = new Map<number, number>()
  st.messages.forEach((m, i) => bySeq.set(m.seq, i))
  const messages = [...st.messages]
  let lastSeq = st.lastSeq
  const fresh: ChatMessage[] = []
  for (const m of session.messages ?? []) {
    const idx = bySeq.get(m.seq)
    if (idx !== undefined) {
      messages[idx] = m
    } else if (m.seq > lastSeq) {
      fresh.push(m)
      lastSeq = m.seq
    }
  }
  messages.push(...fresh)

  // Any in-flight answer whose card is no longer pending has been resolved
  // server-side (by our POST or by a Studio answer to the SAME row) — drop its
  // badge so the card reads its terminal state.
  const answerInFlight: Record<string, string> = {}
  for (const [rid, decision] of Object.entries(st.answerInFlight)) {
    if (cardPending(messages, rid)) answerInFlight[rid] = decision
  }

  const title = (session.title ?? '').trim()
  const mode = (session.mode ?? '').trim()

  return {
    state: {
      ...st,
      settling: false,
      messages,
      lastSeq,
      local: dropSettledLocal(st.local, fresh),
      answerInFlight,
      title: title !== '' ? title : st.title,
      mode: mode !== '' ? mode : st.mode,
      // D77 clear guard: this fetch settles the painted tail only if it was
      // issued for the tail's own turn generation.
      tail: ev.gen === st.tailGen ? '' : st.tail,
    },
    effects: none,
  }
}

// Whether the row carrying request_id is still awaiting a decision. An absent
// row (or one already resolved) reads not-pending, so its in-flight badge
// clears.
function cardPending(msgs: ChatMessage[], rid: string): boolean {
  for (const m of msgs) {
    if (requestId(m) === rid) return approvalStatus(m) === 'pending'
  }
  return false
}

// Renders the public exit frame (charter D23 {status, reason}) as one honest
// footer line. A session is always relaunchable by sending.
function exitNotice(status: number | null, reason: string): string {
  const r = reason === '' ? 'unknown' : reason
  if (status !== null) return `session process exited (${r}, status ${status}) — send to relaunch`
  return `session process exited (${r}) — send to relaunch`
}

// Removes optimistic echoes whose persisted user row just arrived (first
// content match wins — duplicate sends settle one per row). Unmatched echoes
// stay: a queued send's row may not persist until its own turn starts.
function dropSettledLocal(local: LocalSend[], settled: ChatMessage[]): LocalSend[] {
  if (local.length === 0 || settled.length === 0) return local
  const remaining = [...local]
  for (const m of settled) {
    if (m.role !== 'user') continue
    const content = (m.source_markdown ?? '').trim()
    const i = remaining.findIndex((l) => l.content === content)
    if (i !== -1) remaining.splice(i, 1)
  }
  return remaining
}
