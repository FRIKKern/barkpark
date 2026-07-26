// Transport truth (charter D24/D26, t3w2-s6): the typed transient|refused
// classification, the jittered 1s→16s ladder, and streamChatEvents' terminal
// behavior — refused walls terminate into the refused state; everything else
// (5xx, network errors, clean closes) degrades and retries forever. Driven
// with a mocked expo/fetch and fake timers — no socket, no clock.
import { fetch as expoFetch } from 'expo/fetch'

import {
  backoffDelayMs,
  ChatHttpError,
  classifyStreamFailure,
  streamChatEvents,
  type StreamFailure,
  type StreamStatus,
} from '../src/api/chat'
import type { InstanceConnection } from '../src/api/instance'

// (hoisted by jest above the imports)
jest.mock('expo/fetch', () => ({ fetch: jest.fn() }))

const mockFetch = expoFetch as unknown as jest.Mock

const conn: InstanceConnection = {
  projectUrl: 'https://bp.example',
  token: 'tkn',
  dataset: 'production',
}

/** A response stub shaped like the slice of expo/fetch's Response the
 * transport reads: ok/status/body.getReader(). */
function closedBody() {
  return {
    getReader: () => ({
      read: () => Promise.resolve({ done: true as const, value: undefined }),
      releaseLock: () => {},
    }),
  }
}

function recorder() {
  const statuses: StreamStatus[] = []
  const failures: (StreamFailure | undefined)[] = []
  const onStatus = (status: StreamStatus, failure?: StreamFailure) => {
    statuses.push(status)
    failures.push(failure)
  }
  return { statuses, failures, onStatus }
}

beforeEach(() => {
  mockFetch.mockReset()
})

// ── classification ───────────────────────────────────────────────────────────

test('classifyStreamFailure: 5xx and network-level errors are transient; every 4xx is refused', () => {
  // 5xx — the server may come back (runtime_capacity / runtime_unavailable / overloaded).
  for (const status of [500, 502, 503]) {
    expect(classifyStreamFailure(new ChatHttpError(status, `chat events: HTTP ${status}`))).toEqual(
      {
        class: 'transient',
        httpStatus: status,
        message: `chat events: HTTP ${status}`,
      },
    )
  }
  // 4xx — permanent for this session/token (incl 422 chat_unsupported).
  for (const status of [401, 403, 404, 422]) {
    expect(classifyStreamFailure(new ChatHttpError(status, `chat events: HTTP ${status}`))).toEqual(
      {
        class: 'refused',
        httpStatus: status,
        message: `chat events: HTTP ${status}`,
      },
    )
  }
  // Network-level failures carry no HTTP status and are transient.
  expect(classifyStreamFailure(new TypeError('Network request failed'))).toEqual({
    class: 'transient',
    message: 'Network request failed',
  })
  expect(classifyStreamFailure('socket hang up')).toEqual({
    class: 'transient',
    message: 'socket hang up',
  })
})

// ── backoff ladder ───────────────────────────────────────────────────────────

test('connect attempts over a simulated window are BOUNDED, not linear (polish AC1)', () => {
  const rand = jest.spyOn(Math, 'random')
  try {
    rand.mockReturnValue(1) // jitter upper bound: withJitter(ms) === ms
    expect(backoffDelayMs(0)).toBe(1_000)
    expect(backoffDelayMs(1)).toBe(2_000)
    expect(backoffDelayMs(4)).toBe(16_000)
    expect(backoffDelayMs(9)).toBe(16_000) // capped, never past 16s

    // A simulated 2-minute outage: the exponential ladder connects 11 times
    // (1+2+4+8s, then 16s spacing at the cap) where the old flat 1s loop
    // connected 120 — bounded, not linear.
    let t = 0
    let attempts = 0
    while (t < 120_000) {
      t += backoffDelayMs(attempts)
      attempts += 1
    }
    expect(attempts).toBeLessThanOrEqual(11)

    // The jitter floor is 0.5× — the delay never collapses into a busy-spin.
    rand.mockReturnValue(0)
    expect(backoffDelayMs(0)).toBe(500)
  } finally {
    rand.mockRestore()
  }
})

// ── refused: terminal ────────────────────────────────────────────────────────

test.each([401, 403, 404, 422])(
  'HTTP %d terminates into refused — one attempt, no retry, never closed',
  async (status) => {
    mockFetch.mockResolvedValue({ ok: false, status, body: null })
    const { statuses, failures, onStatus } = recorder()
    await streamChatEvents(conn, 's1', {
      signal: new AbortController().signal,
      onFrame: () => {},
      onStatus,
    })
    expect(mockFetch).toHaveBeenCalledTimes(1)
    expect(statuses[statuses.length - 1]).toBe('refused')
    expect(failures[failures.length - 1]).toEqual({
      class: 'refused',
      httpStatus: status,
      message: `chat events: HTTP ${status}`,
    })
    // refused is TERMINAL, distinct from closed — the screen renders the wall.
    expect(statuses).not.toContain('closed')
  },
)

// ── transient: degraded retry-forever ────────────────────────────────────────

test('a 503 degrades and retries forever on the jittered capped ladder — never refused, never gives up', async () => {
  jest.useFakeTimers()
  const rand = jest.spyOn(Math, 'random').mockReturnValue(1)
  try {
    mockFetch.mockResolvedValue({ ok: false, status: 503, body: null })
    const abort = new AbortController()
    const { statuses, onStatus } = recorder()
    const done = streamChatEvents(conn, 's1', {
      signal: abort.signal,
      onFrame: () => {},
      onStatus,
    })

    await jest.advanceTimersByTimeAsync(0)
    expect(mockFetch).toHaveBeenCalledTimes(1)
    // Ladder: connects at t=1s, 3s, 7s, 15s, 31s — 6 total in a 31s window
    // (the old code would have given up after 5; a flat 1s loop would be 32).
    await jest.advanceTimersByTimeAsync(31_000)
    expect(mockFetch).toHaveBeenCalledTimes(6)
    expect(statuses).toContain('degraded')
    expect(statuses).not.toContain('refused')

    abort.abort()
    await jest.advanceTimersByTimeAsync(0)
    await done
    expect(statuses[statuses.length - 1]).toBe('closed')
  } finally {
    rand.mockRestore()
    jest.useRealTimers()
  }
})

// ── clean closes: counted ────────────────────────────────────────────────────

test('clean closes are COUNTED onto the same ladder — an instantly-closing endpoint backs off to the cap', async () => {
  jest.useFakeTimers()
  const rand = jest.spyOn(Math, 'random').mockReturnValue(1)
  try {
    mockFetch.mockImplementation(() =>
      Promise.resolve({ ok: true, status: 200, body: closedBody() }),
    )
    const abort = new AbortController()
    const { statuses, onStatus } = recorder()
    const done = streamChatEvents(conn, 's1', {
      signal: abort.signal,
      onFrame: () => {},
      onStatus,
    })

    await jest.advanceTimersByTimeAsync(0)
    expect(mockFetch).toHaveBeenCalledTimes(1)
    // Same exponential schedule as failures: 6 connects in 31s, not 32 —
    // the old flat UNCOUNTED 1s loop is dead (polish AC1).
    await jest.advanceTimersByTimeAsync(31_000)
    expect(mockFetch).toHaveBeenCalledTimes(6)
    expect(statuses).toContain('open')
    expect(statuses).toContain('degraded')

    abort.abort()
    await jest.advanceTimersByTimeAsync(0)
    await done
    expect(statuses[statuses.length - 1]).toBe('closed')
  } finally {
    rand.mockRestore()
    jest.useRealTimers()
  }
})

// ── liveness resets + resume cursor ──────────────────────────────────────────

test('bytes reset the ladder and frame ids become the Last-Event-ID resume cursor', async () => {
  jest.useFakeTimers()
  const rand = jest.spyOn(Math, 'random').mockReturnValue(1)
  try {
    const enc = new TextEncoder()
    const cursors: (string | undefined)[] = []
    mockFetch.mockImplementation((_url: string, init: { headers: Record<string, string> }) => {
      cursors.push(init.headers['Last-Event-ID'])
      let sent = false
      const body = {
        getReader: () => ({
          read: () => {
            if (!sent) {
              sent = true
              return Promise.resolve({
                done: false as const,
                value: enc.encode('event: message\nid: 7\ndata: {"seq":7}\n\n'),
              })
            }
            return Promise.resolve({ done: true as const, value: undefined })
          },
          releaseLock: () => {},
        }),
      }
      return Promise.resolve({ ok: true, status: 200, body })
    })

    const abort = new AbortController()
    const frames: string[] = []
    const done = streamChatEvents(conn, 's1', {
      signal: abort.signal,
      onFrame: (frame) => frames.push(frame.data),
      onStatus: () => {},
    })

    await jest.advanceTimersByTimeAsync(0)
    expect(frames).toEqual(['{"seq":7}'])
    // The frame's bytes reset the ladder, so the clean close after it sleeps
    // the base 1s (attempt 0), and the reconnect resumes AT the cursor.
    await jest.advanceTimersByTimeAsync(1_000)
    expect(mockFetch).toHaveBeenCalledTimes(2)
    expect(cursors[0]).toBeUndefined()
    expect(cursors[1]).toBe('7')

    abort.abort()
    await jest.advanceTimersByTimeAsync(0)
    await done
  } finally {
    rand.mockRestore()
    jest.useRealTimers()
  }
})
