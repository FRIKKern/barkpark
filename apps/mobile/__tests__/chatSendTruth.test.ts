// Two truths about state the chat client used to CLAIM without having it
// (mob-lm-s3), one at the reducer, one at the store:
//
//   (A) THE UNCONFIRMED SEND. The optimistic echo is painted before the POST is
//       answered, and the drop rule only retires an echo whose PERSISTED row
//       arrives — which, for a send the server never received, never happens.
//       Before the failed variant the bubble sat there pixel-identical to a
//       delivered message until unmount, with the rejection visible only as a
//       transportError banner the reducer was never told about.
//   (B) THE DESTRUCTIVE SEED. The store's seed GET dispatched a hardcoded
//       gen 0 while every other dispatch site carried the issuing effect's gen.
//       tailGen also seeds at 0, so in the attach-mid-turn case — deltas
//       observed before any system/init frame — the D77 clear guard MATCHED and
//       a hydration read wiped a tail that was still streaming.
//
// Both legs carry their control: the wrong value is driven through the same
// harness and shown to still break, so neither proof is vacuously green.
import { getChatSession, sendChatMessage, streamChatEvents } from '../src/api/chat'
import type { ChatStreamOptions } from '../src/api/chat'
import type { InstanceConnection } from '../src/api/instance'
import {
  HYDRATION_GEN,
  initialChatState,
  reduce,
  type ChatEvent,
  type ChatState,
} from '../src/chat/reducer'
import { ChatSessionStore } from '../src/chat/sessionStore'
import type { ChatMessage, ChatSession } from '../src/chat/wire'

// (hoisted by jest above the imports)
jest.mock('../src/api/chat', () => ({
  getChatSession: jest.fn(),
  sendChatMessage: jest.fn(),
  interruptChat: jest.fn(),
  respondChatApproval: jest.fn(),
  streamChatEvents: jest.fn(),
}))

const mockGet = getChatSession as jest.Mock
const mockSend = sendChatMessage as jest.Mock
const mockStream = streamChatEvents as jest.Mock

const t0 = Date.UTC(2026, 6, 28, 12, 0, 0)

function drive(st: ChatState, ...evs: ChatEvent[]): ChatState {
  let state = st
  for (const ev of evs) state = reduce(state, ev, t0).state
  return state
}

const chatFrame = (obj: unknown): ChatEvent => ({
  type: 'frame',
  name: 'chat',
  data: JSON.stringify(obj),
})

const initFrame = (): ChatEvent => chatFrame({ type: 'system', subtype: 'init' })

const deltaFrame = (text: string): ChatEvent =>
  chatFrame({
    type: 'stream_event',
    event: { type: 'content_block_delta', delta: { type: 'text_delta', text } },
  })

const session = (messages: ChatMessage[] = []): ChatSession => ({
  id: 's1',
  title: 'A session',
  messages,
})

const conn: InstanceConnection = {
  projectUrl: 'https://bp.example',
  token: 'tkn',
  dataset: 'production',
}

/** Fake timers stop setTimeout, not microtasks — a few turns settle the
 * already-resolved mock promise chain. */
const flushMicro = async (): Promise<void> => {
  for (let i = 0; i < 10; i++) await Promise.resolve()
}

beforeEach(() => {
  mockGet.mockReset()
  mockSend.mockReset()
  mockStream.mockReset()
})

// ── (A) the unconfirmed send, at the reducer ─────────────────────────────────

test('a rejected send marks its echo failed — it stops claiming delivery', () => {
  const sent = drive(initialChatState('s1'), { type: 'send', content: 'ship it' })
  expect(sent.local).toEqual([{ content: 'ship it', queued: false, failed: false }])
  expect(sent.phase).toBe('waiting')

  const failed = drive(sent, {
    type: 'sendFailed',
    content: 'ship it',
    error: 'network request failed',
  })
  expect(failed.local).toEqual([{ content: 'ship it', queued: false, failed: true }])
  // The user's words are KEPT — losing them is worse than labelling them.
  expect(failed.notice).toBe('send failed — network request failed')
  // …and nothing is left spinning on a turn that was never started.
  expect(failed.phase).toBe('idle')
})

test('a failed send does not idle a turn that is genuinely streaming', () => {
  let state = drive(initialChatState('s1'), initFrame(), deltaFrame('working…'))
  expect(state.phase).toBe('streaming')
  state = drive(state, { type: 'send', content: 'also this' })
  expect(state.local[0]?.queued).toBe(true) // D12 queued steer
  state = drive(state, { type: 'sendFailed', content: 'also this', error: '503' })
  expect(state.phase).toBe('streaming') // the live turn is untouched
  // Two contradictory badges on one bubble is worse than one: queued clears.
  expect(state.local).toEqual([{ content: 'also this', queued: false, failed: true }])
})

test('a failed echo is never retired by a later persisted row for the same text', () => {
  // First attempt rejected; the user retries the same words and the retry lands.
  let state = drive(
    initialChatState('s1'),
    { type: 'send', content: 'retry me' },
    { type: 'sendFailed', content: 'retry me', error: 'offline' },
    { type: 'send', content: 'retry me' },
  )
  expect(state.local.map((l) => l.failed)).toEqual([true, false])

  const row = { seq: 7, role: 'user', source_markdown: 'retry me' } as ChatMessage
  state = drive(state, { type: 'tailFetched', gen: state.tailGen, session: session([row]) })
  // The SECOND echo (the one that reached the server) settled; the failed
  // bubble is still standing and still honest.
  expect(state.local).toEqual([{ content: 'retry me', queued: false, failed: true }])
})

test('sendFailed with no unfailed echo to match is inert — no invented failures', () => {
  const once = drive(
    initialChatState('s1'),
    { type: 'send', content: 'a' },
    { type: 'sendFailed', content: 'a', error: 'x' },
  )
  // A duplicate rejection (or one whose echo already settled) changes nothing —
  // it must never flip a NEIGHBOURING echo.
  expect(drive(once, { type: 'sendFailed', content: 'a', error: 'x' }).local).toBe(once.local)
  expect(drive(once, { type: 'sendFailed', content: 'never sent', error: 'x' })).toBe(once)
})

// ── (A) the unconfirmed send, at the store ───────────────────────────────────

test('a rejected send POST reaches the REDUCER, not only the transportError banner', async () => {
  jest.useFakeTimers()
  try {
    mockGet.mockResolvedValue(session())
    mockStream.mockImplementation(() => new Promise(() => {}))
    mockSend.mockRejectedValue(new Error('Network request failed'))

    const store = new ChatSessionStore(conn, 's1')
    store.start()
    await flushMicro()

    store.send('does not arrive')
    // The optimistic echo is painted immediately — that part is unchanged.
    expect(store.getSnapshot().state.local).toEqual([
      { content: 'does not arrive', queued: false, failed: false },
    ])

    await flushMicro()
    expect(mockSend).toHaveBeenCalledTimes(1)
    // The banner AND the bubble — the bubble is the part that used to be missing.
    expect(store.getSnapshot().transportError).toBe('send failed — Network request failed')
    expect(store.getSnapshot().state.local).toEqual([
      { content: 'does not arrive', queued: false, failed: true },
    ])
    expect(store.getSnapshot().state.notice).toBe('send failed — Network request failed')
    store.stop()
  } finally {
    jest.useRealTimers()
  }
})

test('control: a send whose POST resolves leaves its echo unfailed', async () => {
  jest.useFakeTimers()
  try {
    mockGet.mockResolvedValue(session())
    mockStream.mockImplementation(() => new Promise(() => {}))
    mockSend.mockResolvedValue(undefined)

    const store = new ChatSessionStore(conn, 's1')
    store.start()
    await flushMicro()
    store.send('this one lands')
    await flushMicro()

    expect(store.getSnapshot().transportError).toBeUndefined()
    expect(store.getSnapshot().state.local).toEqual([
      { content: 'this one lands', queued: false, failed: false },
    ])
    store.stop()
  } finally {
    jest.useRealTimers()
  }
})

// ── (B) the hydration sentinel ───────────────────────────────────────────────

test('the seed GET is a HYDRATION read: a re-attach mid-turn does not wipe the live tail', async () => {
  jest.useFakeTimers()
  try {
    mockGet.mockResolvedValue(session())
    const streams: ChatStreamOptions[] = []
    mockStream.mockImplementation((_c: unknown, _id: unknown, opts: ChatStreamOptions) => {
      streams.push(opts)
      return new Promise(() => {})
    })

    const store = new ChatSessionStore(conn, 's1')
    store.start()
    await flushMicro()

    // ATTACH MID-TURN: the turn was already running when this client attached,
    // so text deltas arrive with NO system/init frame of their own — gen and
    // tailGen both stay 0, exactly the value the seed used to dispatch.
    streams[0]!.onFrame({ event: 'chat', data: JSON.stringify(deltaJson('half an ')) })
    streams[0]!.onFrame({ event: 'chat', data: JSON.stringify(deltaJson('answer')) })
    expect(store.getSnapshot().state.tail).toBe('half an answer')
    expect(store.getSnapshot().state.gen).toBe(0)
    expect(store.getSnapshot().state.tailGen).toBe(0)

    // The screen remounts (background→foreground, a nav pop): stop() then
    // start() re-runs the seed GET while the turn is still streaming.
    store.stop()
    store.start()
    await flushMicro()
    expect(mockGet).toHaveBeenCalledTimes(2)

    // THE CLAIM: the live tail SURVIVES the hydration read.
    expect(store.getSnapshot().state.tail).toBe('half an answer')
    store.stop()
  } finally {
    jest.useRealTimers()
  }
})

test('control: the same re-attach with the pre-fix gen 0 DOES wipe the live tail', () => {
  // The store no longer has a way to emit gen 0 for a seed, so the control is
  // driven at the reducer — the guard the sentinel has to clear.
  const live = drive(initialChatState('s1'), deltaFrame('half an answer'))
  expect(live.tailGen).toBe(0)
  expect(drive(live, { type: 'tailFetched', gen: 0, session: session() }).tail).toBe('')
  // …and the sentinel is what makes it survive.
  expect(drive(live, { type: 'tailFetched', gen: HYDRATION_GEN, session: session() }).tail).toBe(
    'half an answer',
  )
})

test('a hydration read never clears a live tail mid-stream either', () => {
  const live = drive(initialChatState('s1'), initFrame(), deltaFrame('streaming'))
  expect(live.gen).toBe(1)
  expect(drive(live, { type: 'tailFetched', gen: HYDRATION_GEN, session: session() }).tail).toBe(
    'streaming',
  )
  // Carrying the CURRENT gen — the OTHER wrong answer the sentinel's comment
  // names — wipes it, which is why the sentinel is neither 0 nor st.gen.
  expect(drive(live, { type: 'tailFetched', gen: live.gen, session: session() }).tail).toBe('')
})

test('the sentinel can never collide with a real generation', () => {
  expect(HYDRATION_GEN).toBeLessThan(0)
  expect(initialChatState('s1').tailGen).toBeGreaterThanOrEqual(0)
})

function deltaJson(text: string): unknown {
  return {
    type: 'stream_event',
    event: { type: 'content_block_delta', delta: { type: 'text_delta', text } },
  }
}
