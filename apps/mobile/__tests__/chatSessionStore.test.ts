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
  patchChatSession,
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
  // Added for the setChoice rollback proofs below. A jest.fn() with no
  // implementation returns undefined, and `.catch` on undefined throws — so
  // every test touching setChoice sets its own resolved/rejected promise.
  patchChatSession: jest.fn(),
}))

const mockGet = getChatSession as jest.Mock
const mockStream = streamChatEvents as jest.Mock
const mockPatch = patchChatSession as jest.Mock

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
  mockPatch.mockReset()
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

/* ── setChoice: the rollback is fenced on the field it wrote ────────────────
 * The handler used to capture `before` at call time and write `before[key]`
 * into the CURRENT snapshot, guarded only by `this.stopped`. A slow failure
 * could therefore overwrite a NEWER choice the server had already accepted.
 * Every other async closure in this class fences on `gen !== this.startGen`. */

/** A store with a live stream and a settled seed, ready to take a choice. */
async function startedStore(): Promise<ChatSessionStore> {
  mockGet.mockResolvedValue(session())
  mockStream.mockImplementation(() => new Promise(() => {}))
  const store = new ChatSessionStore(conn, 's1')
  store.start()
  await flushMicro()
  return store
}

test('a LATE-failing choice write does not clobber a newer choice the server accepted', async () => {
  const store = await startedStore()
  try {
    // Call A fails, but only after call B has already succeeded.
    let failA: (e: Error) => void = () => {}
    mockPatch.mockImplementationOnce(
      () => new Promise((_res, rej) => { failA = rej }),
    )
    mockPatch.mockImplementationOnce(() => Promise.resolve(undefined))

    store.setChoice('mode', 'plan')
    expect(store.getSnapshot().choices.mode).toBe('plan')

    store.setChoice('mode', 'default') // B — succeeds; the server now holds this
    await flushMicro()
    expect(store.getSnapshot().choices.mode).toBe('default')

    failA(new Error('timeout')) // A's PATCH finally rejects
    await flushMicro()

    // Before the fence this wrote 'acceptEdits' — a value neither the user nor
    // the server ever chose.
    expect(store.getSnapshot().choices.mode).toBe('default')
    // …and it did not raise an error about a write the user already replaced.
    expect(store.getSnapshot().transportError).toBeUndefined()
  } finally {
    store.stop()
  }
})

test('an ORDINARY failing choice write still rolls back and still says so', async () => {
  // The other half of the law: a fence that suppressed every rollback would
  // pass the test above and silently break the feature.
  const store = await startedStore()
  try {
    const seeded = store.getSnapshot().choices.mode
    mockPatch.mockImplementationOnce(() => Promise.reject(new Error('offline')))

    store.setChoice('mode', 'plan')
    expect(store.getSnapshot().choices.mode).toBe('plan') // optimistic
    await flushMicro()

    expect(store.getSnapshot().choices.mode).toBe(seeded) // rolled back
    expect(store.getSnapshot().transportError).toContain('could not set mode')
  } finally {
    store.stop()
  }
})

test('the fence is PER FIELD — a failing mode write still rolls back beside a live model write', async () => {
  // A generation counter would have made these two conflict; they are
  // independent fields and must not.
  const store = await startedStore()
  try {
    const seededMode = store.getSnapshot().choices.mode
    let failMode: (e: Error) => void = () => {}
    mockPatch.mockImplementationOnce(
      () => new Promise((_res, rej) => { failMode = rej }),
    )
    mockPatch.mockImplementationOnce(() => Promise.resolve(undefined))

    store.setChoice('mode', 'plan')
    store.setChoice('modelChoice', 'opus') // a DIFFERENT field moves on
    await flushMicro()

    failMode(new Error('timeout'))
    await flushMicro()

    expect(store.getSnapshot().choices.mode).toBe(seededMode) // still rolled back
    expect(store.getSnapshot().choices.modelChoice).toBe('opus') // untouched
    expect(store.getSnapshot().transportError).toContain('could not set mode')
  } finally {
    store.stop()
  }
})

test('a failure after stop() touches nothing', async () => {
  const store = await startedStore()
  let fail: (e: Error) => void = () => {}
  mockPatch.mockImplementationOnce(() => new Promise((_res, rej) => { fail = rej }))
  store.setChoice('mode', 'plan')
  store.stop()
  fail(new Error('timeout'))
  await flushMicro()
  expect(store.getSnapshot().transportError).toBeUndefined()
})

// ── the per-start fence, on the EFFECT closures (not just start()'s own) ─────
//
// setChoice's rollback was fenced after a superseded failure was found writing
// a stale value into a newer snapshot. Its comment then claimed "every other
// async closure in this class fences on `gen !== this.startGen`". That was not
// true of the FIVE closures inside run(): each checked only `this.stopped`, and
// `stopped` is cleared again by the very next start() — so a callback from a
// superseded start lands on the LIVE store rather than being dropped.
//
// The restart is not exotic: stop()/start() is a documented TRUE PAIR (D25),
// React StrictMode double-invokes the mount effect on the same store, and the
// tests above already exercise it.

test('a superseded turn-boundary refetch must not overwrite a choice made AFTER the restart', async () => {
  jest.useFakeTimers()
  try {
    // start #1 seeds mode=default.
    mockGet.mockResolvedValueOnce({ ...session(), mode: 'default' })
    const streams: ChatStreamOptions[] = []
    mockStream.mockImplementation((_c: unknown, _id: unknown, opts: ChatStreamOptions) => {
      streams.push(opts)
      return new Promise(() => {})
    })

    const store = new ChatSessionStore(conn, 's1')
    store.start()
    await flushMicro()
    expect(store.getSnapshot().choices.mode).toBe('default')

    // The turn-boundary refetch, held OPEN so it can land after the restart.
    let releaseTail: ((s: ChatSession) => void) | undefined
    mockGet.mockImplementationOnce(
      () =>
        new Promise<ChatSession>((resolve) => {
          releaseTail = resolve
        }),
    )
    streams[0]!.onFrame({ event: 'chat', data: '{"type":"system","subtype":"init"}' })
    streams[0]!.onFrame({ event: 'chat', data: '{"type":"result","subtype":"success"}' })
    await flushMicro()
    // The effect really fired — without this the whole test is vacuous, because
    // a refetch that never happened can hardly clobber anything.
    expect(releaseTail).toBeDefined()

    // The restart (remount / StrictMode double-effect / the D25 true pair).
    store.stop()
    mockGet.mockResolvedValueOnce({ ...session(), mode: 'default' })
    store.start()
    await flushMicro()

    // The user picks a mode after the restart, and the server ACCEPTS it.
    mockPatch.mockResolvedValue(undefined)
    store.setChoice('mode', 'plan')
    await flushMicro()
    expect(store.getSnapshot().choices.mode).toBe('plan')

    // Now the superseded refetch lands, carrying the PRE-restart truth.
    releaseTail!({ ...session(), mode: 'default' })
    await flushMicro()

    // It belongs to a start that is over. It owns nothing here.
    expect(store.getSnapshot().choices.mode).toBe('plan')
    store.stop()
  } finally {
    jest.useRealTimers()
  }
})

test('a superseded send failure must not raise a banner on the restarted store', async () => {
  jest.useFakeTimers()
  try {
    mockGet.mockResolvedValue(session())
    mockStream.mockImplementation(() => new Promise(() => {}))

    // Hold the POST open so its rejection can land after the restart.
    let failSend: ((e: Error) => void) | undefined
    mockSendMsg.mockImplementationOnce(
      () =>
        new Promise<void>((_resolve, reject) => {
          failSend = reject
        }),
    )

    const store = new ChatSessionStore(conn, 's1')
    store.start()
    await flushMicro()
    store.send('into the void')
    await flushMicro()
    expect(failSend).toBeDefined()

    store.stop()
    store.start()
    await flushMicro()

    failSend!(new Error('Network request failed'))
    await flushMicro()

    // The banner would name an action taken before the restart — this view's
    // chrome, and not this start's to raise.
    expect(store.getSnapshot().transportError).toBeUndefined()

    // THE OTHER HALF, and the reason the fence is not a blanket one. The
    // optimistic echo is REDUCER state, and reducer state survives a restart —
    // that bubble is still on screen, still painted as though it were
    // delivered, and no persisted row will ever arrive to retire it (the POST
    // was refused). So the sendFailed dispatch must STILL land. A fence that
    // dropped it would trade a stale banner for a permanent lie in the
    // transcript, which is the worse of the two.
    const echo = store.getSnapshot().state.local.find((l) => l.content === 'into the void')
    expect(echo).toBeDefined()
    expect(echo!.failed).toBe(true)
    store.stop()
  } finally {
    jest.useRealTimers()
  }
})
