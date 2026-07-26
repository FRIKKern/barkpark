// SCREEN-LEVEL WIRING PROBES (t3w2-s4, review round).
//
// The sibling suites pin pure functions and hook-free renderers. That leaves
// exactly one gap, and it is the expensive one: a pure module can be perfectly
// correct and still be WIRED in a way that defeats it — no type error, no red
// test. Both bugs found in this slice's own review lived precisely there.
//
// So these three probes mount the REAL ChatSessionScreen, over the REAL store,
// and read the REAL LegendList's props:
//
//   A — the list is configured the way the ratified config says (identity, not
//       a look-alike literal), and onScroll is actually attached.
//   B — the work log folds through the whole stack when a REAL system/init
//       frame advances the D77 clock; and the clock going BACKWARDS (retry
//       rebuilds the store at gen 0 while this screen does NOT remount) does
//       not resurrect stamps taken under the old clock.
//   C — the pill's two-condition rule survives the wiring: a scroll that
//       disengages raises nothing on its own, and one delta below raises it.
//
// TEARDOWN IS LOAD-BEARING: the store owns a real setInterval, so every mount
// unmounts in a finally. A probe that throws before unmount() strands the
// interval and hangs the whole run.
import { act, create, type ReactTestInstance, type ReactTestRenderer } from 'react-test-renderer'

import { LegendList } from '@legendapp/list/react-native'

import { getChatSession, streamChatEvents, type ChatStreamOptions } from '../src/api/chat'
import type { InstanceConnection } from '../src/api/instance'
import type { ChatMessage } from '../src/chat/wire'
import { ChatSessionScreen, TRANSCRIPT_FOLLOW } from '../src/screens/ChatSessionScreen'

// (hoisted by jest above the imports)
// The factory must cover EVERY api/chat binding the screen's stack reaches —
// a missing one is not a type error (jest.mock erases the module's shape), it
// is a runtime "is not a function" inside an effect. t3w2-s7 added the picker
// discovery read and the choice PATCH; both land here.
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

const mockGet = getChatSession as jest.Mock
const mockStream = streamChatEvents as jest.Mock

const conn: InstanceConnection = {
  projectUrl: 'https://bp.example',
  token: 'tkn',
  dataset: 'production',
}

const msg = (seq: number, role: string): ChatMessage => ({
  seq,
  role,
  source_markdown: `row ${seq}`,
})

/** Every stream the screen has opened, newest last — retry opens a second one,
 * and only the newest one's callbacks are live (the D25 per-start fence). */
let streams: ChatStreamOptions[] = []

beforeEach(() => {
  // FAKE TIMERS ARE TEARDOWN, not speed. LegendList runs a bootstrap-reveal
  // convergence `tick` on setTimeout; on a zero-sized test host it never
  // converges, and with real timers it outlives unmount() and leaves jest
  // force-exiting a leaked worker. Fake timers put those under jest's own
  // teardown. The store's own IO is promise-based, so the seed GET still
  // settles on the microtask queue that act() flushes.
  jest.useFakeTimers()
  mockGet.mockReset()
  mockStream.mockReset()
  streams = []
  mockStream.mockImplementation((_c: unknown, _id: unknown, opts: ChatStreamOptions) => {
    streams.push(opts)
    return new Promise(() => {}) // a live stream never resolves on its own
  })
})

afterEach(() => {
  jest.clearAllTimers()
  jest.useRealTimers()
})

const live = (): ChatStreamOptions => streams[streams.length - 1]!

async function mount(): Promise<ReactTestRenderer> {
  let tree: ReactTestRenderer
  await act(async () => {
    tree = create(
      <ChatSessionScreen connection={conn} sessionId="s1" onBack={() => {}} />,
    )
  })
  return tree!
}

/** Push one SSE frame through the REAL store and let React settle. */
async function frame(name: string, data: unknown): Promise<void> {
  await act(async () => {
    live().onFrame({ event: name, data: typeof data === 'string' ? data : JSON.stringify(data) })
  })
}

const INIT = { type: 'system', subtype: 'init' }

function list(tree: ReactTestRenderer): ReactTestInstance {
  return tree.root.findByType(LegendList)
}

function rowKeys(tree: ReactTestRenderer): string[] {
  return (list(tree).props.data as { key: string }[]).map((r) => r.key)
}

function textOf(node: ReactTestInstance | string): string {
  if (typeof node === 'string') return node
  return node.children.map(textOf).join('')
}

function pillCount(tree: ReactTestRenderer): number {
  return tree.root.findAll(
    (n: ReactTestInstance) => n.props.accessibilityLabel === 'Jump to the latest message',
    { deep: false },
  ).length
}

/* ── Probe A: the list is configured as ratified ────────────────────────────── */

test('PROBE A — the transcript IS a LegendList carrying the ratified follow config', async () => {
  mockGet.mockResolvedValue({ id: 's1', messages: [msg(1, 'user')] })
  const tree = await mount()
  try {
    const l = list(tree)
    // IDENTITY, not equality: a look-alike inline literal would pass a toEqual
    // and would be a different object every render, which is how the `on` key
    // sneaks back in unnoticed.
    expect(l.props.maintainScrollAtEnd).toBe(TRANSCRIPT_FOLLOW)
    expect(l.props.maintainScrollAtEndThreshold).toBe(0.1)
    expect(typeof l.props.onScroll).toBe('function')
    // Without these the list boots mid-transcript and re-measures every row.
    expect(l.props.initialScrollAtEnd).toBe(true)
    expect(typeof l.props.renderItem).toBe('function')
  } finally {
    await act(async () => tree.unmount())
  }
})

/* ── Probe B: the fold, through the whole stack ─────────────────────────────── */

test('PROBE B — a REAL init frame folds the work log through the whole stack', async () => {
  mockGet.mockResolvedValue({
    id: 's1',
    messages: [msg(1, 'user'), msg(2, 'tool'), msg(3, 'tool')],
  })
  const tree = await mount()
  try {
    // The turn in flight: the header plus its members, in order.
    expect(rowKeys(tree)).toEqual(['m-1', 'log-m-2', 'm-2', 'm-3'])

    // The D77 fence's OWN increment — a real system/init frame through the
    // real reducer, not a hand-set gen.
    await frame('chat', INIT)
    expect(rowKeys(tree)).toEqual(['m-1', 'log-m-2'])
  } finally {
    await act(async () => tree.unmount())
  }
})

test('PROBE B2 — the clock going BACKWARDS (retry) does not resurrect stamps from the old clock', async () => {
  // The regression this pins: retry() rebuilds the store inside
  // useChatSession, so state restarts at gen 0 — but the SCREEN does not
  // remount, so `fold` survives with births stamped against the old clock.
  //
  // The sequence is six steps because the shorter one is VACUOUS: immediately
  // after retry every group reads open under both the fixed and the broken
  // code (at gen 0, born >= 0 holds either way). The stale stamp only becomes
  // visible once the NEW clock advances past it — which is exactly when a user
  // would see a finished turn's work log still hanging open.
  mockGet.mockResolvedValue({ id: 's1', messages: [msg(1, 'user')] })
  const tree = await mount()
  try {
    // 1-2. A turn runs; its apparatus rows arrive under gen 1.
    await frame('chat', INIT) // gen 0 -> 1
    await frame('message', msg(2, 'tool'))
    await frame('message', msg(3, 'tool'))
    expect(rowKeys(tree)).toEqual(['m-1', 'log-m-2', 'm-2', 'm-3']) // born at gen 1, open

    // 3. The next turn folds it.
    await frame('chat', INIT) // gen 1 -> 2
    expect(rowKeys(tree)).toEqual(['m-1', 'log-m-2'])

    // 4. The stream refuses with a 401 and the user taps "signed out — sign in
    //    again". retry() mints a fresh store: gen falls 2 -> 0.
    mockGet.mockResolvedValue({
      id: 's1',
      messages: [msg(1, 'user'), msg(2, 'tool'), msg(3, 'tool')],
    })
    const onStatus = live().onStatus
    // onStatus is optional on the transport contract; if the store ever stops
    // subscribing, this probe must fail loudly rather than quietly skip the
    // refusal it exists to drive.
    if (onStatus === undefined) throw new Error('the store did not subscribe to stream status')
    await act(async () => {
      onStatus('refused', { class: 'refused', httpStatus: 401, message: 'nope' })
    })
    const retryBtn = tree.root
      .findAll((n: ReactTestInstance) => typeof n.props.onPress === 'function')
      .find((n: ReactTestInstance) => textOf(n).includes('signed out'))
    if (retryBtn === undefined) throw new Error('no re-auth affordance rendered on a 401 refusal')
    const press = retryBtn.props.onPress as () => void
    await act(async () => press())
    await act(async () => {}) // let the fresh store's seed GET land

    // 5. At gen 0 everything reads live — fixed and broken agree here.
    expect(rowKeys(tree)).toEqual(['m-1', 'log-m-2', 'm-2', 'm-3'])

    // 6. THE DISCRIMINATOR. The new session's first turn advances gen 0 -> 1.
    //    With the guard, the fold was dropped at the regression and re-stamped
    //    at 0, so the group is behind a finished turn and folds. WITHOUT it the
    //    stale born=1 survives, 1 >= 1 holds, and the log hangs open — a
    //    previous session's work presented as the turn in flight.
    await frame('chat', INIT)
    expect(rowKeys(tree)).toEqual(['m-1', 'log-m-2'])
  } finally {
    await act(async () => tree.unmount())
  }
})

/* ── Probe D: what a token frame ACTUALLY costs, end to end ─────────────────── */

test('PROBE D — a token frame re-mints the tail and one header per group; settled rows keep identity', async () => {
  // This exists because the first version of this slice's PR claimed "a tail
  // tick mints exactly ONE new row". That is true of assembleRows in
  // isolation, and FALSE of the list the screen actually renders: foldWorkLog
  // recomputes per frame and its header constructor mints a fresh object each
  // time. Measuring the real number here is what keeps the claim honest, and
  // is what a header-object cache (filed as a follow-up) would move.
  mockGet.mockResolvedValue({
    id: 's1',
    messages: [msg(1, 'user'), msg(2, 'tool'), msg(3, 'tool'), msg(4, 'assistant'), msg(5, 'tool')],
  })
  const tree = await mount()
  try {
    const delta = (text: string) => ({
      type: 'stream_event',
      event: { type: 'content_block_delta', delta: { type: 'text_delta', text } },
    })
    await frame('chat', delta('a'))
    const before = list(tree).props.data as { key: string }[]
    await frame('chat', delta('b'))
    const after = list(tree).props.data as { key: string }[]

    expect(after.map((r) => r.key)).toEqual([
      'm-1', 'log-m-2', 'm-2', 'm-3', 'm-4', 'log-m-5', 'm-5', 'tail',
    ])

    const fresh = after.filter((row, i) => row !== before[i])
    // Two apparatus groups + the tail. The five settled MESSAGE rows — the
    // ones carrying rendered blocks, and the expensive ones — keep identity,
    // which is the whole point of the split row memos.
    expect(fresh.map((r) => r.key)).toEqual(['log-m-2', 'log-m-5', 'tail'])
    expect(fresh).toHaveLength(3)
    expect(after).toHaveLength(8)
  } finally {
    await act(async () => tree.unmount())
  }
})

/* ── Probe C: the pill's two conditions, wired ──────────────────────────────── */

test('PROBE C — a disengaging scroll alone raises no pill; one delta below raises it', async () => {
  mockGet.mockResolvedValue({ id: 's1', messages: [msg(1, 'user'), msg(2, 'assistant')] })
  const tree = await mount()
  try {
    expect(pillCount(tree)).toBe(0) // following — never a pill

    // The user scrolls up: 4200px of content below a 800px viewport, far
    // outside the 10% band.
    await act(async () => {
      list(tree).props.onScroll({
        nativeEvent: {
          contentOffset: { y: 0 },
          contentSize: { height: 5000 },
          layoutMeasurement: { height: 800 },
        },
      })
    })
    // Disengaged, but NOTHING has arrived since — reading a quiet transcript
    // must not be nagged.
    expect(pillCount(tree)).toBe(0)

    // One token lands below.
    await frame('chat', {
      type: 'stream_event',
      event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'x' } },
    })
    expect(pillCount(tree)).toBe(1)
  } finally {
    await act(async () => tree.unmount())
  }
})
