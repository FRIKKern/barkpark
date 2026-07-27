// D25 lifecycle proofs — ChatSessionStore.start()/stop() as a TRUE pair. The
// run-proven defects these pin: the tick-interval leak (start() piled a second
// interval on a restarted store) and loading-stuck-forever (a restarted store
// never re-ran the seed GET, so the spinner never resolved). Plus the fence:
// streamChatEvents unconditionally emits a terminal status on loop exit, so a
// superseded stream's 'closed' must never clobber the live stream's status.
// The api/chat module is mocked whole — no socket, fake timers only.
import { getChatSession, streamChatEvents, type ChatStreamOptions } from '../src/api/chat'
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
