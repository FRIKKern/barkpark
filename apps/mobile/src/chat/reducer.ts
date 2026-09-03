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
//     own slice `ct-bl-tail-settle-gen`): `gen` increments per turn-start
//     frame on either lane (claude system/init, codex runtime turn_started),
//     `tailGen` stamps delta appends, fetch-tail effects/events carry the
//     issuing gen, and the tail-clear guard is `ev.gen === st.tailGen` — a
//     stale turn-1 refetch can never clear (or duplicate into) a streaming
//     turn-2 tail.
//   - Rail / workflow mission-control state (Rail, Workflow, LiveWorkflow) is
//     not ported: that richness stays a TUI+Studio surface this wave. The
//     `workflow` SSE frame is inert here (forward-compatible), like every
//     unknown frame.
import type { Block } from '../papers/portabledoc/model'
import type {
  ChatMessage,
  ChatSession,
  StableEndFrame,
  StableEndReason,
  StableFrame,
  StableSkeleton,
} from './wire'
import { approvalStatus, requestId } from './wire'

// The client-OWNED interrupt wedge (charter D11): if the terminal result frame
// never arrives within 8s of the interrupt, the client force-degrades locally
// instead of wedging in "interrupting…" forever.
export const WEDGE_TIMEOUT_MS = 8_000

/** The live tail's display cap in UTF-8 BYTES (charter D64's number). The
 * server does NOT enforce this for us: the LiveView caps its own accumulator
 * (chat_live.ex advance_streaming) but chat_controller forwards raw frames, so
 * every client bounds its own tail or a runaway turn grows an unbounded string
 * that re-measures on every delta. */
export const MAX_TAIL_BYTES = 262_144

/** What a frozen tail says — the same honest promise the web's capped bubble
 * makes (chat_live.ex `data-streaming-capped`). It is appended INTO the tail
 * because the tail is the only text the transcript row renders. */
export const TAIL_CAP_NOTICE =
  '\n\n— live preview truncated — the full response arrives on completion'

/** The ceiling on ACCUMULATED committed segments (charter D64's per-turn
 * number, applied per SESSION here because segments outlive their turn — a
 * settled turn keeps rendering its segment rows so nothing pops, see D61). Over
 * the bound the client stops consuming `stable` frames and every later turn
 * renders as today's plain tail. Mobile owns its own bound (D64): the server's
 * cap is LiveView-local and chat_controller forwards raw frames. */
export const MAX_STABLE_SEGMENTS = 4096

/** One COMMITTED segment of an answering turn — the client's projection of an
 * accepted `stable` frame (charter D59). Immutable, and the array it lives in is
 * append-only, so a segment's identity is stable for as long as it is displayed;
 * its (turn, from) pair is both its wire identity and its list row key.
 *
 * `to` is carried rather than derived from `blocks`: block text is not source
 * bytes (53 source vs 42 derived over the fixture's four-segment run proof), so
 * a client that measured the rendered text would reject a PERFECT stream at
 * frame 2. */
export interface StableSegment {
  turn: number
  from: number
  to: number
  blocks: Block[]
}

/** Where the segment stream stopped trusting itself — recorded rather than
 * merely latched, so a test can assert the DEGRADE STATE and not just the
 * absence of a crash. Mirrors the fixture's `gap` record field for field. */
export interface StableGap {
  turn: number
  expectedFrom: number
  actualFrom: number
}

/** The armed pop-free settle (charter D61). At `stable_end reason=settled` the
 * segments cover the turn byte-for-byte, so the persisted row the settle
 * refetch is about to bring is a DUPLICATE of what is already painted — but its
 * `seq` does not exist yet, so which row to suppress can only be decided when
 * the refetch answers. `afterSeq` is the watermark the turn's fresh rows must
 * clear. */
export interface SettleArm {
  turn: number
  afterSeq: number
}

/** A persisted row whose content is already on screen as segment rows, so it is
 * not drawn a second time (charter D61). Keyed by `seq` — server truth — and it
 * names its turn so row assembly knows WHICH segments stand in its place. */
export interface SuppressedRow {
  seq: number
  turn: number
}

/** Where the session's current turn stands, from the client's point of view.
 * The server does not carry this state (charter D12) — it is derived from the
 * frames we've seen. */
export type TurnPhase = 'idle' | 'waiting' | 'streaming' | 'interrupting'

/** An optimistic local echo of an outgoing user message — shown immediately,
 * badged queued while another turn is streaming (charter D12), and dropped
 * once the turn-boundary refetch returns its persisted row.
 *
 * `failed` is the honesty field. The echo is OPTIMISTIC: it is painted before
 * the POST is answered, and a send that never reached the server has no
 * persisted row, so the drop rule (dropSettledLocal) can never retire it — it
 * would sit there, pixel-identical to a delivered message, until unmount. A
 * client must not show a state it has not fetched, so a rejected POST comes
 * BACK through the reducer (the sendFailed event) and marks its echo. */
export interface LocalSend {
  content: string
  queued: boolean
  /** The POST was rejected — this message is NOT on the server. */
  failed: boolean
}

/** The whole reducible session state. `messages` are settled Postgres truth;
 * `tail` is the live-delta carve-out (chat-TUI charter D9); everything else is
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
  /** UTF-8 byte length of the STREAMED text in `tail` (the freeze notice is not
   * counted) — carried so the cap check is O(delta), not O(tail). */
  tailBytes: number
  /** The freeze latch: once the tail breaches MAX_TAIL_BYTES it stops growing.
   * Cleared with the tail at the settle boundary. */
  tailCapped: boolean

  /** request_id → decision ("allow"/"deny") POSTed but not yet confirmed by a
   * refetch — the immediate-feedback layer. */
  answerInFlight: Record<string, string>

  // ── the live DOCUMENT (charter D58–D61, D64–D67) ───────────────────────────
  //
  // Every field below is INERT until a server emits `stable` frames: with none
  // on the wire `segments` stays empty, `committedChars` stays 0, and the tail
  // is exactly the plain string it is today. That is the whole slice's
  // improvement-only property, and it is structural rather than a flag.

  /** The committed segments, append-only and ACROSS turns: a settled turn keeps
   * its segment rows (its persisted row is suppressed instead), because dropping
   * them at the next turn boundary would reflow an answer the reader has already
   * finished reading. The array identity changes ONLY on append or drop, which
   * is what keeps the screen's row memo alive across a delta tick. */
  segments: StableSegment[]
  /** The SERVER-AUTHORED turn whose segment stream is being consumed; -1 before
   * the first `stable` frame. This — never the client `gen` — is what fences the
   * cursor: `gen` advances on system/init, not on the replay that causes a gap,
   * and it has a documented pre-init hole (see the D77 RESIDUAL below). */
  stableTurn: number
  /** The byte cursor INSIDE stableTurn: the exclusive end of everything
   * committed, and the only `from` the next frame may carry. */
  committedBytes: number
  /** How much of `tail` (in UTF-16 code units) the committed segments already
   * cover, so the plain remainder is `tail.slice(committedChars)` and no byte is
   * ever painted twice. Maintained incrementally — advanced by one segment's
   * length per accepted frame — so it is O(segment), never O(tail). */
  committedChars: number
  /** The forming-block classification for the remainder, off the last accepted
   * frame (charter D67). Null means the remainder is ordinary prose. */
  skeleton: StableSkeleton | null
  /** This turn no longer consumes `stable` frames: a hole, the segment bound, or
   * a terminal frame. The committed segments STAY — the remainder simply goes
   * back to being plain. */
  stableStopped: boolean
  /** The terminal reason seen for stableTurn ('' = still streaming). */
  stableEnd: StableEndReason | ''
  /** The hole that stopped the stream, if a hole is what stopped it. */
  stableGap: StableGap | null
  /** Set at a turn boundary when the tail still holds the finished turn's text:
   * the next turn's byte offsets cannot be mapped into a tail that is carrying
   * someone else's bytes, so its segment stream is refused rather than
   * mis-split. Cleared when the settle refetch clears the tail. */
  tailCarried: boolean
  /** The pop-free settle, armed but not yet landed. */
  settleArm: SettleArm | null
  /** Persisted rows already covered by segment rows. */
  suppressed: SuppressedRow[]

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
    tailBytes: 0,
    tailCapped: false,
    answerInFlight: {},
    segments: [],
    stableTurn: -1,
    committedBytes: 0,
    committedChars: 0,
    skeleton: null,
    stableStopped: false,
    stableEnd: '',
    stableGap: null,
    tailCarried: false,
    settleArm: null,
    suppressed: [],
    notice: '',
    exited: false,
  }
}

// ── events ───────────────────────────────────────────────────────────────────

/** One SSE frame off the events stream (event name + raw data string). */
export type FrameEvent = { type: 'frame'; name: string; data: string }
/** The user submitting a non-empty composer. */
export type SendEvent = { type: 'send'; content: string }
/** The send POST was REJECTED — the shell telling the reducer what only the
 * shell can know. Carries `content` because that is the echo's only identity
 * (a local echo has no seq until the server gives it one, which is precisely
 * what did not happen here). */
export type SendFailedEvent = { type: 'sendFailed'; content: string; error: string }
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
  | SendFailedEvent
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

/** The generation a HYDRATION fetch carries — a session GET that is not a
 * settle boundary (the shell's seed GET at attach; the TUI's rail-expand
 * refetch). It is a SENTINEL, not a generation: `gen` and `tailGen` are only
 * ever >= 0, so `ev.gen === st.tailGen` (the D77 clear guard) is unsatisfiable
 * for it and a hydration read can never clear a live tail.
 *
 * Both plausible alternatives are wrong, which is the whole reason this is a
 * named constant and not a literal at the call site:
 *   - carrying the CURRENT gen wipes the live streamed text whenever the
 *     hydration lands mid-stream (it matches the tail's own generation);
 *   - the ZERO value wipes it in the attach-mid-turn case — deltas observed
 *     before any system/init frame leave gen === tailGen === 0, so a seed GET
 *     stamped 0 matches and clears a tail that is still streaming.
 * Parity: internal/chat/keys.go passes `Gen: -1` for the same two reasons. */
export const HYDRATION_GEN = -1
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
    case 'sendFailed':
      return reduceSendFailed(st, ev)
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
      local: [...st.local, { content, queued: midTurn, failed: false }],
      phase: midTurn ? st.phase : 'waiting',
      notice: '',
    },
    effects: [{ type: 'sendMessage', content }],
  }
}

// The send POST came back rejected. The echo is already painted, and the drop
// rule cannot retire it (there is no persisted row for a message the server
// never received), so the ONLY honest move is to mark it: the bubble keeps the
// user's text — losing it would be worse than mislabelling it — and stops
// claiming delivery.
//
// The OLDEST unfailed echo with this content is the one marked: sends settle
// oldest-first (dropSettledLocal matches the same way), so a duplicate send
// whose first attempt succeeded and whose second was rejected marks exactly one
// bubble. An echo that has already settled (its persisted row arrived before
// the rejection was observed) matches nothing and the event is inert — it never
// invents a failure for a message the server does hold.
//
// The queued badge is cleared with the flip: a failed send is not waiting its
// turn in a queue, and two contradictory badges on one bubble is worse than
// none. And if this send is the only thing the session was waiting on, the
// phase returns to idle — otherwise the composer would spin on a turn that was
// never started.
function reduceSendFailed(st: ChatState, ev: SendFailedEvent): ReduceResult {
  const i = st.local.findIndex((l) => !l.failed && l.content === ev.content)
  if (i === -1) return { state: st, effects: none }
  const local = [...st.local]
  local[i] = { ...local[i]!, queued: false, failed: true }
  const stillPending = local.some((l) => !l.failed)
  return {
    state: {
      ...st,
      local,
      phase: st.phase === 'waiting' && !stillPending ? 'idle' : st.phase,
      notice: `send failed — ${ev.error}`,
    },
    effects: none,
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
    case 'runtime':
      return reduceRuntimeFrame(st, ev.data)
    case 'stable': {
      // One settled segment of the answering turn (charter D59). A malformed
      // frame is INERT, exactly like every other unparseable frame — and that
      // inertness is not a shrug: the byte cursor notices the missing bytes on
      // the NEXT frame and degrades honestly, so a dropped frame can never be
      // spliced over.
      const f = parseStableFrame(ev.data)
      if (f === undefined) return { state: st, effects: none }
      return { state: reduceStable(st, f), effects: none }
    }
    case 'stable_end': {
      const f = parseStableEnd(ev.data)
      if (f === undefined) return { state: st, effects: none }
      return { state: reduceStableEnd(st, f), effects: none }
    }
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
    // While interrupting, deltas may keep landing until the CLI actually
    // stops — keep accumulating (the truth is the result frame).
    return { state: appendTail(st, delta.text), effects: none }
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
    // AND the AI title lands (chat-TUI charter D8/D15). The tail stays painted until
    // the fetch returns — never a blank flash. The effect carries this turn's
    // gen (D77): only a fetch for the tail's own generation may clear it.
    return {
      state: {
        ...st,
        phase: 'idle',
        wedgeAtMs: 0,
        settling: true,
        notice,
        // The turn is over but its text is still painted. Until the refetch
        // clears it, the tail is CARRYING a finished turn — so the next turn's
        // byte offsets have nowhere honest to land (adoptStableTurn refuses it).
        tailCarried: st.tail !== '',
      },
      effects: [{ type: 'fetchTail', sinceSeq: st.lastSeq, gen: st.gen }],
    }
  }

  return { state: st, effects: none }
}

// ── the live-document consumer (charter D59/D61/D64/D67) ─────────────────────

function isInt(v: unknown): v is number {
  return typeof v === 'number' && Number.isInteger(v)
}

// The remainder's shape classification. Any `kind` string is legal — an unknown
// one degrades to the generic "block" placeholder (StreamSkeleton.skeletonLabel
// is the server's skeleton_label/1 twin, including its fallback arm), so a newer
// server's eighth kind renders honestly instead of nothing. `prose` is
// legitimately the EMPTY STRING whenever the forming block starts exactly at
// `to`, and it is defaulted rather than required for exactly that reason.
function parseSkeleton(raw: unknown): StableSkeleton | null {
  if (raw === null || typeof raw !== 'object') return null
  const o = raw as Record<string, unknown>
  if (typeof o.kind !== 'string') return null
  return { kind: o.kind, prose: typeof o.prose === 'string' ? o.prose : '' }
}

/** The `stable` payload, or undefined for anything that is not one. Unknown keys
 * are IGNORED (the fixture's forward-compat sequence): a server that starts
 * stamping `hint` or `cost` must not degrade an older client. */
function parseStableFrame(data: string): StableFrame | undefined {
  const o = parseJson(data)
  if (o === undefined) return undefined
  const { turn, from, to } = o
  if (!isInt(turn) || !isInt(from) || !isInt(to)) return undefined
  // Half-open [from,to) with at least one byte, and at least one block: an
  // empty segment would advance the cursor while painting nothing, which is the
  // one shape that could silently swallow source bytes.
  if (from < 0 || to <= from) return undefined
  if (!Array.isArray(o.blocks) || o.blocks.length === 0) return undefined
  return {
    turn,
    from,
    to,
    blocks: o.blocks as Block[],
    skeleton: parseSkeleton(o.skeleton),
  }
}

function parseStableEnd(data: string): StableEndFrame | undefined {
  const o = parseJson(data)
  if (o === undefined) return undefined
  const { turn, from, reason } = o
  if (!isInt(turn) || !isInt(from) || from < 0) return undefined
  if (reason !== 'settled' && reason !== 'capped' && reason !== 'degraded') return undefined
  return { turn, from, reason }
}

// Adopts the frame's turn, resetting the per-turn cursor when it changes — the
// fixture's cursor_rule verbatim. Segments of EARLIER turns survive: they are
// what a settled turn is still being drawn from.
//
// The refusal arm is the one thing the wire cannot tell us: if a finished turn's
// text is still sitting in the tail (its settle refetch has not landed), the new
// turn's byte offsets index into a string that starts with someone else's bytes.
// Mapping them anyway would paint the new turn's first segment TWICE — once as a
// block, once as plain remainder. So the turn is refused whole and renders as
// today's plain tail.
function adoptStableTurn(st: ChatState, turn: number): ChatState {
  if (turn === st.stableTurn) return st
  return {
    ...st,
    stableTurn: turn,
    committedBytes: 0,
    skeleton: null,
    stableStopped: st.tailCarried,
    stableEnd: '',
    stableGap: null,
  }
}

// Drops one turn's segments and un-suppresses whatever they were standing in
// for, resetting the display cursor with them so the whole tail is plain again.
// This is the fixture's `committed_bytes: 0` for a server-declared degrade,
// spelled out: nothing half-committed survives a drop.
function dropStableTurn(st: ChatState, turn: number): ChatState {
  const segments = st.segments.filter((s) => s.turn !== turn)
  if (segments.length === st.segments.length && st.committedBytes === 0) return st
  return {
    ...st,
    segments,
    suppressed: st.suppressed.filter((r) => r.turn !== turn),
    committedBytes: 0,
    committedChars: 0,
    skeleton: null,
  }
}

// THE ACCEPT RULE, and it is not hygiene (charter D59). Live `event: chat` frames
// carry no id and are never replayed ("Emergency guard, not a replay promise",
// chat_controller.ex:396) while this client reconnects on a 1s→16s ladder, so a
// consumer that ignored `from` would splice a SILENTLY WRONG document: no throw,
// no error field, and the SAME final byte cursor as the ungapped stream, which is
// why nothing downstream could notice either. And `from` alone is insufficient —
// a turn-boundary gap whose predecessor's total coincidentally equals the
// survivor's `from` is FALSE-ACCEPTED, which is the run proof recorded as the
// fixture's turn_boundary_gap_false_accepted_by_from_only sequence.
function reduceStable(st: ChatState, f: StableFrame): ChatState {
  const next = adoptStableTurn(st, f.turn)
  if (next.stableStopped) return next
  if (f.from !== next.committedBytes) {
    // THE HOLE. Keep every committed segment — that content is real, converted,
    // already read — render the remainder plain, and never patch the gap. The
    // turn stops consuming, so a later frame cannot re-open the wound.
    return {
      ...next,
      stableStopped: true,
      skeleton: null,
      stableGap: { turn: f.turn, expectedFrom: next.committedBytes, actualFrom: f.from },
    }
  }
  if (next.segments.length >= MAX_STABLE_SEGMENTS) {
    return { ...next, stableStopped: true, skeleton: null }
  }
  return {
    ...next,
    segments: [...next.segments, { turn: f.turn, from: f.from, to: f.to, blocks: f.blocks }],
    // The cursor advances by `to` — the SOURCE offset — never by the rendered
    // block text.
    committedBytes: f.to,
    committedChars: advanceChars(next.tail, next.committedChars, f.to - f.from),
    skeleton: f.skeleton,
  }
}

// The turn's terminal frame (charter D61).
//
//   settled  — the server compared concat(segments) against a whole-document
//              conversion and they matched, so the persisted row is a duplicate
//              of what is already painted: ARM the suppression. This is what
//              turns "at settle nothing pops" from a hope into a mechanism.
//   degraded — the server distrusts its OWN segmentation: drop the segments and
//              render the persisted row, today's exact behaviour. `from` is NOT
//              cursor-checked here, because the segments are being thrown away
//              anyway and a cursor complaint about discarded bytes is noise.
//   capped   — the segmenter hit its bound. Reachable with ZERO segments ever
//              emitted, which is why this is its own event and not a field.
//              Same handling as degraded: FREEZE onto the persisted row.
function reduceStableEnd(st: ChatState, f: StableEndFrame): ChatState {
  const next = adoptStableTurn(st, f.turn)
  if (f.reason === 'degraded' || f.reason === 'capped') {
    return dropStableTurn(
      { ...next, stableEnd: f.reason, stableStopped: true, settleArm: null },
      f.turn,
    )
  }
  if (next.stableStopped) return { ...next, stableEnd: 'settled' }
  if (f.from !== next.committedBytes) {
    return {
      ...next,
      stableEnd: 'settled',
      stableStopped: true,
      skeleton: null,
      stableGap: { turn: f.turn, expectedFrom: next.committedBytes, actualFrom: f.from },
    }
  }
  const covered = next.segments.some((s) => s.turn === f.turn)
  return {
    ...next,
    stableEnd: 'settled',
    // Terminal means terminal: this turn consumes nothing further. A later frame
    // for it is inert — NOT a protocol error, nothing resets and nothing is
    // reported, it simply cannot append to a document the server has already
    // declared whole and the client has already promised not to reflow.
    stableStopped: true,
    skeleton: null,
    settleArm: covered ? { turn: f.turn, afterSeq: next.lastSeq } : null,
  }
}

/** The plain, still-unsettled remainder of the live tail — everything after the
 * committed cursor. With no segments committed this is the whole tail, byte for
 * byte, which is why a server that never emits `stable` frames sees today's
 * behaviour exactly. */
export function tailRemainder(st: ChatState): string {
  return st.committedChars <= 0 ? st.tail : st.tail.slice(st.committedChars)
}

// Handles one normalized Runtime.Event frame (event: runtime) — the codex and
// remote/RemoteRef text lane, the sibling of `event: chat`. The wire is the
// serialized %Runtime.Event{} struct (chat_controller.ex sse_runtime_frame):
// `kind` is the normalized verb and `native` retains the lossless provider
// envelope, so the text lives at native.params.delta.
//
// kind is matched EXACTLY, and that is load-bearing: codex's protocol maps
// item/reasoning/textDelta → thinking_delta and item/commandExecution/
// outputDelta → tool_delta to the SAME native.params.delta location. A loose
// match would splice reasoning and command output into the answer. Everything
// that is not turn_started, text_delta or turn_completed is inert here — those
// rows arrive as persisted truth at the turn boundary, as on the claude lane.
function reduceRuntimeFrame(st: ChatState, data: string): ReduceResult {
  const frame = parseJson(data)
  if (frame === undefined) return { state: st, effects: none }
  const kind = typeof frame.kind === 'string' ? frame.kind : ''

  if (kind === 'turn_started') {
    // The codex lane's turn-start signal — the sibling of the claude lane's
    // system/init — and the twin of internal/chat/reduce.go's turn_started arm.
    // It advances the generation and emits NOTHING else: no effect, no phase
    // change, no notice, and above all NO touch of tail/tailGen (that would
    // blank-flash the prior turn's still-painted text, which carries its own
    // generation until its own settle lands).
    //
    // Why the advance: before it, gen moved only on a claude system/init frame,
    // so a codex turn kept the generation it started in — a stale turn-1 settle
    // GET landed carrying a gen that still equalled tailGen, and the D77 clear
    // guard (`ev.gen === st.tailGen`) wiped turn 2's live tail.
    //
    // THE CURSOR STAYS PUT. `committedBytes`/`stableTurn` are keyed on the
    // SERVER turn, never on this client clock (see the `stableTurn` field), and
    // __tests__/chatCursorTurnKeyed.test.ts reds if this arm ever takes them.
    return { state: { ...st, gen: st.gen + 1 }, effects: none }
  }

  if (kind === 'text_delta') {
    const native = (frame.native ?? {}) as Record<string, unknown>
    const params = (native.params ?? {}) as Record<string, unknown>
    const delta = params.delta
    if (typeof delta !== 'string' || delta === '') return { state: st, effects: none }
    // Stamped with the current gen exactly as the claude lane stamps it, so the
    // D77 settle guard sees the same shape on both lanes — and the generation it
    // carries is now this lane's own, advanced by the turn_started arm above.
    return { state: appendTail(st, delta), effects: none }
  }

  if (kind === 'turn_completed') {
    // The codex turn boundary — the sibling of the claude `result` frame, and
    // the ONLY settle a codex turn gets. Without it the phase never returns to
    // idle and the Recorder's persisted answer (recorder.ex persist_runtime_text)
    // never reaches the screen.
    const terminal = typeof frame.terminal_state === 'string' ? frame.terminal_state : ''
    const interrupted = st.phase === 'interrupting' || terminal === 'interrupted'
    let notice: string
    if (interrupted) notice = '⊘ Interrupted — session live'
    else if (terminal === 'failed') notice = 'the turn ended with an error'
    else notice = ''
    return {
      state: {
        ...st,
        phase: 'idle',
        wedgeAtMs: 0,
        settling: true,
        notice,
        tailCarried: st.tail !== '',
      },
      effects: [{ type: 'fetchTail', sinceSeq: st.lastSeq, gen: st.gen }],
    }
  }

  return { state: st, effects: none }
}

// Appends streamed text to the live tail — the ONE accumulator both lanes share,
// so the D77 stamp and the display cap can never diverge between providers.
//
// FREEZE semantics at MAX_TAIL_BYTES (parity with the web's capped bubble): the
// tail stops growing, everything already shown is KEPT, and one honest line says
// the preview was truncated. The stream is neither closed nor shed — deltas keep
// arriving, the turn still settles, and the settle refetch brings the full
// untruncated answer from Postgres.
function appendTail(st: ChatState, text: string): ChatState {
  const next: ChatState = { ...st, tailGen: st.gen }
  if (next.phase === 'idle' || next.phase === 'waiting') next.phase = 'streaming'
  if (st.tailCapped) return next
  const bytes = st.tailBytes + utf8ByteLength(text)
  if (bytes > MAX_TAIL_BYTES) {
    next.tail = st.tail + TAIL_CAP_NOTICE
    next.tailCapped = true
    return next
  }
  next.tail = st.tail + text
  next.tailBytes = bytes
  return next
}

// How wide the code point starting at s[i] is, encoded as
// `bytes * 2 + (surrogate pair ? 1 : 0)` so both hot loops below stay
// allocation-free. ONE owner for the encoding rule: the cap counter and the
// cursor mapper must agree on every byte or the display split drifts from the
// bound, and two hand-copied loops is exactly how that drift happens.
function utf8StepAt(s: string, i: number): number {
  const c = s.charCodeAt(i)
  if (c < 0x80) return 2
  if (c < 0x800) return 4
  if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
    const lo = s.charCodeAt(i + 1)
    if (lo >= 0xdc00 && lo <= 0xdfff) return 9 // 4 bytes, 2 code units
  }
  return 6
}

// UTF-8 byte length of a JS string, counted without allocating (TextEncoder is
// not guaranteed on every Hermes build, and the cap must be measured in the same
// unit the server's D64 number is stated in).
function utf8ByteLength(s: string): number {
  let n = 0
  for (let i = 0; i < s.length; ) {
    const step = utf8StepAt(s, i)
    n += step >> 1
    i += (step & 1) === 1 ? 2 : 1
  }
  return n
}

// Walks `bytes` UTF-8 bytes forward from code-unit index `from`, returning the
// index reached. CLAMPED at the end of the string on purpose: the frames may run
// ahead of the deltas that carry their text, and when they do the honest split is
// "everything visible is committed" — an empty remainder. It never runs past the
// string, so the plain remainder can never repeat a byte a segment already drew.
function advanceChars(s: string, from: number, bytes: number): number {
  let i = from < 0 ? 0 : from
  let n = 0
  while (i < s.length && n < bytes) {
    const step = utf8StepAt(s, i)
    n += step >> 1
    i += (step & 1) === 1 ? 2 : 1
  }
  return i
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

  // D77 clear guard: this fetch settles the painted tail only if it was issued
  // for the tail's own turn generation.
  const clears = ev.gen === st.tailGen
  const settled: ChatState = {
    ...st,
    settling: false,
    messages,
    lastSeq,
    local: dropSettledLocal(st.local, fresh),
    answerInFlight,
    title: title !== '' ? title : st.title,
    mode: mode !== '' ? mode : st.mode,
    // Clearing the tail also releases the freeze latch — the cap bounds ONE
    // turn's preview, never the session.
    tail: clears ? '' : st.tail,
    tailBytes: clears ? 0 : st.tailBytes,
    tailCapped: clears ? false : st.tailCapped,
  }
  if (!clears) return { state: settled, effects: none }
  return { state: landStableSettle(settled, st, fresh), effects: none }
}

// THE SETTLE BOUNDARY for the live document (charter D61), reached only on the
// refetch that actually clears the tail.
//
// The string the byte cursor was mapped into has just been replaced, so the
// per-turn cursor resets with it. What happens to the SEGMENTS is the whole
// question, and it has exactly three answers:
//
//   armed + exactly one fresh assistant row → SUPPRESS that row. Its content is
//     already painted as segment rows, verified byte-for-byte by the server
//     before it said `settled`, so drawing it again would be the pop this design
//     exists to remove. The row itself is untouched in `messages` — Postgres
//     stays the sole truth and a cold open renders it normally; suppression is a
//     presentation fact, and it is why the settle is a data no-op.
//   armed but the batch is AMBIGUOUS (no fresh assistant row, or several) →
//     DROP the segments and let the persisted rows draw. Fails toward today's
//     behaviour rather than toward guessing which row the turn was.
//   not armed, and the TURN is over → drop the segments. A gap, a server
//     degrade, a cap, or a server that never emitted a stable frame all land
//     here: the persisted row is the truth now.
//
// A mid-turn refetch (an approval ask, an answered card) also clears the tail,
// and it deliberately KEEPS the segments: that content is real and converted,
// and the post-clear tail holds only the deltas that arrive after it, so nothing
// is drawn twice. Consumption still stops, because the cursor's string is gone —
// the next frame for that turn cannot match a cursor reset to 0, which is the
// accept rule detecting the situation on its own rather than a second latch.
function landStableSettle(next: ChatState, prev: ChatState, fresh: ChatMessage[]): ChatState {
  const reset: ChatState = {
    ...next,
    stableTurn: -1,
    committedBytes: 0,
    committedChars: 0,
    skeleton: null,
    stableStopped: false,
    stableEnd: '',
    stableGap: null,
    tailCarried: false,
    settleArm: null,
  }
  const arm = prev.settleArm
  if (arm !== null) {
    const own = fresh.filter((m) => m.role === 'assistant')
    const row = own.length === 1 ? own[0] : undefined
    if (row !== undefined) {
      return { ...reset, suppressed: [...reset.suppressed, { seq: row.seq, turn: arm.turn }] }
    }
    return dropStableTurn(reset, arm.turn)
  }
  // `phase` is the discriminator, and it is the honest one: the result frame
  // flips it to idle BEFORE issuing the settle refetch, while a permission ask
  // refetches mid-turn with the turn still streaming.
  if (prev.phase === 'idle' && prev.stableTurn !== -1) return dropStableTurn(reset, prev.stableTurn)
  return reset
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
//
// A FAILED echo is never settled by a row: its POST was rejected, so no row it
// could be is coming. Skipping it matters for the retry shape — re-sending the
// same text and succeeding must retire the SECOND echo (the one that reached
// the server) and leave the failed bubble standing, not the other way round.
function dropSettledLocal(local: LocalSend[], settled: ChatMessage[]): LocalSend[] {
  if (local.length === 0 || settled.length === 0) return local
  const remaining = [...local]
  for (const m of settled) {
    if (m.role !== 'user') continue
    const content = (m.source_markdown ?? '').trim()
    const i = remaining.findIndex((l) => !l.failed && l.content === content)
    if (i !== -1) remaining.splice(i, 1)
  }
  return remaining
}
