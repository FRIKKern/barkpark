// THE PROGRESSIVE TAIL — the phone's chat tail as a live DOCUMENT
// (mob-w3-rich-tail, mobile charter D58–D61 / D64–D67, chat-TUI D81).
//
// What this suite is defending. While an answer streams, the server settles it in
// append-only SEGMENTS of already-converted PortableDoc blocks; the client draws
// those as documents and keeps only the UNFINISHED remainder plain. Three things
// can go wrong, and only one of them is the kind a "does it render" test catches:
//
//   1. A SILENTLY WRONG DOCUMENT. Live `event: chat` frames carry no id and are
//      never replayed, while this client reconnects on a 1s→16s ladder — so a
//      consumer that trusted the segments it happened to receive would splice a
//      document with a HOLE in it. No throw, no error field, and the same final
//      byte cursor as an ungapped stream, which is exactly why nothing downstream
//      could notice. §1 and §2 are about that, and they are driven from the
//      FROZEN WIRE FIXTURE the Go leg reads, not from a local idea of the wire.
//   2. A POP AT SETTLE. Append-only rendering introduces a hazard the web does
//      not have (the web re-renders the whole prefix every time), so §3 pins the
//      settle as a data no-op: the persisted row stays untouched in state and is
//      simply not drawn a second time.
//   3. A DOCUMENT THAT COSTS MORE EVERY SECOND. §4 measures the real list.
//
// WHY SO MUCH OF IT RUNS THROUGH THE REAL SCREEN. A pure module can be perfectly
// correct and wired in a way that defeats it — that is the lesson mob-rt-s3 paid
// for, where the plain-tail law was guarded by ONE test over a DEAD code path
// (bodyRender's tail arm is unreachable: TranscriptRow returns first), so
// mutating the arm that actually paints reddened nothing at all. §3–§5 therefore
// mount ChatSessionScreen over the real store and read the real LegendList's
// data, exactly as chatScreenWiring's probes do.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

import { Fragment } from 'react'
import { Animated } from 'react-native'
import { act, create, type ReactTestInstance, type ReactTestRenderer } from 'react-test-renderer'

import { LegendList } from '@legendapp/list/react-native'

import fixture from '../../../internal/pdrender/testdata/chat_stable_frames.json'

import { getChatSession, streamChatEvents, type ChatStreamOptions } from '../src/api/chat'
import type { InstanceConnection } from '../src/api/instance'
import {
  MAX_STABLE_SEGMENTS,
  initialChatState,
  reduce,
  tailRemainder,
  type ChatEvent,
  type ChatState,
} from '../src/chat/reducer'
import type { ChatMessage, StableWireEvent } from '../src/chat/wire'
import { isStableEvent } from '../src/chat/wire'
import {
  ChatSessionScreen,
  TRANSCRIPT_ROW_GAP,
  assembleRows,
  groupSegmentRows,
  rowLead,
  stableSegmentRows,
  transcriptItem,
  transcriptItemType,
  type Row,
  type RowCtx,
} from '../src/screens/ChatSessionScreen'
import { chatBlockCtx } from '../src/screens/ChatSessionScreen'
import { light } from '../src/ui/theme'

jest.mock('../src/api/chat', () => ({
  getChatSession: jest.fn(),
  sendChatMessage: jest.fn(),
  interruptChat: jest.fn(),
  respondChatApproval: jest.fn(),
  streamChatEvents: jest.fn(),
  patchChatSession: jest.fn(() => Promise.resolve()),
  fetchChatCapabilities: jest.fn(() => Promise.resolve(undefined)),
}))
jest.mock('react-native-webview', () => ({ WebView: () => null }))
jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(() => Promise.resolve()),
  notificationAsync: jest.fn(() => Promise.resolve()),
  selectionAsync: jest.fn(() => Promise.resolve()),
  ImpactFeedbackStyle: { Light: 'light', Medium: 'medium', Heavy: 'heavy' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning', Error: 'error' },
}))

/* ── the recorded contract ───────────────────────────────────────────────────── */

interface FixtureGap {
  frame_index: number
  turn: number
  expected_from: number
  actual_from: number
}

interface FixtureWalk {
  outcome: string
  accepted_stable_frames: number
  committed_bytes: number
  final_turn: number
  gap: FixtureGap | null
}

interface FixtureSequence {
  name: string
  sources: Record<string, string>
  skeleton_at_frame?: number
  drops_segments?: boolean
  frames: StableWireEvent[]
  expected: FixtureWalk
  expected_from_only?: FixtureWalk
}

const fx = fixture as unknown as { sequences: FixtureSequence[] }

const seqNamed = (name: string): FixtureSequence => {
  const found = fx.sequences.find((s) => s.name === name)
  if (found === undefined) throw new Error(`fixture sequence ${name} is gone`)
  return found
}

/* ── reducer harness ─────────────────────────────────────────────────────────── */

const T0 = 1_000_000

function drive(st: ChatState, ...events: ChatEvent[]): ChatState {
  let out = st
  for (const ev of events) out = reduce(out, ev, T0).state
  return out
}

const wire = (f: StableWireEvent): ChatEvent => ({
  type: 'frame',
  name: f.event,
  data: JSON.stringify(f.data),
})

const delta = (text: string): ChatEvent => ({
  type: 'frame',
  name: 'chat',
  data: JSON.stringify({
    type: 'stream_event',
    event: { type: 'content_block_delta', delta: { type: 'text_delta', text } },
  }),
})

const INIT: ChatEvent = {
  type: 'frame',
  name: 'chat',
  data: JSON.stringify({ type: 'system', subtype: 'init' }),
}

const RESULT: ChatEvent = { type: 'frame', name: 'chat', data: JSON.stringify({ type: 'result' }) }

/** The state's outcome in the fixture's own vocabulary. A recorded GAP outranks a
 * terminal reason on purpose: a `stable_end reason=settled` that arrives after the
 * client already found a hole does not un-find it. */
function outcomeOf(st: ChatState): string {
  if (st.stableGap !== null) return 'gap'
  return st.stableEnd !== '' ? st.stableEnd : 'streaming'
}

/**
 * Walk one recorded sequence through the REAL reducer and report the outcome in
 * the fixture's shape, so the recorded `expected` block is the assertion target
 * and the Go leg's answers and this one cannot drift apart.
 *
 * Only `stable` frames that actually appended are counted as accepted, which is
 * what makes the count survive a server-declared degrade dropping the segments
 * afterwards.
 */
function walkThroughReducer(seq: FixtureSequence): FixtureWalk {
  let st = initialChatState('s1')
  let accepted = 0
  let gapAt = -1
  for (let i = 0; i < seq.frames.length; i++) {
    const f = seq.frames[i]!
    const before = st.segments.length
    st = drive(st, wire(f))
    if (isStableEvent(f) && st.segments.length > before) accepted += 1
    if (gapAt === -1 && st.stableGap !== null) gapAt = i
  }
  return {
    outcome: outcomeOf(st),
    accepted_stable_frames: accepted,
    committed_bytes: st.committedBytes,
    final_turn: st.stableTurn,
    gap:
      st.stableGap === null
        ? null
        : {
            frame_index: gapAt,
            turn: st.stableGap.turn,
            expected_from: st.stableGap.expectedFrom,
            actual_from: st.stableGap.actualFrom,
          },
  }
}

/* ══ 1. the accept rule IS the frozen contract ══════════════════════════════════ */

describe('the reducer reaches the RECORDED outcome for every wire sequence (D59)', () => {
  // The assertion target is internal/pdrender/testdata/chat_stable_frames.json —
  // the same bytes internal/pdrender/chat_stable_frames_test.go reads. Two
  // consumers, one recorded truth: if this leg and the Go leg ever disagree about
  // a sequence, one of the surfaces is wrong about the wire and it shows up here
  // rather than on a phone.
  it.each(fx.sequences.map((s) => [s.name, s] as const))('%s', (_name, seq) => {
    expect(walkThroughReducer(seq)).toEqual(seq.expected)
  })

  it('covers the four outcomes that matter, so the sweep above is not vacuous', () => {
    const outcomes = new Set(fx.sequences.map((s) => s.expected.outcome))
    for (const want of ['settled', 'capped', 'degraded', 'gap']) expect(outcomes).toContain(want)
    // …and one of the recorded sequences must be a TURN-BOUNDARY gap, because
    // that is the only one where the `from`-only predicate and the contract
    // disagree. Without it, deleting the turn fence would red nothing.
    expect(fx.sequences.filter((s) => s.expected_from_only)).toHaveLength(1)
  })

  it('advances the cursor by `to`, never by the rendered block text', () => {
    // The run proof recorded in the fixture: frame 0's heading renders 17
    // characters out of 22 source bytes. A client that measured its own output
    // would sit at 17, reject frame 1's from=22, and degrade a PERFECT stream.
    const seq = seqNamed('clean_three_segments_settled')
    const first = seq.frames[0]!
    if (!isStableEvent(first)) throw new Error('fixture frame 0 is no longer a stable frame')
    const rendered = (first.data.blocks[0] as unknown as { text: string }).text
    expect(rendered.length).toBeLessThan(first.data.to)
    const st = drive(initialChatState('s1'), wire(first))
    expect(st.committedBytes).toBe(first.data.to)
    expect(st.committedBytes).not.toBe(rendered.length)
  })

  it('ignores a MALFORMED frame without ever letting it move the cursor', () => {
    // Inertness is the reducer's standing rule for an unparseable frame, and here
    // it is also the safe rule: the bytes the bad frame carried are simply not
    // committed, so the NEXT frame's `from` no longer matches and the hole is
    // caught by the cursor instead of being papered over.
    const seq = seqNamed('clean_three_segments_settled')
    let st = drive(initialChatState('s1'), wire(seq.frames[0]!))
    const good = st
    for (const bad of [
      'not json',
      '{}',
      '{"turn":1,"from":22,"to":91}', // no blocks
      '{"turn":1,"from":22,"to":91,"blocks":[]}', // nothing to draw
      '{"turn":1,"from":22,"to":22,"blocks":[{"type":"paragraph"}]}', // zero-width
      '{"turn":1,"from":"22","to":91,"blocks":[{"type":"paragraph"}]}',
    ]) {
      st = drive(st, { type: 'frame', name: 'stable', data: bad })
      expect(st).toBe(good) // inert: the very same state object
    }
    // And the stream is NOT poisoned — a well-formed continuation still lands.
    st = drive(st, wire(seq.frames[1]!))
    expect(st.segments).toHaveLength(2)
  })

  it('refuses a stable_end whose reason it does not know', () => {
    const st = initialChatState('s1')
    expect(drive(st, { type: 'frame', name: 'stable_end', data: '{"turn":1,"from":0,"reason":"?"}' })).toBe(st)
  })

  it('stops committing at its own segment bound (D64: mobile owns its cap)', () => {
    // The bound is the second unbounded axis a byte cap cannot see: 1 MiB of
    // "a\n\n" advances the boundary hundreds of thousands of times, every frame
    // of it under any byte cap.
    let st = initialChatState('s1')
    let from = 0
    for (let i = 0; i < MAX_STABLE_SEGMENTS + 5; i++) {
      st = drive(st, {
        type: 'frame',
        name: 'stable',
        data: JSON.stringify({
          turn: 1,
          from,
          to: from + 3,
          blocks: [{ type: 'paragraph', content: [{ type: 'text', value: 'a' }] }],
          skeleton: null,
        }),
      })
      from += 3
    }
    expect(st.segments).toHaveLength(MAX_STABLE_SEGMENTS)
    expect(st.stableStopped).toBe(true)
    // FREEZE, never shed: nothing already committed is thrown away.
    expect(st.stableGap).toBeNull()
  })
})

/* ══ 2. the honest degrade ══════════════════════════════════════════════════════ */

describe('a HOLE degrades honestly and never fabricates', () => {
  const seq = seqNamed('midstream_gap_one_frame_dropped')
  const source = seq.sources['1'] as string

  /** The gap sequence driven with its real source text in the tail, so the
   * DISPLAY consequence is observable and not just the cursor's opinion. */
  function driveGap(): ChatState {
    let st = drive(initialChatState('s1'), INIT, delta(source.slice(0, 14)), wire(seq.frames[0]!))
    st = drive(st, delta(source.slice(14)))
    return drive(st, wire(seq.frames[1]!))
  }

  it('keeps every committed segment, renders the REST plain, and patches nothing', () => {
    const st = driveGap()
    // Kept: the heading really did arrive and really was converted.
    expect(st.segments).toHaveLength(1)
    expect(st.committedBytes).toBe(14)
    // The degrade STATE, not merely the absence of a crash.
    expect(st.stableStopped).toBe(true)
    expect(st.stableGap).toEqual({ turn: 1, expectedFrom: 14, actualFrom: 59 })
    // The hole is NOT patched: the survivor frame's blocks are nowhere in state,
    // so the document cannot claim bytes 14–59 it never received.
    expect(JSON.stringify(st.segments)).not.toContain('Tail paragraph')
    // Everything past the cursor is plain text, verbatim and complete — the
    // missing middle is present as SOURCE, which is honest, rather than as a
    // silently omitted block.
    expect(tailRemainder(st)).toBe(source.slice(14))
    expect(tailRemainder(st)).toContain('The middle frame never arrives')
  })

  it('stops consuming for the rest of the turn — a later PERFECT frame is refused', () => {
    // Without the latch, a client that resynchronised mid-turn would produce a
    // document whose middle is missing and whose end is present, which reads as
    // complete. Refusing the rest of the turn is what keeps the plain remainder
    // the single source of the un-committed text.
    const st = driveGap()
    const resync = drive(st, {
      type: 'frame',
      name: 'stable',
      data: JSON.stringify({
        turn: 1,
        from: 14,
        to: 59,
        blocks: [{ type: 'paragraph', content: [{ type: 'text', value: 'late' }] }],
        skeleton: null,
      }),
    })
    expect(resync.segments).toHaveLength(1)
    expect(resync.committedBytes).toBe(14)
  })

  it('drops the skeleton with the trust — no placeholder outlives the degrade', () => {
    const withSkeleton = drive(
      initialChatState('s1'),
      INIT,
      delta('Here is the converter entry point:\n\nIt looks like this:\n```go\n'),
      wire(seqNamed('open_fence_skeleton').frames[0]!),
    )
    expect(withSkeleton.skeleton).not.toBeNull()
    const gapped = drive(withSkeleton, {
      type: 'frame',
      name: 'stable',
      data: JSON.stringify({
        turn: 1,
        from: 999,
        to: 1050,
        blocks: [{ type: 'paragraph', content: [{ type: 'text', value: 'x' }] }],
        skeleton: { kind: 'table', prose: '' },
      }),
    })
    expect(gapped.stableGap).not.toBeNull()
    expect(gapped.skeleton).toBeNull()
  })

  it('refuses a turn whose bytes cannot be located in the tail (the CARRIED tail)', () => {
    // The one thing the wire cannot tell us. A finished turn's text is still
    // painted (its settle refetch has not landed) when the NEXT turn's segments
    // start arriving: their byte offsets index a string that begins with someone
    // else's bytes, so mapping them would draw the new turn's first segment
    // TWICE — once as a block, once as plain remainder. The turn is refused
    // whole instead, and renders as today's plain tail.
    let st = drive(initialChatState('s1'), INIT, delta('turn one text, never settled'), RESULT)
    expect(st.tailCarried).toBe(true)
    st = drive(st, INIT, delta('## Turn two\n\n'))
    st = drive(st, {
      type: 'frame',
      name: 'stable',
      data: JSON.stringify({
        turn: 2,
        from: 0,
        to: 13,
        blocks: [{ type: 'heading', level: 2, text: 'Turn two' }],
        skeleton: null,
      }),
    })
    expect(st.segments).toHaveLength(0)
    expect(st.stableStopped).toBe(true)
    // Nothing is hidden either: the whole tail is still the plain remainder.
    expect(tailRemainder(st)).toBe('turn one text, never settled## Turn two\n\n')
  })

  it('measures the remainder in UTF-8 BYTES, so a multi-byte turn splits correctly', () => {
    // The offsets are byte offsets and a JS index is not; every recorded fixture
    // source is deliberately ASCII, so this is the one law the fixture cannot
    // pin. "Grüße 🇳🇴" is 2-, 3- and 4-byte territory in one string.
    const head = 'Grüße 🇳🇴 alle!\n\n'
    // HAND-DERIVED on purpose — deliberately not computed by any encoder, and
    // certainly not by the reducer's own counter, which would make the assertion
    // agree with a bug: G(1) r(1) ü(2) ß(2) e(1) ␠(1) = 8, the two regional
    // indicators of 🇳🇴 at 4 bytes each = 16, ␠(1) = 17, "alle!"(5) = 22, two
    // newlines = 24. In UTF-16 the same string is 18 code units, so a client that
    // measured code units would stop six bytes early — inside the flag sequence.
    const bytes = 24
    expect(head.length).toBe(18)
    const st = drive(
      initialChatState('s1'),
      INIT,
      delta(head + 'and the rest'),
      {
        type: 'frame',
        name: 'stable',
        data: JSON.stringify({
          turn: 1,
          from: 0,
          to: bytes,
          blocks: [{ type: 'paragraph', content: [{ type: 'text', value: 'Grüße 🇳🇴 alle!' }] }],
          skeleton: null,
        }),
      },
    )
    expect(st.segments).toHaveLength(1)
    // Byte-counted, the committed prefix ends exactly where the prose does — a
    // char-counted cursor would leave a fragment of the flag sequence behind.
    expect(tailRemainder(st)).toBe('and the rest')
  })
})

/* ══ 3. the settle: a data no-op, or an honest fallback ═════════════════════════ */

const conn: InstanceConnection = {
  projectUrl: 'https://bp.example',
  token: 'tkn',
  dataset: 'production',
}

const mockGet = getChatSession as jest.Mock
const mockStream = streamChatEvents as jest.Mock
let streams: ChatStreamOptions[] = []

beforeEach(() => {
  // Fake timers are TEARDOWN, not speed: LegendList's bootstrap-reveal tick never
  // converges on a zero-sized host and would outlive unmount().
  jest.useFakeTimers()
  mockGet.mockReset()
  mockStream.mockReset()
  streams = []
  mockStream.mockImplementation((_c: unknown, _id: unknown, opts: ChatStreamOptions) => {
    streams.push(opts)
    return new Promise(() => {})
  })
})

afterEach(() => {
  jest.clearAllTimers()
  jest.useRealTimers()
})

const liveStream = (): ChatStreamOptions => streams[streams.length - 1]!

async function mount(): Promise<ReactTestRenderer> {
  let tree: ReactTestRenderer
  await act(async () => {
    tree = create(<ChatSessionScreen connection={conn} sessionId="s1" onBack={() => {}} />)
  })
  return tree!
}

/** Push one SSE frame through the REAL store and let React settle. */
async function push(name: string, data: unknown): Promise<void> {
  await act(async () => {
    liveStream().onFrame({ event: name, data: typeof data === 'string' ? data : JSON.stringify(data) })
  })
}

const pushWire = (f: StableWireEvent): Promise<void> => push(f.event, f.data)

const pushDelta = (text: string): Promise<void> =>
  push('chat', {
    type: 'stream_event',
    event: { type: 'content_block_delta', delta: { type: 'text_delta', text } },
  })

function listOf(tree: ReactTestRenderer): ReactTestInstance {
  return tree.root.findByType(LegendList)
}

function dataOf(tree: ReactTestRenderer): Row[] {
  return listOf(tree).props.data as Row[]
}

const keysOf = (tree: ReactTestRenderer): string[] => dataOf(tree).map((r) => r.key)

const ctx: RowCtx = {
  theme: light,
  blockCtx: chatBlockCtx(light),
  inFlight: {},
  onAnswer: () => {},
  onToggleLog: () => {},
}

/** Paint the list's rows through the screen's OWN renderItem seam and serialise
 * the result — styles, structure and text together, which is what makes "nothing
 * popped" a byte comparison rather than a text one.
 *
 * `only` selects which rows to paint. The no-pop comparison passes ANSWER_ROWS,
 * and the reason is honest rather than convenient: the liveness cursor row is
 * SUPPOSED to disappear at settle (the turn stopped being live), so including it
 * would make the comparison fail for the one difference that is correct. The test
 * that uses it asserts separately that the row it excluded carried nothing but
 * that cursor. */
function paintedText(tree: ReactTestRenderer, only?: (row: Row) => boolean): string {
  const render = listOf(tree).props.renderItem as (a: { item: Row }) => React.ReactElement
  const rows = only === undefined ? dataOf(tree) : dataOf(tree).filter(only)
  let out!: ReactTestRenderer
  act(() => {
    out = create(
      <Fragment>
        {rows.map((row) => (
          <Fragment key={row.key}>{render({ item: row })}</Fragment>
        ))}
      </Fragment>,
    )
  })
  const serialised = JSON.stringify(out.toJSON())
  act(() => out.unmount())
  return serialised
}

/** Everything that is the ANSWER — the rows that must survive a settle unchanged.
 * The live-cursor row and the forming placeholder are, by definition, not among
 * them. */
const ANSWER_ROWS = (row: Row): boolean => row.kind !== 'tail' && row.kind !== 'skeleton'

/** The clean three-segment turn, straight off the frozen fixture — real recorded
 * frames rather than a local imitation of them. */
const CLEAN = seqNamed('clean_three_segments_settled')
const CLEAN_SOURCE = CLEAN.sources['1'] as string

/** Stream the recorded turn through the real screen: each segment's source text
 * arrives as deltas BEFORE the frame that settles it, which is the order the
 * server produces (it has to have the bytes before it can convert them). */
async function streamCleanTurn(): Promise<void> {
  await push('chat', { type: 'system', subtype: 'init' })
  for (const f of CLEAN.frames) {
    if (isStableEvent(f)) await pushDelta(CLEAN_SOURCE.slice(f.data.from, f.data.to))
    await pushWire(f)
  }
}

const ASSISTANT_ROW: ChatMessage = {
  seq: 2,
  role: 'assistant',
  source_markdown: CLEAN_SOURCE,
  blocks: [
    { type: 'heading', level: 2, text: 'Streaming stables' },
    { type: 'paragraph', content: [{ type: 'text', value: 'The reply commits in stable segments as the converter settles them.' }] },
  ],
}

const SEED = { id: 's1', messages: [{ seq: 1, role: 'user', source_markdown: 'ask' }] }

test('SETTLE — the segments stay, the persisted row is not drawn twice, NOTHING pops', async () => {
  mockGet.mockResolvedValueOnce(SEED).mockResolvedValue({
    id: 's1',
    messages: [...SEED.messages, ASSISTANT_ROW],
  })
  const tree = await mount()
  try {
    await streamCleanTurn()

    // MID-STREAM: three committed segments as their own keyed rows, plus the
    // plain remainder row (empty here — the recorded turn commits every byte).
    expect(keysOf(tree)).toEqual(['m-1', 's-1-0', 's-1-22', 's-1-91', 'tail'])
    const before = paintedText(tree, ANSWER_ROWS)
    expect(before).toContain('Streaming stables')
    expect(before).toContain('the turn fences the cursor')
    // Converted, not marked up: the hash markers of the source are nowhere in
    // the painted tree.
    expect(before).not.toContain('## Streaming')
    // The row the comparison below excludes carries NOTHING but the cursor — the
    // recorded turn committed every byte, so the plain remainder is empty and the
    // only thing the settle removes is the "still writing" mark itself.
    expect(dataOf(tree).find((r) => r.kind === 'tail')).toEqual({
      key: 'tail',
      kind: 'tail',
      text: '',
    })

    // THE SETTLE. The result frame lands, the refetch brings the persisted row.
    await push('chat', { type: 'result' })
    await act(async () => {
      await Promise.resolve()
    })

    // The persisted row EXISTS — it is in the transcript's data as truth — and it
    // is not drawn, because the segment rows standing in its place are the same
    // bytes the server verified before it said `settled`.
    expect(keysOf(tree)).toEqual(['m-1', 's-1-0', 's-1-22', 's-1-91'])
    expect(keysOf(tree)).not.toContain('m-2')
    // THE NO-POP PROOF: the answer's painted tree — structure, styles and text —
    // is byte-identical across the settle boundary. Not "looks the same": the
    // same bytes.
    expect(paintedText(tree, ANSWER_ROWS)).toBe(before)
  } finally {
    await act(async () => tree.unmount())
  }
})

test('SETTLE — a DEGRADED turn drops its segments and renders the persisted row', async () => {
  const seq = seqNamed('degraded_after_two_segments')
  const source = seq.sources['1'] as string
  mockGet.mockResolvedValueOnce(SEED).mockResolvedValue({
    id: 's1',
    messages: [...SEED.messages, { ...ASSISTANT_ROW, source_markdown: source }],
  })
  const tree = await mount()
  try {
    await push('chat', { type: 'system', subtype: 'init' })
    for (const f of seq.frames) {
      if (isStableEvent(f)) await pushDelta(source.slice(f.data.from, f.data.to))
      await pushWire(f)
    }
    // The server declared its own segmentation untrustworthy, so the two good
    // segments go too: the persisted row is the truth now, and half a document
    // beside it would be worse than none.
    expect(keysOf(tree)).toEqual(['m-1', 'tail'])
    await push('chat', { type: 'result' })
    await act(async () => {
      await Promise.resolve()
    })
    expect(keysOf(tree)).toEqual(['m-1', 'm-2'])
  } finally {
    await act(async () => tree.unmount())
  }
})

test('SETTLE — a CAPPED turn shows no partial document at all', async () => {
  mockGet.mockResolvedValueOnce(SEED).mockResolvedValue({
    id: 's1',
    messages: [...SEED.messages, ASSISTANT_ROW],
  })
  const tree = await mount()
  try {
    await push('chat', { type: 'system', subtype: 'init' })
    await pushDelta('one unbroken block, larger than the cap')
    await pushWire(seqNamed('capped_after_zero_stable_frames').frames[0]!)
    expect(keysOf(tree)).toEqual(['m-1', 'tail'])
    await push('chat', { type: 'result' })
    await act(async () => {
      await Promise.resolve()
    })
    expect(keysOf(tree)).toEqual(['m-1', 'm-2'])
  } finally {
    await act(async () => tree.unmount())
  }
})

test('SETTLE — a GAPPED turn keeps what it committed and still renders the persisted row', async () => {
  const seq = seqNamed('midstream_gap_one_frame_dropped')
  const source = seq.sources['1'] as string
  mockGet.mockResolvedValueOnce(SEED).mockResolvedValue({
    id: 's1',
    messages: [...SEED.messages, { ...ASSISTANT_ROW, source_markdown: source }],
  })
  const tree = await mount()
  try {
    await push('chat', { type: 'system', subtype: 'init' })
    await pushDelta(source.slice(0, 14))
    await pushWire(seq.frames[0]!)
    await pushDelta(source.slice(14))
    await pushWire(seq.frames[1]!)
    // Mid-stream the committed heading stays drawn beside the plain remainder.
    expect(keysOf(tree)).toEqual(['m-1', 's-1-0', 'tail'])
    await pushWire(seq.frames[2]!)
    await push('chat', { type: 'result' })
    await act(async () => {
      await Promise.resolve()
    })
    // At settle the suppression was never armed, so the persisted row draws and
    // the segments give way to it rather than doubling it.
    expect(keysOf(tree)).toEqual(['m-1', 'm-2'])
  } finally {
    await act(async () => tree.unmount())
  }
})

describe('the settle is a DATA no-op — segments are presentation only', () => {
  /** The same turn twice: once with the segment stream, once without a single
   * `stable` frame on the wire. */
  function settleBothWays(): { withSegments: ChatState; without: ChatState } {
    const session = { id: 's1', messages: [ASSISTANT_ROW], title: 'A title', mode: 'plan' }
    const run = (segments: boolean): ChatState => {
      let st = drive(initialChatState('s1'), INIT)
      for (const f of CLEAN.frames) {
        if (isStableEvent(f)) st = drive(st, delta(CLEAN_SOURCE.slice(f.data.from, f.data.to)))
        if (segments) st = drive(st, wire(f))
      }
      st = drive(st, RESULT)
      return drive(st, { type: 'tailFetched', gen: st.gen, session })
    }
    return { withSegments: run(true), without: run(false) }
  }

  it('lands BYTE-IDENTICAL persisted truth either way', () => {
    const { withSegments, without } = settleBothWays()
    // The row itself, the watermark, the title, the mode, the tail: every piece
    // of persisted truth is the same string it would have been. Progressive
    // rendering changed what was DRAWN and nothing about what is KNOWN.
    expect(JSON.stringify(withSegments.messages)).toBe(JSON.stringify(without.messages))
    expect(withSegments.lastSeq).toBe(without.lastSeq)
    expect(withSegments.title).toBe(without.title)
    expect(withSegments.mode).toBe(without.mode)
    expect(withSegments.tail).toBe(without.tail)
    expect(withSegments.tailCapped).toBe(without.tailCapped)
  })

  it('differs in EXACTLY one thing: which rows are drawn', () => {
    const { withSegments, without } = settleBothWays()
    expect(withSegments.suppressed).toEqual([{ seq: 2, turn: 1 }])
    expect(without.suppressed).toEqual([])
    expect(withSegments.segments).toHaveLength(3)
    expect(without.segments).toHaveLength(0)
  })

  it('suppresses NOTHING when the settle batch is ambiguous — it fails closed', () => {
    // Two assistant rows in one batch, or none: which row the turn was is now a
    // guess, and a guess would suppress real content. Drop the segments instead
    // and let the persisted rows draw — today's exact behaviour.
    for (const messages of [
      [] as ChatMessage[],
      [ASSISTANT_ROW, { ...ASSISTANT_ROW, seq: 3 }],
      [{ seq: 2, role: 'tool', source_markdown: 'Read(x)' }],
    ]) {
      let st = drive(initialChatState('s1'), INIT)
      for (const f of CLEAN.frames) {
        if (isStableEvent(f)) st = drive(st, delta(CLEAN_SOURCE.slice(f.data.from, f.data.to)))
        st = drive(st, wire(f))
      }
      st = drive(st, RESULT)
      st = drive(st, { type: 'tailFetched', gen: st.gen, session: { id: 's1', messages } })
      expect(st.suppressed).toEqual([])
      expect(st.segments).toEqual([])
    }
  })

  it('an UNARMED settle DROPS the turn’s segments instead of orphaning them', () => {
    // A gapped turn never arms the suppression, so the persisted row draws — and
    // the segments beside it must GO. They would not be VISIBLE if they stayed
    // (nothing suppresses them, and the live turn has been reset), so no row
    // assertion could ever catch this: an invisible pile that grows by one gapped
    // turn at a time, holding its memo-table rows alive with it. Hence the pin is
    // on the state, and it exists because a mutation run found the branch
    // unguarded.
    const seq = seqNamed('midstream_gap_one_frame_dropped')
    const source = seq.sources['1'] as string
    let st = drive(initialChatState('s1'), INIT, delta(source.slice(0, 14)), wire(seq.frames[0]!))
    st = drive(st, delta(source.slice(14)), wire(seq.frames[1]!), wire(seq.frames[2]!))
    expect(st.segments).toHaveLength(1)
    expect(st.settleArm).toBeNull()
    st = drive(st, RESULT)
    st = drive(st, {
      type: 'tailFetched',
      gen: st.gen,
      session: { id: 's1', messages: [ASSISTANT_ROW] },
    })
    expect(st.segments).toEqual([])
    expect(st.suppressed).toEqual([])
  })

  it('a MID-TURN refetch (an approval ask) keeps the segments it already has', () => {
    // A permission frame refetches while the turn is still streaming and clears
    // the tail on the way. Dropping the committed segments there would wipe a
    // progressive document every time the agent asks to run something — and it
    // would be wrong, because the post-clear tail holds only the deltas that
    // arrive after it, so nothing could be drawn twice.
    let st = drive(initialChatState('s1'), INIT)
    st = drive(st, delta(CLEAN_SOURCE.slice(0, 22)), wire(CLEAN.frames[0]!))
    expect(st.segments).toHaveLength(1)
    st = drive(st, { type: 'frame', name: 'permission', data: '{}' })
    st = drive(st, { type: 'tailFetched', gen: st.gen, session: { id: 's1', messages: [] } })
    expect(st.phase).toBe('streaming')
    expect(st.segments).toHaveLength(1)
    // But consumption stops, because the string the cursor was mapped into is
    // gone. No second latch does this: the accept rule notices on its own.
    st = drive(st, wire(CLEAN.frames[1]!))
    expect(st.segments).toHaveLength(1)
    expect(st.stableGap).toEqual({ turn: 1, expectedFrom: 0, actualFrom: 22 })
  })

  it('a COLD OPEN renders the persisted row — segments are ephemeral by design', () => {
    // Nothing about suppression survives a fresh state, which is the whole reason
    // the persisted row is never modified.
    const cold = initialChatState('s1')
    expect(cold.segments).toEqual([])
    expect(cold.suppressed).toEqual([])
    const rows = assembleRows(
      [{ key: 'm-2', kind: 'message', message: ASSISTANT_ROW }],
      [],
      '',
      undefined,
    )
    expect(rows.map((r) => r.key)).toEqual(['m-2'])
  })
})

/* ══ 4. the row shape (D65) ═════════════════════════════════════════════════════ */

test('ROW SHAPE — a delta costs ONE new row no matter how many segments are committed', async () => {
  // THE MEASUREMENT D65 was decided on, reproduced through the real list. Folding
  // the segments into one fat tail row instead would make per-delta reconciliation
  // LINEAR in the number of segments (measured 10.5 → 80.5 element creations at
  // 20 → 160 segments; 14ms → 637ms wall). Here the count must not move at all
  // between a 1-segment turn and an 8-segment one.
  mockGet.mockResolvedValue(SEED)
  const tree = await mount()
  try {
    await push('chat', { type: 'system', subtype: 'init' })

    const freshAfterDelta = async (): Promise<string[]> => {
      const before = dataOf(tree)
      await pushDelta('x')
      const after = dataOf(tree)
      return after.filter((row, i) => row !== before[i]).map((r) => r.key)
    }

    let from = 0
    const commit = async (): Promise<void> => {
      const to = from + 12
      await pushDelta('paragraph.\n\n')
      await push('stable', {
        turn: 1,
        from,
        to,
        blocks: [{ type: 'paragraph', content: [{ type: 'text', value: 'paragraph.' }] }],
        skeleton: null,
      })
      from = to
    }

    await commit()
    expect(await freshAfterDelta()).toEqual(['tail'])
    const oneSegment = dataOf(tree).length

    for (let i = 0; i < 7; i++) await commit()
    expect(dataOf(tree).length).toBe(oneSegment + 7)
    // EIGHT committed segments later, a delta still mints exactly one row: the
    // segment rows come back from the memo table by IDENTITY, so React skips
    // every one of them.
    expect(await freshAfterDelta()).toEqual(['tail'])
  } finally {
    await act(async () => tree.unmount())
  }
})

describe('segment rows are keyed, bucketed, and identity-stable', () => {
  const seg = (turn: number, from: number, to: number, type: string) => ({
    turn,
    from,
    to,
    blocks: [{ type }],
  })

  it('keys are `s-<turn>-<from>` — the segment’s own wire identity', () => {
    const rows = stableSegmentRows(new Map(), [seg(1, 0, 22, 'heading'), seg(1, 22, 91, 'paragraph')])
    expect(rows.map((r) => r.key)).toEqual(['s-1-0', 's-1-22'])
    // A key that carries the turn is what lets two turns' segments coexist, which
    // is what lets a settled turn keep its rows while the next one streams.
    expect(stableSegmentRows(new Map(), [seg(2, 0, 5, 'heading')])[0]!.key).toBe('s-2-0')
  })

  it('the memo table hands back the SAME row object after a later commit', () => {
    // Not "an equal row" — the same object. memo(TranscriptRow) compares identity
    // and nothing else, so this is the difference between a settled paragraph
    // rendering once and rendering twice a second for the rest of the turn.
    const table = new Map<string, Row>()
    const first = stableSegmentRows(table, [seg(1, 0, 22, 'heading')])
    const second = stableSegmentRows(table, [seg(1, 0, 22, 'heading'), seg(1, 22, 91, 'paragraph')])
    expect(second[0]).toBe(first[0])
    expect(second[1]).not.toBe(first[0])
  })

  it('evicts a dropped turn’s rows so a degrade cannot leak them forward', () => {
    const table = new Map<string, Row>()
    stableSegmentRows(table, [seg(1, 0, 22, 'heading'), seg(1, 22, 91, 'paragraph')])
    expect(table.size).toBe(2)
    stableSegmentRows(table, [])
    expect(table.size).toBe(0)
  })

  it('buckets each segment on the block that OPENS it, never one blended average', () => {
    // Without per-type buckets legend-list averages a one-line heading segment
    // and a forty-line code segment together and positions both off the blend —
    // the same dishonesty the message rows split on roleKind to avoid.
    const rows = stableSegmentRows(new Map(), [
      seg(1, 0, 22, 'heading'),
      seg(1, 22, 91, 'paragraph'),
      seg(1, 91, 300, 'code'),
    ])
    expect(rows.map(transcriptItemType)).toEqual([
      'segment:lead:heading', // opens the turn — its measured height carries the 18px lead
      'segment:paragraph',
      'segment:code',
    ])
    // And the new kinds do not collide with the old ones.
    const all = [
      ...rows,
      { key: 'tail', kind: 'tail', text: 'x' } as Row,
      { key: 'skeleton', kind: 'skeleton', label: 'table', prose: '' } as Row,
    ]
    expect(new Set(all.map(transcriptItemType)).size).toBe(all.length)
  })

  it('splits a turn-opening segment from a continuing one of the SAME block type (mob-lm-s5f)', () => {
    // A segment row's measured height depends on whether it OPENS a turn —
    // rowLead wraps the turn's first segment in the 18px turn-boundary lead and
    // every continuing one in nothing — so one bucket per block type blended
    // two height populations 18px apart and every estimate in it was wrong by
    // a predictable fraction. getItemType receives (item, index) and can never
    // see the predecessor; the ordering fact rides on the row instead.
    const rows = stableSegmentRows(new Map(), [
      seg(1, 0, 22, 'paragraph'),
      seg(1, 22, 91, 'paragraph'),
      seg(2, 0, 40, 'paragraph'),
    ])
    expect(rows.map(transcriptItemType)).toEqual([
      'segment:lead:paragraph', // opens turn 1
      'segment:paragraph', //      continues turn 1 — a DIFFERENT bucket
      'segment:lead:paragraph', // opens turn 2
    ])
    // The flag is the SAME fact rowLead reads off the ordering: within a pure
    // segment run, opensTurn=true rows are exactly the rows rowLead leads 18.
    rows.forEach((row, i) => {
      const lead = rowLead(rows, i)
      if (row.kind !== 'segment') throw new Error('unreachable')
      if (i === 0) return // rowLead returns 0 at the head of the transcript by law
      expect(row.opensTurn).toBe(lead === TRANSCRIPT_ROW_GAP)
    })
    // And it is NOT `from === 0` in disguise: a resumed stream's first held
    // segment starts mid-turn yet still opens it.
    const resumed = stableSegmentRows(new Map(), [seg(3, 120, 200, 'paragraph')])
    if (resumed[0]!.kind !== 'segment') throw new Error('unreachable')
    expect(resumed[0]!.opensTurn).toBe(true)
  })

  it('groups by the turn read back OUT of the key, so grouping cannot drift', () => {
    const rows = stableSegmentRows(new Map(), [seg(1, 0, 5, 'heading'), seg(2, 0, 9, 'paragraph')])
    const byTurn = groupSegmentRows(rows)
    expect([...byTurn.keys()]).toEqual([1, 2])
    expect(byTurn.get(1)!.map((r) => r.key)).toEqual(['s-1-0'])
  })

  it('a suppressed row is replaced IN PLACE, keeping the turn’s position', () => {
    // Appending the segments instead would move a settled answer below rows that
    // came after it.
    const rows = stableSegmentRows(new Map(), [seg(1, 0, 22, 'heading'), seg(1, 22, 91, 'paragraph')])
    const out = assembleRows(
      [
        { key: 'm-1', kind: 'message', message: { seq: 1, role: 'user' } },
        { key: 'm-2', kind: 'message', message: ASSISTANT_ROW },
        { key: 'm-3', kind: 'message', message: { seq: 3, role: 'user' } },
      ],
      [],
      '',
      {
        byTurn: groupSegmentRows(rows),
        suppressed: [{ seq: 2, turn: 1 }],
        liveTurn: 1,
        remainder: '',
        skeleton: null,
      },
    )
    expect(out.map((r) => r.key)).toEqual(['m-1', 's-1-0', 's-1-22', 'm-3'])
    // …and exactly once — a turn that is both suppressed and "live" must not be
    // drawn a second time at the bottom.
    expect(out.filter((r) => r.key === 's-1-0')).toHaveLength(1)
  })

  it('a committed segment renders BYTE-IDENTICALLY however many deltas follow', () => {
    const row = stableSegmentRows(new Map(), [
      { turn: 1, from: 0, to: 22, blocks: [{ type: 'heading', level: 2, text: 'Streaming stables' }] },
    ])[0]!
    const paint = (): string => {
      let r!: ReactTestRenderer
      act(() => {
        r = create(<Fragment>{transcriptItem(row, ctx)}</Fragment>)
      })
      const json = JSON.stringify(r.toJSON())
      act(() => r.unmount())
      return json
    }
    const first = paint()
    for (let i = 0; i < 5; i++) expect(paint()).toBe(first)
    expect(first).toContain('Streaming stables')
    // The rendered heading is a document, not the source it came from.
    expect(first).not.toContain('## Streaming')
  })
})

/* ══ 5. the skeleton, wired ═════════════════════════════════════════════════════ */

describe('the forming-block placeholder (D67)', () => {
  const FENCE = seqNamed('open_fence_skeleton')
  const FENCE_SOURCE = FENCE.sources['1'] as string

  it('REPLACES the plain remainder row and carries the frame’s own kind + prose', async () => {
    mockGet.mockResolvedValue(SEED)
    const tree = await mount()
    try {
      await push('chat', { type: 'system', subtype: 'init' })
      await pushDelta(FENCE_SOURCE.slice(0, 36))
      await pushWire(FENCE.frames[0]!)
      await pushDelta('It looks like this:\n```go\n')

      // One placeholder row where the plain tail row would be — the half-open
      // fence belongs BEHIND the box, and its prose above it.
      expect(keysOf(tree)).toEqual(['m-1', 's-1-0', 'skeleton'])
      const skeleton = dataOf(tree).find((r) => r.kind === 'skeleton')
      expect(skeleton).toEqual({
        key: 'skeleton',
        kind: 'skeleton',
        label: 'code',
        prose: 'It looks like this:\n',
      })
      // AT MOST ONE, always: the wire guarantees a single skeleton per frame and
      // the row list must not accumulate them.
      expect(dataOf(tree).filter((r) => r.kind === 'skeleton')).toHaveLength(1)
      // The painted box announces itself honestly and the raw fence never shows.
      const painted = paintedText(tree)
      expect(painted).toContain('rendering code')
      expect(painted).toContain('It looks like this:')
      expect(painted).not.toContain('```')

      // The fence closes: the frame settles both blocks and the skeleton goes
      // null, so the placeholder is gone and the code is a real block.
      await pushDelta(FENCE_SOURCE.slice(36, 115))
      await pushWire(FENCE.frames[1]!)
      expect(dataOf(tree).filter((r) => r.kind === 'skeleton')).toHaveLength(0)
      expect(paintedText(tree)).toContain('func Render(doc Doc) string')
    } finally {
      await act(async () => tree.unmount())
    }
  })

  it('accepts an EMPTY prose string, and an unknown kind, without inventing either', () => {
    // prose is legitimately '' whenever the forming block starts exactly at `to`,
    // and a consumer that required it non-empty would reject a valid frame. An
    // unknown kind is equally legal: StreamSkeleton degrades it to the generic
    // "block" shape, exactly as the server's own skeleton_label/1 fallback does.
    const st = drive(initialChatState('s1'), INIT, delta('| a | b |\n'), {
      type: 'frame',
      name: 'stable',
      data: JSON.stringify({
        turn: 1,
        from: 0,
        to: 0 + 1,
        blocks: [{ type: 'paragraph', content: [{ type: 'text', value: 'x' }] }],
        skeleton: { kind: 'from-a-newer-server' },
      }),
    })
    expect(st.skeleton).toEqual({ kind: 'from-a-newer-server', prose: '' })
    const rows = assembleRows([], [], 'tail text', {
      byTurn: new Map(),
      suppressed: [],
      liveTurn: 1,
      remainder: 'tail text',
      skeleton: st.skeleton,
    })
    expect(rows).toEqual([
      { key: 'skeleton', kind: 'skeleton', label: 'from-a-newer-server', prose: '' },
    ])
  })

  it('STOPS its animation driver when the turn settles — no driver per turn', async () => {
    // The app's first Animated.loop, and a loop that is never stopped leaks once
    // per turn with no crash and no red anywhere. streamSkeleton.test.tsx pins the
    // component's own teardown; this pins that the WIRING actually reaches it, by
    // driving a real turn to settle through the real row path and watching the
    // driver the component was handed.
    const start = jest.fn()
    const stop = jest.fn()
    const loop = jest
      .spyOn(Animated, 'loop')
      .mockImplementation(() => ({ start, stop, reset: jest.fn() }) as unknown as Animated.CompositeAnimation)
    try {
      const skeletonRow: Row = { key: 'skeleton', kind: 'skeleton', label: 'table', prose: '' }
      let r!: ReactTestRenderer
      act(() => {
        r = create(<Fragment>{transcriptItem(skeletonRow, ctx)}</Fragment>)
      })
      expect(start).toHaveBeenCalledTimes(1)
      expect(stop).not.toHaveBeenCalled()
      // The turn settles: the row list no longer carries a skeleton, so the
      // placeholder unmounts and the cleanup fires.
      act(() => {
        r.update(<Fragment />)
      })
      expect(stop).toHaveBeenCalledTimes(1)
      act(() => r.unmount())
    } finally {
      loop.mockRestore()
    }
  })
})

/* ══ 6. the ONE-CONVERTER law ═══════════════════════════════════════════════════ */

test('NO client-side markdown parser exists anywhere in the chat screen’s stack', () => {
  // THE WHOLE POINT OF THE DESIGN, and behaviour cannot prove it: a TypeScript
  // markdown parser good enough to pass every assertion in this file is exactly
  // the fork the server-side segment stream exists to prevent. Only the SOURCE
  // can say so. Comments are stripped first, because this file's own header and
  // the modules' own doc comments name the things they forswear.
  const files = [
    ['src', 'chat', 'reducer.ts'],
    ['src', 'chat', 'wire.ts'],
    ['src', 'chat', 'StreamSkeleton.tsx'],
    ['src', 'screens', 'ChatSessionScreen.tsx'],
  ]
  const deps = new Set<string>()
  for (const parts of files) {
    const src = readFileSync(join(__dirname, '..', ...parts), 'utf8')
    const code = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '')
    for (const forbidden of [
      /\bmarked\b/i,
      /markdown-it/i,
      /\bremark\b/i,
      /\bmicromark\b/i,
      /\bcommonmark\b/i,
      /\bshowdown\b/i,
      /\bmdast\b/i,
      /fromMarkdown/,
      /parseMarkdown/,
      /toMarkdown/,
    ]) {
      expect(code).not.toMatch(forbidden)
    }
    for (const m of code.matchAll(/^import[^'"]*['"]([^'"]+)['"]/gm)) deps.add(m[1] as string)
  }
  // The whole dependency surface of the progressive path, enumerated: a new
  // import here is a decision, and it should show up in a diff.
  expect([...deps].sort()).toEqual(
    [
      './wire',
      '../api/chat',
      '../api/instance',
      '../chat/PickerSheet',
      '../chat/StreamSkeleton',
      '../chat/followScroll',
      '../chat/reducer',
      '../chat/useChatSession',
      '../chat/wire',
      '../chat/workLog',
      '../papers/portabledoc/blocks',
      '../papers/portabledoc/model',
      '../ui/haptics',
      '../ui/theme',
      '../ui/typography',
      '@legendapp/list/react-native',
      'react',
      'react-native',
    ].sort(),
  )
})

/* ══ 7. the NO-OP against a server that never emits stable frames ══════════════ */

test('NO-OP — the pre-existing frame vocabulary produces exactly today’s rows', async () => {
  // The deployment permutation that matters most on the day this merges: the
  // server emitter is not built, so nothing on the wire says `stable`. Every
  // progressive field must stay inert and the transcript must be the two-phase
  // tail it has always been.
  mockGet.mockResolvedValueOnce(SEED).mockResolvedValue({
    id: 's1',
    messages: [...SEED.messages, ASSISTANT_ROW],
  })
  const tree = await mount()
  try {
    await push('chat', { type: 'system', subtype: 'init' })
    await pushDelta('half a **bol')
    expect(keysOf(tree)).toEqual(['m-1', 'tail'])
    // The tail row is the WHOLE tail, plain and verbatim — not a remainder of
    // something, because nothing was committed.
    expect(dataOf(tree).find((r) => r.kind === 'tail')).toEqual({
      key: 'tail',
      kind: 'tail',
      text: 'half a **bol',
    })
    await push('chat', { type: 'result' })
    await act(async () => {
      await Promise.resolve()
    })
    // Two-phase settle, untouched: the tail is replaced by the persisted row.
    expect(keysOf(tree)).toEqual(['m-1', 'm-2'])
  } finally {
    await act(async () => tree.unmount())
  }
})

test('NO-OP — the reducer state is inert without a single stable frame', () => {
  const st = drive(
    initialChatState('s1'),
    INIT,
    delta('streaming words'),
    { type: 'frame', name: 'runtime', data: JSON.stringify({ kind: 'text_delta', native: { params: { delta: ' more' } } }) },
    { type: 'frame', name: 'permission', data: '{}' },
    { type: 'frame', name: 'message', data: JSON.stringify({ seq: 9, role: 'tool' }) },
    { type: 'frame', name: 'workflow', data: '{}' },
  )
  expect(st.tail).toBe('streaming words more')
  // tailRemainder is the identity function while nothing is committed, which is
  // what makes the whole layer a no-op rather than a differently-shaped path.
  expect(tailRemainder(st)).toBe(st.tail)
  expect(st.segments).toEqual([])
  expect(st.stableTurn).toBe(-1)
  expect(st.committedBytes).toBe(0)
  expect(st.committedChars).toBe(0)
  expect(st.skeleton).toBeNull()
  expect(st.stableGap).toBeNull()
  expect(st.settleArm).toBeNull()
  expect(st.suppressed).toEqual([])
  expect(assembleRows([], [], st.tail)).toEqual([{ key: 'tail', kind: 'tail', text: st.tail }])
})
