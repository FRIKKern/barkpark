// D25 lifecycle proofs — ChatSessionStore.start()/stop() as a TRUE pair. The
// run-proven defects these pin: the tick-interval leak (start() piled a second
// interval on a restarted store) and loading-stuck-forever (a restarted store
// never re-ran the seed GET, so the spinner never resolved). Plus the fence:
// streamChatEvents unconditionally emits a terminal status on loop exit, so a
// superseded stream's 'closed' must never clobber the live stream's status.
// The api/chat module is mocked whole — no socket, fake timers only.
import {
  getChatSession,
  interruptChat,
  sendChatMessage,
  streamChatEvents,
  type ChatStreamOptions,
} from '../src/api/chat'
import type { InstanceConnection } from '../src/api/instance'
import { ChatSessionStore } from '../src/chat/sessionStore'
import type { ChatSession } from '../src/chat/wire'

// (hoisted by jest above the imports)
jest.mock('../src/api/chat', () => ({
  getChatSession: jest.fn(),
  sendChatMessage: jest.fn(),
  interruptChat: jest.fn(),
  respondChatApproval: jest.fn(),
  streamChatEvents: jest.fn(),
}))

const mockGet = getChatSession as jest.Mock
const mockStream = streamChatEvents as jest.Mock

const conn: InstanceConnection = {
  projectUrl: 'https://bp.example',
  token: 'tkn',
  dataset: 'production',
}

const session = (): ChatSession => ({ id: 's1', title: 'A session', messages: [] })

/** Fake timers stop setTimeout, not microtasks — a few turns settle the
 * already-resolved mock promise chain. */
const flushMicro = async () => {
  for (let i = 0; i < 10; i++) await Promise.resolve()
}

beforeEach(() => {
  mockGet.mockReset()
  mockStream.mockReset()
})

test('stop() then start() restarts: fresh seed GET, loading resolves, exactly ONE live interval', async () => {
  jest.useFakeTimers()
  try {
    mockGet.mockResolvedValue(session())
    const streams: ChatStreamOptions[] = []
    mockStream.mockImplementation((_c: unknown, _id: unknown, opts: ChatStreamOptions) => {
      streams.push(opts)
      return new Promise(() => {}) // a live stream never resolves on its own
    })

    const store = new ChatSessionStore(conn, 's1')
    store.start()
    store.start() // RUNNING → no-op (the tick-handle guard, not a second seed)
    await flushMicro()
    expect(mockGet).toHaveBeenCalledTimes(1)
    expect(store.getSnapshot().loading).toBe(false)
    expect(jest.getTimerCount()).toBe(1) // exactly one wedge interval

    store.stop()
    expect(jest.getTimerCount()).toBe(0) // stop() cleared AND nulled the tick
    expect(streams[0]!.signal.aborted).toBe(true) // per-start controller aborted

    store.start()
    await flushMicro()
    expect(mockGet).toHaveBeenCalledTimes(2) // the seed GET re-ran
    expect(store.getSnapshot().loading).toBe(false) // resolved — not stuck forever
    expect(jest.getTimerCount()).toBe(1) // exactly ONE live interval — no leak
    expect(streams).toHaveLength(2)
    // The restart got a FRESH AbortController — the old one is aborted forever.
    expect(streams[1]!.signal.aborted).toBe(false)
    store.stop()
  } finally {
    jest.useRealTimers()
  }
})

test("a superseded stream's terminal 'closed' cannot clobber the live stream's status (frames fenced too)", async () => {
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
    store.stop()
    store.start()
    await flushMicro()
    expect(streams).toHaveLength(2)

    // The live stream opens…
    streams[1]!.onStatus?.('open')
    expect(store.getSnapshot().streamStatus).toBe('open')

    // …then the SUPERSEDED stream drains out and emits its terminal status —
    // fenced: the live status survives.
    streams[0]!.onStatus?.('closed')
    expect(store.getSnapshot().streamStatus).toBe('open')

    // Its frames are fenced too: a stale init frame must not advance the
    // live reducer state.
    const before = store.getSnapshot().state
    streams[0]!.onFrame({ event: 'chat', data: '{"type":"system","subtype":"init"}' })
    expect(store.getSnapshot().state).toBe(before)

    // The LIVE stream's refused terminal lands, failure detail and all.
    streams[1]!.onStatus?.('refused', {
      class: 'refused',
      httpStatus: 404,
      message: 'chat events: HTTP 404',
    })
    expect(store.getSnapshot().streamStatus).toBe('refused')
    expect(store.getSnapshot().streamFailure?.httpStatus).toBe(404)
    store.stop()
  } finally {
    jest.useRealTimers()
  }
})

test('a restart after a failed seed GET clears the error and loads fresh', async () => {
  jest.useFakeTimers()
  try {
    mockGet.mockRejectedValueOnce(new Error('HTTP 500'))
    mockGet.mockResolvedValue(session())
    mockStream.mockImplementation(() => new Promise(() => {}))

    const store = new ChatSessionStore(conn, 's1')
    store.start()
    await flushMicro()
    expect(store.getSnapshot().loadError).toBe('HTTP 500')
    expect(mockStream).not.toHaveBeenCalled() // no stream behind a dead seed

    store.stop()
    store.start()
    await flushMicro()
    expect(store.getSnapshot().loadError).toBeUndefined()
    expect(store.getSnapshot().loading).toBe(false)
    expect(mockStream).toHaveBeenCalledTimes(1)
    store.stop()
  } finally {
    jest.useRealTimers()
  }
})

// ── mob-bl-transport-error-sticky: the reconciled transportError ledger ──────
//
// set() is a shallow merge, so transportError survives every write that does
// not deliberately clear it. Probe-proven defect: one failed send left the
// error standing through a healthy onStatus('open'), and the screen's
// `transportError ?? state.notice` then masked every later reducer notice
// ('interrupting…' included) until the next send. The laws pinned here:
//   (1) a healthy stream status clears a stale POST failure,
//   (2) ONLY 'open' clears — degraded/refused are not recovery evidence,
//   (3) interrupt() entry-clears like send()/setChoice() already did.

const mockInterrupt = interruptChat as jest.Mock
const mockSendMsg = sendChatMessage as jest.Mock

/** The EXACT notice expression from ChatSessionScreen.tsx — the mask this row
 * exists to break lives in this `??`, so the pin evaluates the same shape. */
const screenNotice = (s: {
  transportError: string | undefined
  state: { notice: string }
}): string | undefined => s.transportError ?? (s.state.notice !== '' ? s.state.notice : undefined)

test("a healthy stream status clears a stale send failure — it stops masking the reducer's own notice", async () => {
  jest.useFakeTimers()
  try {
    mockGet.mockResolvedValue(session())
    mockSendMsg.mockRejectedValue(new Error('Network request failed'))
    mockInterrupt.mockResolvedValue(undefined)
    const streams: ChatStreamOptions[] = []
    mockStream.mockImplementation((_c: unknown, _id: unknown, opts: ChatStreamOptions) => {
      streams.push(opts)
      return new Promise(() => {})
    })

    const store = new ChatSessionStore(conn, 's1')
    store.start()
    await flushMicro()

    store.send('does not arrive')
    await flushMicro()
    expect(store.getSnapshot().transportError).toBe('send failed — Network request failed')

    // The transport re-asserts itself: the stale verdict falls.
    streams[0]!.onStatus?.('open')
    expect(store.getSnapshot().transportError).toBeUndefined()

    // …and the reducer's own notice is what the screen expression now shows
    // (before the fix the stale send error outranked it until the next send).
    // Interrupt needs a live turn (D11: idle interrupt is a silent no-op), so
    // stream one in first.
    streams[0]!.onFrame({ event: 'chat', data: '{"type":"system","subtype":"init"}' })
    streams[0]!.onFrame({
      event: 'chat',
      data: JSON.stringify({
        type: 'stream_event',
        event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'working…' } },
      }),
    })
    store.interrupt()
    expect(store.getSnapshot().state.notice).toBe('interrupting…')
    expect(screenNotice(store.getSnapshot())).toBe('interrupting…')
    store.stop()
  } finally {
    jest.useRealTimers()
  }
})

test("only 'open' clears — a degraded status is not evidence the transport recovered", async () => {
  jest.useFakeTimers()
  try {
    mockGet.mockResolvedValue(session())
    mockSendMsg.mockRejectedValue(new Error('offline'))
    const streams: ChatStreamOptions[] = []
    mockStream.mockImplementation((_c: unknown, _id: unknown, opts: ChatStreamOptions) => {
      streams.push(opts)
      return new Promise(() => {})
    })

    const store = new ChatSessionStore(conn, 's1')
    store.start()
    await flushMicro()
    store.send('x')
    await flushMicro()
    expect(store.getSnapshot().transportError).toBe('send failed — offline')

    streams[0]!.onStatus?.('degraded', { class: 'transient', message: 'reconnecting' })
    expect(store.getSnapshot().transportError).toBe('send failed — offline')
    streams[0]!.onStatus?.('closed')
    expect(store.getSnapshot().transportError).toBe('send failed — offline')
    store.stop()
  } finally {
    jest.useRealTimers()
  }
})

test('interrupt() entry-clears a stale transport failure, like send() and setChoice() already did', async () => {
  jest.useFakeTimers()
  try {
    mockGet.mockResolvedValue(session())
    mockSendMsg.mockRejectedValue(new Error('offline'))
    mockInterrupt.mockResolvedValue(undefined)
    mockStream.mockImplementation(() => new Promise(() => {}))

    const store = new ChatSessionStore(conn, 's1')
    store.start()
    await flushMicro()
    store.send('x')
    await flushMicro()
    expect(store.getSnapshot().transportError).toBe('send failed — offline')

    store.interrupt() // no healthy frame needed — the fresh attempt drops the old verdict
    expect(store.getSnapshot().transportError).toBeUndefined()
    store.stop()
  } finally {
    jest.useRealTimers()
  }
})
