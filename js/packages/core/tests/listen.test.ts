import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest'
import { http, HttpResponse, delay } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createListenHandle } from '../src/listen'
import {
  BarkparkAPIError,
  BarkparkAuthError,
  BarkparkEdgeRuntimeError,
  BarkparkValidationError,
} from '../src/errors'
import type { BarkparkClient, BarkparkClientConfig, ListenEvent } from '../src/types'
// Imported from the PUBLIC entry (../src/index), not ../src/listen — proves
// ListenOptions is exported from the package (it is createListenHandle's `opts`
// type). Un-export it from index.ts and this import fails → tsc errors. Protective.
import type { ListenOptions } from '../src/index'

const config: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
  token: 'test-token',
}

// Type-level guard (declared, never executed): client.listen()'s filter pins `op`
// to 'eq' (Phase 1A is eq-only). Revert ListenFilter → QueryOptions['filters'] and
// the @ts-expect-error below stops applying → tsc fails. Protective at the TYPE level.
function _listenFilterIsEqOnly(bp: BarkparkClient): void {
  bp.listen('post', [{ field: 'status', op: 'eq', value: 'published' }])
  // @ts-expect-error — a non-eq op is rejected at the type level (eq-only)
  bp.listen('post', [{ field: 'rank', op: 'gt', value: 5 }])
}
void _listenFilterIsEqOnly

// The exported ListenOptions types createListenHandle's reconnect/perspective opts.
const _listenOptions: ListenOptions = { maxReconnects: 3, reconnectBaseMs: 100 }
void _listenOptions

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('createListenHandle', () => {
  it('yields welcome + mutation SSE events (keepalive skipped)', async () => {
    const events: ListenEvent[] = []
    const handle = createListenHandle(config, 'post')
    for await (const evt of handle) {
      events.push(evt)
      if (events.length >= 2) break
    }
    expect(events.length).toBeGreaterThanOrEqual(2)
    const welcome = events.find((e) => e.type === 'welcome')
    const mutation = events.find((e) => e.type === 'mutation')
    expect(welcome).toBeDefined()
    expect(mutation).toBeDefined()
    expect(mutation!.eventId).toBe('1')
    expect(mutation!.mutation).toBe('create')
    expect(mutation!.documentId).toBe('drafts.live-x1')
    expect(mutation!.previousRev).toBeNull()
    expect(mutation!.result).toBeTruthy()
  })

  it('yields discardDraft as a recognized mutation kind', async () => {
    // Stream one discardDraft frame, then hold the connection open so the
    // generator doesn't hit the clean-close reconnect path — we break out
    // ourselves once the event lands.
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/listen/:dataset`, () => {
        const stream = new ReadableStream<Uint8Array>({
          async start(controller) {
            const enc = new TextEncoder()
            controller.enqueue(
              enc.encode(
                `id: 9\nevent: mutation\ndata: ${JSON.stringify({ eventId: 9, mutation: 'discardDraft', documentId: 'drafts.d1', previousRev: 'a'.repeat(32) })}\n\n`,
              ),
            )
            await delay(5_000)
            controller.close()
          },
        })
        return new HttpResponse(stream, {
          status: 200,
          headers: { 'content-type': 'text/event-stream' },
        })
      }),
    )

    const handle = createListenHandle(config, 'post', undefined, { maxReconnects: 0 })
    let mutation: ListenEvent | undefined
    for await (const evt of handle) {
      if (evt.type === 'mutation') {
        mutation = evt
        break
      }
    }
    expect(mutation).toBeDefined()
    expect(mutation!.mutation).toBe('discardDraft')
    expect(mutation!.documentId).toBe('drafts.d1')
  })

  it('throws BarkparkEdgeRuntimeError synchronously on edge runtime', () => {
    ;(globalThis as unknown as { EdgeRuntime?: string }).EdgeRuntime = 'vercel-edge'
    try {
      expect(() => createListenHandle(config, 'post')).toThrowError(BarkparkEdgeRuntimeError)
    } finally {
      delete (globalThis as unknown as { EdgeRuntime?: string }).EdgeRuntime
    }
  })

  it('unsubscribe() aborts the in-flight fetch and exits the loop cleanly', async () => {
    // Slow handler: streams a welcome frame, then hangs until aborted.
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/listen/:dataset`, () => {
        const stream = new ReadableStream<Uint8Array>({
          async start(controller) {
            const enc = new TextEncoder()
            controller.enqueue(enc.encode(`event: welcome\ndata: {"type":"welcome"}\n\n`))
            // Hold open; generator is expected to abort us.
            await delay(5_000)
            controller.close()
          },
        })
        return new HttpResponse(stream, {
          status: 200,
          headers: { 'content-type': 'text/event-stream' },
        })
      }),
    )

    const handle = createListenHandle(config, 'post', undefined, {
      maxReconnects: 0,
    })
    const iterator = handle[Symbol.asyncIterator]()
    const first = await iterator.next()
    expect(first.done).toBe(false)
    expect((first.value as ListenEvent).type).toBe('welcome')

    handle.unsubscribe()
    const next = await iterator.next()
    expect(next.done).toBe(true)
  })

  it('reconnects with Last-Event-ID header after mid-stream close', async () => {
    const seenHeaders: Array<string | null> = []
    let call = 0

    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/listen/:dataset`, ({ request }) => {
        seenHeaders.push(request.headers.get('last-event-id'))
        call++
        const isFirst = call === 1
        const stream = new ReadableStream<Uint8Array>({
          async start(controller) {
            const enc = new TextEncoder()
            if (isFirst) {
              controller.enqueue(
                enc.encode(
                  `id: 7\nevent: mutation\ndata: ${JSON.stringify({ eventId: 7, mutation: 'update', documentId: 'p1', rev: 'a'.repeat(32), previousRev: null })}\n\n`,
                ),
              )
              await delay(5)
              controller.close() // clean close → reconnect
            } else {
              controller.enqueue(
                enc.encode(
                  `id: 8\nevent: mutation\ndata: ${JSON.stringify({ eventId: 8, mutation: 'update', documentId: 'p1', rev: 'b'.repeat(32), previousRev: 'a'.repeat(32) })}\n\n`,
                ),
              )
              await delay(5)
              controller.close()
            }
          },
        })
        return new HttpResponse(stream, {
          status: 200,
          headers: { 'content-type': 'text/event-stream' },
        })
      }),
    )

    const collected: ListenEvent[] = []
    const handle = createListenHandle(config, 'post', undefined, { reconnectBaseMs: 10 })
    for await (const evt of handle) {
      collected.push(evt)
      if (collected.length >= 2) break
    }
    expect(collected.map((e) => e.eventId)).toEqual(['7', '8'])
    expect(seenHeaders[0]).toBeNull()
    expect(seenHeaders[1]).toBe('7')
  })

  it('floors the reconnect after a clean immediate 200→EOF close (no zero-delay storm)', async () => {
    // A misconfigured proxy / instantly-terminating LB answers 200 + SSE but
    // closes the body immediately with no frames. Clean closes don't count
    // against maxReconnects and reconnectCount resets on every open, so without
    // the 1s floor this would busy-spin — reopening hundreds of times in 250ms.
    let calls = 0
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/listen/:dataset`, () => {
        calls++
        const stream = new ReadableStream<Uint8Array>({
          start(controller) {
            controller.close() // empty body, immediate EOF
          },
        })
        return new HttpResponse(stream, {
          status: 200,
          headers: { 'content-type': 'text/event-stream' },
        })
      }),
    )

    // reconnectBaseMs: 10 proves the *floor* (1000) — not the base — governs the
    // clean-close delay: even at a 10ms base we must not reopen within 250ms.
    const handle = createListenHandle(config, 'post', undefined, { reconnectBaseMs: 10 })
    const iterator = handle[Symbol.asyncIterator]()
    // Drive the generator in the background: it never yields, it only reconnects.
    // The promise stays pending while it loops; we sample `calls` after a window.
    const drain = iterator.next()
    void drain

    await delay(250)
    // 1 initial open + at most 1 in-flight reconnect after the 1s floor.
    expect(calls).toBeGreaterThanOrEqual(1)
    expect(calls).toBeLessThanOrEqual(2)

    // Unsubscribing mid-sleep must exit cleanly (the aborted re-check).
    handle.unsubscribe()
    const done = await drain
    expect(done.done).toBe(true)
  })

  it('idle watchdog abandons a half-open (silent) socket and reconnects', async () => {
    // A half-open TCP socket delivers no bytes, no keepalive, no FIN — reader.read()
    // would hang forever. The watchdog must cancel the read after idleTimeoutMs and
    // fall into the reconnect path. Connection 1 yields welcome then goes silent;
    // connection 2 (post-reconnect) delivers the mutation we wait for.
    let call = 0
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/listen/:dataset`, () => {
        call++
        const first = call === 1
        const stream = new ReadableStream<Uint8Array>({
          async start(controller) {
            const enc = new TextEncoder()
            if (first) {
              controller.enqueue(enc.encode(`event: welcome\ndata: {"type":"welcome"}\n\n`))
              await delay(1_000) // silence >> idleTimeoutMs; the watchdog fires first
              controller.close()
            } else {
              controller.enqueue(
                enc.encode(
                  `id: 9\nevent: mutation\ndata: ${JSON.stringify({ eventId: 9, mutation: 'create', documentId: 'p9', rev: 'c'.repeat(32), previousRev: null })}\n\n`,
                ),
              )
              await delay(5)
              controller.close()
            }
          },
        })
        return new HttpResponse(stream, {
          status: 200,
          headers: { 'content-type': 'text/event-stream' },
        })
      }),
    )

    const collected: ListenEvent[] = []
    const handle = createListenHandle(config, 'post', undefined, {
      idleTimeoutMs: 40,
      reconnectBaseMs: 10,
    })
    for await (const evt of handle) {
      collected.push(evt)
      if (collected.length >= 2) break
    }
    expect(collected[0]!.type).toBe('welcome')
    expect(collected[1]!.eventId).toBe('9')
    expect(call).toBeGreaterThanOrEqual(2) // proves the silent socket triggered a reconnect
  }, 10_000)

  it('throws BarkparkAPIError when a frameless stream exceeds the buffer cap', async () => {
    // A broken/malicious stream that emits bytes with no frame boundary (\n\n) would
    // grow the decode buffer without bound → OOM. Past the 1 MiB cap it must surface.
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/listen/:dataset`, () => {
        const stream = new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(new TextEncoder().encode('x'.repeat(1_100_000))) // > 1 MiB, no \n\n
            // deliberately left open — the client must throw before any boundary arrives
          },
        })
        return new HttpResponse(stream, {
          status: 200,
          headers: { 'content-type': 'text/event-stream' },
        })
      }),
    )

    const handle = createListenHandle(config, 'post', undefined, { maxReconnects: 0 })
    const iterator = handle[Symbol.asyncIterator]()
    await expect(iterator.next()).rejects.toThrow(BarkparkAPIError)
    handle.unsubscribe()
  })

  it('escalates to a thrown error after repeated silent clean closes', async () => {
    // A misconfigured proxy answers 200 + SSE then instantly EOFs with no data —
    // clean closes are uncounted, so this would loop ~forever. After
    // MAX_CONSECUTIVE_CLEAN_CLOSES (5) the client must surface an error.
    let calls = 0
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/listen/:dataset`, () => {
        calls++
        const stream = new ReadableStream<Uint8Array>({
          start(controller) {
            controller.close() // empty body, immediate EOF, no data frame
          },
        })
        return new HttpResponse(stream, {
          status: 200,
          headers: { 'content-type': 'text/event-stream' },
        })
      }),
    )

    const handle = createListenHandle(config, 'post', undefined, { reconnectBaseMs: 10 })
    const iterator = handle[Symbol.asyncIterator]()
    await expect(iterator.next()).rejects.toThrow(BarkparkAPIError)
    expect(calls).toBeGreaterThanOrEqual(5) // one open per silent close, up to the escalation
  }, 20_000)

  it('encodes Date filter values as ISO-8601, matching the query builder', async () => {
    let requestedUrl: string | undefined
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/listen/:dataset`, ({ request }) => {
        requestedUrl = request.url
        const stream = new ReadableStream<Uint8Array>({
          async start(controller) {
            const enc = new TextEncoder()
            controller.enqueue(enc.encode(`event: welcome\ndata: {"type":"welcome"}\n\n`))
            await delay(5_000)
            controller.close()
          },
        })
        return new HttpResponse(stream, {
          status: 200,
          headers: { 'content-type': 'text/event-stream' },
        })
      }),
    )

    const handle = createListenHandle(
      config,
      'post',
      { publishedAt: new Date('2026-07-02T10:00:00.000Z') },
      { maxReconnects: 0 },
    )
    const iterator = handle[Symbol.asyncIterator]()
    const first = await iterator.next()
    expect((first.value as ListenEvent).type).toBe('welcome')
    handle.unsubscribe()

    expect(requestedUrl).toContain('filter%5BpublishedAt%5D=2026-07-02T10%3A00%3A00.000Z')
    // NOT a locale-format date (bare String(Date) would emit 'Thu Jul 02 2026 …').
    expect(requestedUrl).not.toMatch(/Jul/)
  })

  it('throws BarkparkAuthError on 401 and does NOT retry', async () => {
    let attempts = 0
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/listen/:dataset`, () => {
        attempts++
        return HttpResponse.json(
          { error: { code: 'unauthorized', message: 'nope', request_id: 'req_x' } },
          { status: 401 },
        )
      }),
    )
    const handle = createListenHandle(config, 'post', undefined, { maxReconnects: 3 })
    await expect(async () => {
      const it = handle[Symbol.asyncIterator]()
      while (!(await it.next()).done) {
        /* drain until it throws — no event is reached */
      }
    }).rejects.toBeInstanceOf(BarkparkAuthError)
    expect(attempts).toBe(1)
  })

  it('throws BarkparkAPIError when response content-type is not SSE', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/listen/:dataset`, () =>
        HttpResponse.json({ not: 'sse' }, { status: 200 }),
      ),
    )
    const handle = createListenHandle(config, 'post', undefined, { maxReconnects: 0 })
    await expect(async () => {
      const it = handle[Symbol.asyncIterator]()
      while (!(await it.next()).done) {
        /* drain until it throws — no event is reached */
      }
    }).rejects.toBeInstanceOf(BarkparkAPIError)
  })

  describe('reconnect-knob validation', () => {
    // A spy fetch proves the throw is synchronous at the call site — no connection
    // is opened. NaN/negative reconnectBaseMs would otherwise flow to
    // Math.min(NaN * 2**n, 8000) = NaN → setTimeout(fn, NaN) → a zero-delay reconnect loop.
    function spyConfig(): { config: BarkparkClientConfig; calls: () => number } {
      let calls = 0
      const spied: BarkparkClientConfig = {
        ...config,
        fetch: ((..._args: unknown[]) => {
          calls++
          return Promise.reject(new Error('fetch must not be initiated'))
        }) as unknown as typeof globalThis.fetch,
      }
      return { config: spied, calls: () => calls }
    }

    it.each([
      ['NaN', Number.NaN],
      ['-1', -1],
      ['1.5', 1.5],
      ['Infinity', Number.POSITIVE_INFINITY],
    ])('rejects maxReconnects: %s with BarkparkValidationError (no fetch)', (_label, value) => {
      const { config: c, calls } = spyConfig()
      expect(() => createListenHandle(c, 'post', undefined, { maxReconnects: value })).toThrowError(
        BarkparkValidationError,
      )
      expect(calls()).toBe(0)
    })

    it.each([
      ['NaN', Number.NaN],
      ['-1', -1],
      ['1.5', 1.5],
      ['Infinity', Number.POSITIVE_INFINITY],
    ])('rejects reconnectBaseMs: %s with BarkparkValidationError (no fetch)', (_label, value) => {
      const { config: c, calls } = spyConfig()
      expect(() =>
        createListenHandle(c, 'post', undefined, { reconnectBaseMs: value }),
      ).toThrowError(BarkparkValidationError)
      expect(calls()).toBe(0)
    })

    it('sets field metadata on the thrown error', () => {
      try {
        createListenHandle(config, 'post', undefined, { maxReconnects: -1 })
        throw new Error('expected throw')
      } catch (err) {
        expect(err).toBeInstanceOf(BarkparkValidationError)
        expect((err as BarkparkValidationError).field).toBe('maxReconnects')
      }
      try {
        createListenHandle(config, 'post', undefined, { reconnectBaseMs: Number.NaN })
        throw new Error('expected throw')
      } catch (err) {
        expect(err).toBeInstanceOf(BarkparkValidationError)
        expect((err as BarkparkValidationError).field).toBe('reconnectBaseMs')
      }
    })

    it('accepts undefined and valid values without throwing', () => {
      expect(() => createListenHandle(config, 'post', undefined, {})).not.toThrow()
      expect(() =>
        createListenHandle(config, 'post', undefined, { maxReconnects: 0, reconnectBaseMs: 1 }),
      ).not.toThrow()
      expect(() =>
        createListenHandle(config, 'post', undefined, { maxReconnects: 10, reconnectBaseMs: 500 }),
      ).not.toThrow()
    })
  })

  describe('caller-signal listener lifecycle ([signal-listener-leak])', () => {
    // Wrap add/removeEventListener on a real AbortSignal to count net 'abort'
    // listeners. Before the fix, {once:true} only self-removed when the signal
    // FIRED, so tearing down a handle on a still-unfired long-lived signal left a
    // dead listener behind — net climbs by one per handle.
    function trackSignal(): { signal: AbortSignal; controller: AbortController; net: () => number } {
      const controller = new AbortController()
      const signal = controller.signal
      let net = 0
      const origAdd = signal.addEventListener.bind(signal)
      const origRemove = signal.removeEventListener.bind(signal)
      signal.addEventListener = ((type: string, ...rest: unknown[]) => {
        if (type === 'abort') net++
        return (origAdd as (...a: unknown[]) => void)(type, ...rest)
      }) as typeof signal.addEventListener
      signal.removeEventListener = ((type: string, ...rest: unknown[]) => {
        if (type === 'abort') net--
        return (origRemove as (...a: unknown[]) => void)(type, ...rest)
      }) as typeof signal.removeEventListener
      return { signal, controller, net: () => net }
    }

    it('unsubscribe() removes the abort listener — no accumulation on a shared signal', () => {
      const { signal, net } = trackSignal()
      // Reuse ONE long-lived signal across many handles, tearing each down. The
      // listener is registered synchronously at create time and must be gone after
      // unsubscribe(), so net returns to baseline (0) rather than climbing to 5.
      for (let i = 0; i < 5; i++) {
        const handle = createListenHandle(config, 'post', undefined, {
          maxReconnects: 0,
          signal,
        })
        handle.unsubscribe()
      }
      expect(net()).toBe(0)
    })

    it('a later abort of the shared signal does not re-enter a torn-down handle', () => {
      const { signal, controller, net } = trackSignal()
      const handle = createListenHandle(config, 'post', undefined, { maxReconnects: 0, signal })
      handle.unsubscribe()
      // The listener is already removed; firing the signal now is a no-op and must
      // not throw or resurrect anything. (removeEventListener is idempotent.)
      expect(() => controller.abort()).not.toThrow()
      expect(net()).toBe(0)
    })

    it('caller-signal abort still tears the stream down (no double-teardown throw)', async () => {
      // A custom fetch whose response body errors when the (forwarded) abort signal
      // fires — this models a real socket drop. MSW's mocked body ignores fetch-signal
      // aborts, so we bypass it here to exercise the signal-DOES-fire teardown path.
      const enc = new TextEncoder()
      const fetchImpl = ((_url: string, init?: RequestInit) => {
        const sig = init?.signal ?? undefined
        const stream = new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(enc.encode(`event: welcome\ndata: {"type":"welcome"}\n\n`))
            if (sig?.aborted) {
              controller.error(new Error('aborted'))
              return
            }
            sig?.addEventListener('abort', () => controller.error(new Error('aborted')), {
              once: true,
            })
          },
        })
        return Promise.resolve(
          new Response(stream, {
            status: 200,
            headers: { 'content-type': 'text/event-stream' },
          }),
        )
      }) as unknown as typeof globalThis.fetch

      const { signal, controller, net } = trackSignal()
      const handle = createListenHandle(
        { ...config, fetch: fetchImpl },
        'post',
        undefined,
        { maxReconnects: 0, signal },
      )
      const iterator = handle[Symbol.asyncIterator]()
      const first = await iterator.next()
      expect(first.done).toBe(false)
      expect((first.value as ListenEvent).type).toBe('welcome')

      // Abort via the CALLER's signal: the {once:true} listener fires + self-removes,
      // the stream errors, and the generator returns done WITHOUT throwing. The
      // redundant removeEventListener in teardown is a safe no-op (net stays 0).
      controller.abort()
      const next = await iterator.next()
      expect(next.done).toBe(true)
      expect(net()).toBe(0)
    })
  })
})
