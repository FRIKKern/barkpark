// The recorded-frame reducer proofs — the TS port of internal/chat/
// reduce_test.go. Every load-bearing invariant (D8 settlement, D9 tail
// carve-out, D11 interrupt truth, D12 queued steer, D15 title refresh, the
// D77 settle race) is driven by feeding reduce() the same frame shapes the
// server emits — no device, no server, no clock.
import {
  initialChatState,
  MAX_TAIL_BYTES,
  reduce,
  TAIL_CAP_NOTICE,
  WEDGE_TIMEOUT_MS,
  type ChatEffect,
  type ChatEvent,
  type ChatState,
  type FetchTailEffect,
} from '../src/chat/reducer'
import type { ChatMessage, ChatSession } from '../src/chat/wire'

const t0 = Date.UTC(2026, 6, 13, 12, 0, 0)

function chatFrame(obj: unknown): ChatEvent {
  return { type: 'frame', name: 'chat', data: JSON.stringify(obj) }
}

const initFrame = (extra: Record<string, unknown> = {}): ChatEvent =>
  chatFrame({ type: 'system', subtype: 'init', ...extra })

const deltaFrame = (text: string): ChatEvent =>
  chatFrame({
    type: 'stream_event',
    event: { type: 'content_block_delta', delta: { type: 'text_delta', text } },
  })

/** One `event: runtime` frame — the serialized %Runtime.Event{} the codex and
 * remote lanes emit (chat_controller.ex sse_runtime_frame): the normalized
 * `kind` plus the lossless provider envelope under `native`. */
function runtimeFrame(kind: string, extra: Record<string, unknown> = {}): ChatEvent {
  return {
    type: 'frame',
    name: 'runtime',
    data: JSON.stringify({
      version: 1,
      provider: 'codex',
      session_id: 's1',
      durability: 'delta',
      kind,
      ...extra,
    }),
  }
}

/** A codex text frame of the given kind — text_delta, thinking_delta and
 * tool_delta ALL carry their text at native.params.delta (codex protocol.ex
 * maps item/agentMessage/delta, item/reasoning/textDelta and
 * item/commandExecution/outputDelta to the same place). */
const runtimeTextFrame = (kind: string, delta: string): ChatEvent =>
  runtimeFrame(kind, {
    item_id: 'item_1',
    native: { method: 'item/agentMessage/delta', params: { itemId: 'item_1', delta } },
  })

const resultFrame = (reason: string, isError: boolean): ChatEvent =>
  chatFrame({ type: 'result', subtype: 'success', terminal_reason: reason, is_error: isError })

/** Folds events through reduce, collecting the LAST effect set, so a test can
 * assert the settled state plus what IO the final event asked for. */
function drive(
  st: ChatState,
  nowMs: number,
  ...evs: ChatEvent[]
): { state: ChatState; effects: ChatEffect[] } {
  let state = st
  let effects: ChatEffect[] = []
  for (const ev of evs) {
    ;({ state, effects } = reduce(state, ev, nowMs))
  }
  return { state, effects }
}

function fetchTailOf(effects: ChatEffect[]): FetchTailEffect | undefined {
  return effects.find((e): e is FetchTailEffect => e.type === 'fetchTail')
}

function pendingCardRow(seq: number, role: string, rid: string): ChatMessage {
  return {
    seq,
    role,
    source_markdown: 'run `rm -rf build`?',
    metadata: { request_id: rid, approval_status: 'pending' },
  }
}

// chat-TUI charter D8/D9: deltas form the live plain-text tail; ONLY the terminal result frame
// is the turn boundary, and it alone asks for the ?since= refetch that
// settles the tail into persisted rows.
test('delta tail accumulates and settles at result', () => {
  let { state } = drive(initialChatState('s1'), t0, initFrame())
  expect(state.phase).toBe('streaming')

  let effects: ChatEffect[]
  ;({ state, effects } = drive(state, t0, deltaFrame('Hel'), deltaFrame('lo')))
  expect(state.tail).toBe('Hello')
  expect(effects).toHaveLength(0) // a delta must trigger no IO — the tail is live truth

  ;({ state, effects } = drive(state, t0, resultFrame('', false)))
  expect(state.phase).toBe('idle')
  expect(state.settling).toBe(true)
  const fetch = fetchTailOf(effects)
  expect(fetch).toBeDefined()
  expect(fetch?.sinceSeq).toBe(state.lastSeq)
  // The tail stays painted until the fetch returns — never a blank flash.
  expect(state.tail).toBe('Hello')
})

// chat-TUI charter D8/D15: the turn-boundary GET appends the persisted rows, clears the
// settled tail, and lands the (AI-refreshed) title.
test('tailFetched settles and refreshes title', () => {
  const st: ChatState = {
    ...initialChatState('s1'),
    tail: 'Hello',
    settling: true,
  }
  const session: ChatSession = {
    id: 's1',
    title: 'Refreshed AI Title',
    messages: [{ seq: 1, role: 'assistant', source_markdown: 'Hello' }],
  }
  const { state } = drive(st, t0, { type: 'tailFetched', gen: 0, session })
  expect(state.messages).toHaveLength(1)
  expect(state.lastSeq).toBe(1)
  expect(state.tail).toBe('')
  expect(state.title).toBe('Refreshed AI Title')
  expect(state.settling).toBe(false)
})

// The D8 "never silently drop streamed text" rule: a failed refetch keeps the
// tail and says so.
test('tailFetched error keeps tail painted', () => {
  const st: ChatState = { ...initialChatState('s1'), tail: 'partial reply', settling: true }
  const { state } = drive(st, t0, { type: 'tailFetched', gen: 0, error: 'boom' })
  expect(state.tail).toBe('partial reply')
  expect(state.notice).not.toBe('')
})

// D11: interrupt during a turn flips to interrupting immediately and arms the
// wedge; a further delta is non-terminal; only the result frame settles it —
// and aborted_streaming is a NORMAL outcome, never an error.
test('interrupt immediate, then aborted_streaming is not an error', () => {
  let st: ChatState = { ...initialChatState('s1'), phase: 'streaming', tail: 'thinking' }

  let { state, effects } = drive(st, t0, { type: 'interrupt' })
  expect(state.phase).toBe('interrupting')
  expect(state.notice).toBe('interrupting…')
  expect(effects.some((e) => e.type === 'interruptTurn')).toBe(true)
  expect(state.wedgeAtMs).not.toBe(0)

  // The empty control ack is not completion — a further delta keeps us
  // interrupting (deltas may keep landing until the CLI actually stops).
  ;({ state } = drive(state, t0, deltaFrame(' more')))
  expect(state.phase).toBe('interrupting')

  // The result frame is the truth: aborted_streaming settles non-error.
  ;({ state, effects } = drive(state, t0, resultFrame('aborted_streaming', false)))
  expect(state.phase).toBe('idle')
  expect(state.notice).toBe('⊘ Interrupted — session live')
  expect(fetchTailOf(effects)).toBeDefined() // an interrupted turn still settles its tail
})

// The D11 8s wedge: if the result never arrives, a tick past the deadline
// force-degrades locally and refetches.
test('interrupt wedge degrades locally after 8s', () => {
  const { state: interrupting } = drive(
    { ...initialChatState('s1'), phase: 'streaming' },
    t0,
    { type: 'interrupt' },
  )

  // A tick before the deadline changes nothing.
  const before = drive(interrupting, t0 + WEDGE_TIMEOUT_MS - 1000, { type: 'tick' })
  expect(before.state.phase).toBe('interrupting')
  expect(before.effects).toHaveLength(0)

  // A tick past 8s degrades locally and refetches.
  const after = drive(interrupting, t0 + WEDGE_TIMEOUT_MS + 1000, { type: 'tick' })
  expect(after.state.phase).toBe('idle')
  expect(fetchTailOf(after.effects)).toBeDefined()
})

// D11: interrupt with no active turn does nothing — no phase change, no IO.
test('idle interrupt is a silent no-op', () => {
  const { state, effects } = drive(initialChatState('s1'), t0, { type: 'interrupt' })
  expect(state.phase).toBe('idle')
  expect(state.notice).toBe('')
  expect(effects).toHaveLength(0)
})

// D12: a send during a turn is badged queued and only un-badges when a fresh
// system/init frame proves the next turn started.
test('mid-turn send queues, then resolves on next init', () => {
  let st: ChatState = { ...initialChatState('s1'), phase: 'streaming' }

  let { state, effects } = drive(st, t0, { type: 'send', content: 'next question' })
  expect(state.local).toHaveLength(1)
  expect(state.local[0]?.queued).toBe(true)
  // A send always POSTs immediately (the server does not distinguish queued).
  expect(effects.some((e) => e.type === 'sendMessage')).toBe(true)
  expect(state.phase).toBe('streaming')

  // The next turn's init frame drains the badge.
  ;({ state } = drive(state, t0, initFrame()))
  expect(state.local[0]?.queued).toBe(false)
})

// The mid_turn_queued_user fixture semantics: turn one's tail survives the
// queued send, its own result, AND the fresh init — only its own settle fetch
// clears it (the no-blank-flash property the D77 gen fix must preserve).
test('queued send preserves turn one until fresh init', () => {
  let { state } = drive(initialChatState('s1'), t0, initFrame(), deltaFrame('turn one'))
  expect(state.tail).toBe('turn one')
  expect(state.phase).toBe('streaming')

  let effects: ChatEffect[]
  ;({ state, effects } = drive(state, t0, { type: 'send', content: 'queued question' }))
  expect(state.tail).toBe('turn one')
  expect(state.local[0]?.queued).toBe(true)
  expect(effects.some((e) => e.type === 'sendMessage')).toBe(true)

  ;({ state } = drive(state, t0, resultFrame('', false)))
  expect(state.phase).toBe('idle')
  expect(state.tail).toBe('turn one')
  expect(state.local[0]?.queued).toBe(true) // result must not consume the queued send

  ;({ state } = drive(state, t0, initFrame()))
  expect(state.phase).toBe('streaming')
  expect(state.local[0]?.queued).toBe(false)
  expect(state.tail).toBe('turn one') // fresh init preserves turn one until its settle lands
})

// The idle-send path: a send with no active turn flips to waiting, not badged.
test('fresh send starts waiting', () => {
  const { state } = drive(initialChatState('s1'), t0, { type: 'send', content: 'hi' })
  expect(state.phase).toBe('waiting')
  expect(state.local[0]?.queued).toBe(false)
})

// A blank send is inert.
test('blank send is a no-op', () => {
  const { state, effects } = drive(initialChatState('s1'), t0, { type: 'send', content: '   ' })
  expect(state.local).toHaveLength(0)
  expect(effects).toHaveLength(0)
})

// The public exit frame (charter D23 {status, reason}) settles honestly: a
// null-status crash names its reason (never "status 0"), an integer exit
// shows the code, and the turn ends relaunchable.
test('exit frame surfaces reason', () => {
  const crash: ChatEvent = { type: 'frame', name: 'exit', data: '{"status":null,"reason":"crashed"}' }
  let { state, effects } = drive({ ...initialChatState('s1'), phase: 'streaming' }, t0, crash)
  expect(state.exited).toBe(true)
  expect(state.phase).toBe('idle')
  expect(effects).toHaveLength(0)
  expect(state.notice).toContain('crashed')
  expect(state.notice).not.toContain('status 0')

  const clean: ChatEvent = { type: 'frame', name: 'exit', data: '{"status":0,"reason":"clean"}' }
  ;({ state } = drive(initialChatState('s1'), t0, clean))
  expect(state.notice).toContain('status 0')
  expect(state.notice).toContain('clean')
})

// The Law-1 answer contract: a card answer emits the approval POST with an
// immediate in-flight badge, and the POST completing fires a FULL refetch
// (sinceSeq 0) — the only refetch that surfaces an in-place metadata flip.
test('answer posts then full refetch', () => {
  let st: ChatState = {
    ...initialChatState('s1'),
    messages: [pendingCardRow(3, 'approval', 'req-1')],
    lastSeq: 3,
  }

  let { state, effects } = drive(st, t0, { type: 'answer', requestId: 'req-1', decision: 'allow' })
  const answer = effects.find((e) => e.type === 'answerCard')
  expect(answer).toEqual({ type: 'answerCard', requestId: 'req-1', decision: 'allow' })
  expect(state.answerInFlight['req-1']).toBe('allow')
  expect(state.notice).toBe('allowing…')

  ;({ state, effects } = drive(state, t0, { type: 'answered', requestId: 'req-1' }))
  const fetch = fetchTailOf(effects)
  expect(fetch?.sinceSeq).toBe(0)
})

// The pending → allowed flip: the resolved row keeps its seq (only metadata
// changed), so the merge must UPDATE it in place, not duplicate it — and the
// in-flight badge clears once the terminal status lands.
test('answer refetch flips card in place', () => {
  const st: ChatState = {
    ...initialChatState('s1'),
    messages: [pendingCardRow(3, 'approval', 'req-1')],
    lastSeq: 3,
    answerInFlight: { 'req-1': 'allow' },
  }
  const resolvedRow = pendingCardRow(3, 'approval', 'req-1')
  resolvedRow.metadata = { ...resolvedRow.metadata, approval_status: 'allowed' }

  const { state } = drive(st, t0, {
    type: 'tailFetched',
    gen: 0,
    session: { id: 's1', messages: [resolvedRow] },
  })
  expect(state.messages).toHaveLength(1)
  expect(state.messages[0]?.metadata?.approval_status).toBe('allowed')
  expect(state.answerInFlight['req-1']).toBeUndefined()
})

// Law-2 one-truth: a card resolved by ANOTHER surface (Studio) shows as
// resolved here purely from a refetch — no local answer, no sync engine.
test('a Studio answer resolves the same card', () => {
  const st: ChatState = {
    ...initialChatState('s1'),
    messages: [pendingCardRow(5, 'question', 'q-9')],
    lastSeq: 5,
  }
  const answered = pendingCardRow(5, 'question', 'q-9')
  answered.metadata = { ...answered.metadata, approval_status: 'denied' }
  const { state } = drive(st, t0, {
    type: 'tailFetched',
    gen: 0,
    session: { id: 's1', messages: [answered] },
  })
  expect(state.messages[0]?.metadata?.approval_status).toBe('denied')
})

// The D28 scope fence: a blank request_id or a decision outside allow/deny is
// a silent no-op (no POST, no state change).
test('answer scope is allow/deny only', () => {
  const base = initialChatState('s1')
  for (const ev of [
    { type: 'answer', requestId: '', decision: 'allow' },
    { type: 'answer', requestId: 'req-1', decision: 'approve' },
    { type: 'answer', requestId: 'req-1', decision: '' },
  ] as const) {
    const { state, effects } = drive(base, t0, ev)
    expect(effects).toHaveLength(0)
    expect(Object.keys(state.answerInFlight)).toHaveLength(0)
  }
})

// An answer POST failure surfaces honestly and drops the badge so the card
// stays pending (retryable), never stuck "answering…".
test('answer error clears in-flight', () => {
  const st: ChatState = { ...initialChatState('s1'), answerInFlight: { 'req-1': 'deny' } }
  const { state, effects } = drive(st, t0, {
    type: 'answered',
    requestId: 'req-1',
    error: '403 forbidden',
  })
  expect(effects).toHaveLength(0)
  expect(state.answerInFlight['req-1']).toBeUndefined()
  expect(state.notice).toContain('answer failed')
})

// The plan-approve optimism: an allow on a plan card promises Autopilot; a
// deny (keep planning) keeps the ordinary answering notice.
test('plan approve notice promises Autopilot', () => {
  const planCard: ChatMessage = {
    seq: 1,
    role: 'plan',
    metadata: { request_id: 'r1', approval_status: 'pending' },
  }
  const st: ChatState = { ...initialChatState('s1'), messages: [planCard] }
  const allow = drive(st, t0, { type: 'answer', requestId: 'r1', decision: 'allow' })
  expect(allow.state.notice).toContain('Autopilot')

  const deny = drive(st, t0, { type: 'answer', requestId: 'r1', decision: 'deny' })
  expect(deny.state.notice).not.toContain('Autopilot')
})

// The header-truth capture: the init frame's resolved model + permissionMode
// land in state, a frame missing them never blanks known values, and the
// CLI's post-plan "default" is NOT painted.
test('init frame captures model and mode', () => {
  let { state } = drive(
    initialChatState('s1'),
    t0,
    initFrame({ model: 'claude-opus-4-8[1m]', permissionMode: 'plan' }),
  )
  expect(state.model).toBe('claude-opus-4-8[1m]')
  expect(state.mode).toBe('plan')

  ;({ state } = drive(state, t0, initFrame()))
  expect(state.model).toBe('claude-opus-4-8[1m]')
  expect(state.mode).toBe('plan')

  ;({ state } = drive(state, t0, initFrame({ permissionMode: 'default' })))
  expect(state.mode).toBe('plan')
})

// The turn-boundary mode sync: the store row is where the server-side
// plan→autopilot switch lands, and the refetch carries it to the badge.
test('tailFetched refreshes mode', () => {
  let { state } = drive({ ...initialChatState('s1'), mode: 'plan' }, t0, {
    type: 'tailFetched',
    gen: 0,
    session: { id: 's1', mode: 'auto' },
  })
  expect(state.mode).toBe('auto')

  ;({ state } = drive(state, t0, { type: 'tailFetched', gen: 0, session: { id: 's1' } }))
  expect(state.mode).toBe('auto') // a modeless refetch never blanks the badge
})

// Replay-phase `event: message` frames merge with the same monotonic-seq rule
// as the tail refetch — a stale or duplicate row never lands twice.
test('replay message frames are seq-monotonic', () => {
  const row = (seq: number): string => JSON.stringify({ seq, role: 'assistant', source_markdown: `m${seq}` })
  let { state } = drive(
    initialChatState('s1'),
    t0,
    { type: 'frame', name: 'message', data: row(1) },
    { type: 'frame', name: 'message', data: row(2) },
    { type: 'frame', name: 'message', data: row(2) }, // duplicate — inert
    { type: 'frame', name: 'message', data: row(1) }, // stale — inert
  )
  expect(state.messages.map((m) => m.seq)).toEqual([1, 2])
  expect(state.lastSeq).toBe(2)
})

// A permission frame refetches the tail so the answerable card renders from
// replay truth.
test('permission frame triggers tail refetch', () => {
  const st: ChatState = { ...initialChatState('s1'), lastSeq: 4 }
  const { state, effects } = drive(st, t0, { type: 'frame', name: 'permission', data: '{}' })
  expect(state.settling).toBe(true)
  expect(fetchTailOf(effects)?.sinceSeq).toBe(4)
})

// Malformed and unknown frames are inert — forward-compatible, never a crash.
test('malformed and unknown frames are inert', () => {
  const st = { ...initialChatState('s1'), phase: 'streaming' as const, tail: 'keep' }
  const { state, effects } = drive(
    st,
    t0,
    { type: 'frame', name: 'chat', data: 'not json' },
    { type: 'frame', name: 'workflow', data: '{"label":"run"}' },
    { type: 'frame', name: 'mystery', data: '{}' },
  )
  expect(state.tail).toBe('keep')
  expect(state.phase).toBe('streaming')
  expect(effects).toHaveLength(0)
})

// ── the D77 settle race ──────────────────────────────────────────────────────
//
// Run-proven on the Go TUI (chat-tui charter D77): result(turn1) →
// init(turn2, queued send) → stale TailFetchedEvent(turn1) left the tail
// uncleared (turn-1 rendered TWICE) and the next turn-2 delta concatenated
// onto it ("TURN-1-REPLYTURN-2-REPLY"). The generation token is the fix: the
// clear guard is `ev.gen === st.tailGen`, never the phase proxy.

// The canonical run-proven ordering: result(turn1) → init(turn2, off a queued
// send) → the turn-1 settle GET returns. Pre-fix, the `phase === idle` proxy
// failed (the init flipped phase back to streaming) so the tail never cleared
// — turn-1 rendered TWICE and the next turn-2 delta concatenated onto it.
// With the gen guard the fetch's gen (1) matches the tail's generation (the
// tail text IS turn 1's), so it clears exactly on time.
test('D77: turn-1 settle landing after turn-2 init still clears the turn-1 tail', () => {
  let { state, effects } = drive(
    initialChatState('s1'),
    t0,
    initFrame(),
    deltaFrame('TURN-1-REPLY'),
    resultFrame('', false),
  )
  const staleFetch = fetchTailOf(effects)
  expect(staleFetch?.gen).toBe(1)
  expect(state.tail).toBe('TURN-1-REPLY')

  // The queued send's turn 2 inits BEFORE the settle GET returns.
  ;({ state } = drive(state, t0, { type: 'send', content: 'queued question' }, initFrame()))
  expect(state.phase).toBe('streaming')
  expect(state.tail).toBe('TURN-1-REPLY') // no blank flash — still painted
  expect(state.gen).toBe(2)
  expect(state.tailGen).toBe(1) // the tail's text still belongs to turn 1

  // The turn-1 fetch lands: gen 1 === tailGen 1 → the tail settles into its
  // persisted row, ONCE — despite phase being 'streaming' (the pre-fix proxy
  // that broke this).
  ;({ state } = drive(state, t0, {
    type: 'tailFetched',
    gen: staleFetch?.gen ?? 1,
    session: {
      id: 's1',
      messages: [
        { seq: 1, role: 'user', source_markdown: 'first question' },
        { seq: 2, role: 'assistant', source_markdown: 'TURN-1-REPLY' },
      ],
    },
  }))
  expect(state.tail).toBe('')
  expect(state.messages.map((m) => m.seq)).toEqual([1, 2])

  // Turn 2 streams into a FRESH tail — never concatenated onto turn 1.
  ;({ state } = drive(state, t0, deltaFrame('TURN-2-REPLY')))
  expect(state.tail).toBe('TURN-2-REPLY')
  expect(state.tailGen).toBe(2)
})

// The other interleaving: turn-2 deltas arrive BEFORE the stale turn-1 fetch
// lands. The gen mismatch (fetch gen 1, tailGen 2) must NOT clear — clearing
// would wipe live turn-2 text. Convergence comes at turn 2's own settle, with
// every reply exactly once.
test('D77: a stale settle never wipes a streaming newer tail; turn-2 settle converges', () => {
  let { state, effects } = drive(
    initialChatState('s1'),
    t0,
    initFrame(),
    deltaFrame('TURN-1-REPLY'),
    resultFrame('', false),
  )
  const staleFetch = fetchTailOf(effects)

  ;({ state } = drive(
    state,
    t0,
    { type: 'send', content: 'queued question' },
    initFrame(),
    deltaFrame('TURN-2-REPLY'),
  ))
  expect(state.tailGen).toBe(2)

  // The STALE turn-1 fetch lands after turn-2 deltas: rows merge, tail stays.
  ;({ state } = drive(state, t0, {
    type: 'tailFetched',
    gen: staleFetch?.gen ?? 1,
    session: {
      id: 's1',
      messages: [
        { seq: 1, role: 'user', source_markdown: 'first question' },
        { seq: 2, role: 'assistant', source_markdown: 'TURN-1-REPLY' },
      ],
    },
  }))
  expect(state.messages.map((m) => m.seq)).toEqual([1, 2])
  expect(state.tail).toContain('TURN-2-REPLY') // live turn-2 text never wiped

  // Turn 2 results; its OWN settle fetch (gen 2) clears the tail — every
  // reply exists exactly once.
  ;({ state, effects } = drive(state, t0, resultFrame('', false)))
  const freshFetch = fetchTailOf(effects)
  expect(freshFetch?.gen).toBe(2)
  ;({ state } = drive(state, t0, {
    type: 'tailFetched',
    gen: freshFetch?.gen ?? 2,
    session: {
      id: 's1',
      messages: [
        { seq: 3, role: 'user', source_markdown: 'queued question' },
        { seq: 4, role: 'assistant', source_markdown: 'TURN-2-REPLY' },
      ],
    },
  }))
  expect(state.tail).toBe('')
  expect(state.messages.map((m) => m.seq)).toEqual([1, 2, 3, 4])
  const bodies = state.messages.map((m) => m.source_markdown)
  expect(bodies.filter((b) => b === 'TURN-1-REPLY')).toHaveLength(1)
  expect(bodies.filter((b) => b === 'TURN-2-REPLY')).toHaveLength(1)
})

// The wedge-degrade and answered-refetch paths carry the CURRENT gen too, so
// their returns clear the tail only for the generation they were issued in.
test('D77: wedge and answer refetches stamp the issuing generation', () => {
  // Wedge path.
  let { state } = drive(initialChatState('s1'), t0, initFrame(), deltaFrame('x'))
  let interrupted = drive(state, t0, { type: 'interrupt' })
  const wedged = drive(interrupted.state, t0 + WEDGE_TIMEOUT_MS, { type: 'tick' })
  expect(fetchTailOf(wedged.effects)?.gen).toBe(1)

  // Answered path.
  const answered = drive(
    { ...initialChatState('s1'), gen: 3, tailGen: 3 },
    t0,
    { type: 'answered', requestId: 'r1' },
  )
  expect(fetchTailOf(answered.effects)?.gen).toBe(3)
})

// ── the runtime lane (codex + remote/RemoteRef) ──────────────────────────────
// The wire has TWO live text lanes. `event: chat` is raw claude stream-json;
// `event: runtime` is the normalized Runtime.Event struct codex and RemoteRef
// emit, with the text at native.params.delta. Before this lane existed a codex
// frame fell through reduceFrame inert: no tail, no phase flip, and — the
// correctness half — no settle at all, so the persisted answer never landed and
// the composer stayed stuck out of idle.

test('runtime text deltas stream and turn_completed settles the turn', () => {
  // A codex session sends without a claude system/init frame ever arriving —
  // the phase must still leave 'waiting' on the first delta.
  let { state } = drive(initialChatState('s1'), t0, { type: 'send', content: 'hi' })
  expect(state.phase).toBe('waiting')

  let effects: ChatEffect[]
  ;({ state, effects } = drive(
    state,
    t0,
    runtimeTextFrame('text_delta', 'Hel'),
    runtimeTextFrame('text_delta', 'lo, '),
    runtimeTextFrame('text_delta', 'world'),
  ))
  expect(state.tail).toBe('Hello, world')
  expect(state.phase).toBe('streaming')
  expect(effects).toHaveLength(0) // a delta must trigger no IO — the tail is live truth
  expect(state.tailGen).toBe(state.gen) // stamped exactly as the claude lane stamps it

  // The codex turn boundary. The Recorder persists the codex row, so the settle
  // refetch is what makes the answer durable on screen.
  ;({ state, effects } = drive(
    state,
    t0,
    runtimeFrame('turn_completed', { durability: 'durable', terminal_state: 'completed' }),
  ))
  expect(state.phase).toBe('idle')
  expect(state.settling).toBe(true)
  const fetch = fetchTailOf(effects)
  expect(fetch).toBeDefined()
  expect(fetch?.sinceSeq).toBe(state.lastSeq)
  expect(fetch?.gen).toBe(state.gen) // carries the issuing generation (D77)
  expect(state.tail).toBe('Hello, world') // still painted — never a blank flash

  // …and the settle clears it, exactly like the claude lane.
  ;({ state } = drive(state, t0, {
    type: 'tailFetched',
    gen: fetch?.gen ?? 0,
    session: {
      id: 's1',
      messages: [{ seq: 1, role: 'assistant', source_markdown: 'Hello, world' }],
    },
  }))
  expect(state.tail).toBe('')
  expect(state.messages).toHaveLength(1)
})

// THE TRAP: thinking_delta (reasoning) and tool_delta (command output) carry
// their text at the SAME native.params.delta location as the answer. Match the
// kind loosely and reasoning splices into the answer document.
test('runtime kind matching is exact — thinking_delta and tool_delta never enter the tail', () => {
  let { state } = drive(
    initialChatState('s1'),
    t0,
    initFrame(),
    runtimeTextFrame('text_delta', 'The answer is '),
  )
  expect(state.tail).toBe('The answer is ')

  let effects: ChatEffect[]
  ;({ state, effects } = drive(
    state,
    t0,
    runtimeTextFrame('thinking_delta', 'let me reconsider the premise…'),
    runtimeTextFrame('tool_delta', '$ rm -rf build\nremoved 412 files'),
    runtimeFrame('item_started', { native: { params: { item: { id: 'i1' } } } }),
    runtimeFrame('usage', { usage: { input_tokens: 10 } }),
  ))
  expect(state.tail).toBe('The answer is ') // EXACTLY unmoved
  expect(effects).toHaveLength(0)

  // The answer keeps streaming around them — the tail is not frozen, just picky.
  ;({ state } = drive(state, t0, runtimeTextFrame('text_delta', '42.')))
  expect(state.tail).toBe('The answer is 42.')
})

// An interrupted or failed codex turn is still a settle: the phase returns to
// idle, the notice is honest, and the transcript refetches.
test('runtime turn_completed carries the terminal state honestly', () => {
  const streaming: ChatState = { ...initialChatState('s1'), phase: 'streaming', tail: 'partial' }

  const interrupted = drive(
    streaming,
    t0,
    runtimeFrame('turn_completed', { terminal_state: 'interrupted' }),
  )
  expect(interrupted.state.phase).toBe('idle')
  expect(interrupted.state.notice).toContain('Interrupted')
  expect(fetchTailOf(interrupted.effects)).toBeDefined()

  const failed = drive(streaming, t0, runtimeFrame('turn_completed', { terminal_state: 'failed' }))
  expect(failed.state.notice).toContain('error')
  expect(fetchTailOf(failed.effects)).toBeDefined()

  const ok = drive(streaming, t0, runtimeFrame('turn_completed', { terminal_state: 'completed' }))
  expect(ok.state.notice).toBe('')
})

// A malformed runtime frame is inert, like every other unknown frame — the
// decoder never throws and never moves the tail on garbage.
test('runtime frames survive malformed and missing payloads', () => {
  const base: ChatState = { ...initialChatState('s1'), phase: 'streaming', tail: 'kept' }
  const garbage = drive(base, t0, { type: 'frame', name: 'runtime', data: 'not json' })
  expect(garbage.state).toEqual(base)

  const noNative = drive(base, t0, runtimeFrame('text_delta'))
  expect(noNative.state.tail).toBe('kept')

  const wrongType = drive(base, t0, runtimeFrame('text_delta', { native: { params: { delta: 42 } } }))
  expect(wrongType.state.tail).toBe('kept')
})

// D64's client half. The display cap is LiveView-LOCAL today — the controller
// forwards raw frames — so the phone bounds its own tail or a runaway turn
// grows an unbounded string that re-measures on every delta. FREEZE, not shed
// and not close: what was shown stays shown, one honest line explains the rest,
// the stream keeps running and the turn still settles.
test('the tail freezes at the byte cap and keeps what is shown', () => {
  const chunk = 'x'.repeat(8192)
  let state = drive(initialChatState('s1'), t0, initFrame()).state

  // Drive the accumulator right up to the cap without breaching it.
  const wholeChunks = Math.floor(MAX_TAIL_BYTES / chunk.length)
  for (let i = 0; i < wholeChunks; i++) {
    state = drive(state, t0, runtimeTextFrame('text_delta', chunk)).state
  }
  expect(state.tail).toHaveLength(wholeChunks * chunk.length)
  expect(state.tailCapped).toBe(false)

  // The delta that breaches it: the shown text is KEPT verbatim and the honest
  // line lands. Nothing is dropped from what the user already read.
  const frozen = drive(state, t0, runtimeTextFrame('text_delta', chunk)).state
  expect(frozen.tail).toBe(state.tail + TAIL_CAP_NOTICE)
  expect(frozen.tailCapped).toBe(true)
  expect(frozen.tail.length - TAIL_CAP_NOTICE.length).toBeLessThanOrEqual(MAX_TAIL_BYTES)

  // Frozen means frozen: further deltas (either lane) no longer grow the tail,
  // and the marker is written exactly once.
  const more = drive(
    frozen,
    t0,
    runtimeTextFrame('text_delta', chunk),
    deltaFrame('claude text too'),
  ).state
  expect(more.tail).toBe(frozen.tail)
  expect(more.tail.split(TAIL_CAP_NOTICE)).toHaveLength(2)

  // NOT closed and NOT shed: the turn still settles, the full answer arrives
  // from Postgres, and the next turn streams into a fresh, unfrozen tail.
  const settled = drive(more, t0, resultFrame('', false), {
    type: 'tailFetched',
    gen: more.gen,
    session: {
      id: 's1',
      messages: [{ seq: 1, role: 'assistant', source_markdown: 'the untruncated answer' }],
    },
  }).state
  expect(settled.tail).toBe('')
  expect(settled.tailCapped).toBe(false)
  expect(settled.messages[0]?.source_markdown).toBe('the untruncated answer')
  const next = drive(settled, t0, initFrame(), runtimeTextFrame('text_delta', 'fresh')).state
  expect(next.tail).toBe('fresh')
})

// The cap is measured in UTF-8 BYTES (the unit D64's number is stated in), not
// UTF-16 code units: multi-byte text must freeze EARLIER than its char count
// would suggest, never later.
test('the tail cap counts UTF-8 bytes, not characters', () => {
  const emoji = '🐕'.repeat(2048) // 4 bytes each, 2 UTF-16 units each
  let state = drive(initialChatState('s1'), t0, initFrame()).state
  const chunks = Math.floor(MAX_TAIL_BYTES / (2048 * 4)) + 1
  for (let i = 0; i < chunks; i++) {
    state = drive(state, t0, runtimeTextFrame('text_delta', emoji)).state
  }
  expect(state.tailCapped).toBe(true)
  // Frozen well before the UTF-16 length would have reached the cap.
  expect(state.tail.length).toBeLessThan(MAX_TAIL_BYTES)
})

// THE CONTROL LEG: the same drive() harness, the same cap-bearing appendTail,
// and the claude lane still streams and settles — so nothing above is vacuously
// green on a harness that simply cannot observe movement.
test('control: the claude lane still streams and settles through the shared tail', () => {
  let { state, effects } = drive(
    initialChatState('s1'),
    t0,
    initFrame(),
    deltaFrame('Hel'),
    deltaFrame('lo'),
  )
  expect(state.tail).toBe('Hello')
  expect(state.tailBytes).toBe(5)
  expect(state.tailCapped).toBe(false)
  expect(state.phase).toBe('streaming')

  ;({ state, effects } = drive(state, t0, resultFrame('', false)))
  expect(fetchTailOf(effects)?.gen).toBe(1)
  expect(state.settling).toBe(true)
})

// ── the codex turn boundary advances the generation (criterion 1) ────────────
//
// The twin of internal/chat/reduce.go's turn_started arm. Before it, `gen` moved
// at exactly one site — the claude system/init arm — so a codex session's D77
// settle fence was INERT: every turn shared one generation, and `ev.gen ===
// st.tailGen` was true for a settle GET issued a turn ago.
test('a codex turn_started advances the generation and does NOTHING else', () => {
  const before: ChatState = {
    ...initialChatState('s1'),
    gen: 3,
    tailGen: 3,
    tail: 'prior turn, still painted',
    tailBytes: 'prior turn, still painted'.length,
    phase: 'idle',
    notice: 'a standing notice',
    stableTurn: 7,
    committedBytes: 41,
    committedChars: 41,
  }
  const { state: after, effects } = drive(before, t0, runtimeFrame('turn_started'))

  expect(after.gen).toBe(before.gen + 1)
  expect(effects).toHaveLength(0)

  // The tail is untouched: blanking it here would flash away the prior turn's
  // still-painted text, which carries its own generation until its settle lands.
  expect(after.tail).toBe(before.tail)
  expect(after.tailGen).toBe(before.tailGen)
  expect(after.tailBytes).toBe(before.tailBytes)
  expect(after.phase).toBe(before.phase)
  expect(after.notice).toBe(before.notice)

  // THE CURSOR STAYS PUT — keyed on the SERVER turn, never on this client clock
  // (pinned from the other side by __tests__/chatCursorTurnKeyed.test.ts).
  expect(after.stableTurn).toBe(before.stableTurn)
  expect(after.committedBytes).toBe(before.committedBytes)
  expect(after.committedChars).toBe(before.committedChars)
})

// The mobile half of the two-turn codex interleave (criterion 2), driven
// ENTIRELY off runtime frames — no claude system/init anywhere, which is exactly
// the lane the fence used to be inert on. Turn 1 settles late; turn 2 is already
// live when its GET lands; turn 2's text must survive.
test('a stale turn-1 codex settle can no longer clear a live turn-2 tail', () => {
  let { state } = drive(
    initialChatState('s1'),
    t0,
    runtimeFrame('turn_started'),
    runtimeTextFrame('text_delta', 'TURN ONE ANSWER'),
  )

  let effects: ChatEffect[]
  ;({ state, effects } = drive(state, t0, runtimeFrame('turn_completed', { terminal_state: 'completed' })))
  const staleGen = fetchTailOf(effects)?.gen ?? -1
  expect(staleGen).toBeGreaterThanOrEqual(0)

  // Turn 2 starts and streams while turn 1's GET is still in flight.
  ;({ state } = drive(
    state,
    t0,
    runtimeFrame('turn_started'),
    runtimeTextFrame('text_delta', 'TURN TWO IS LIVE'),
  ))
  expect(state.tailGen).not.toBe(staleGen) // the fence is armed, not inert

  // Turn 1's stale GET lands last.
  ;({ state } = drive(state, t0, {
    type: 'tailFetched',
    gen: staleGen,
    session: {
      id: 's1',
      messages: [{ seq: 1, role: 'assistant', source_markdown: 'TURN ONE ANSWER' }],
    },
  }))
  expect(state.messages).toHaveLength(1) // turn one still settles into its row
  expect(state.tail).toContain('TURN TWO IS LIVE') // …and turn two survives
})
