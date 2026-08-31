// Regression coverage for the isNetworkish 429 widening in src/listen.ts.
//
// Before the fix, assertStreamResponse (errors.ts) throws a 429 as a plain
// BarkparkAPIError, 429 < 500 fails the `>= 500` check, and the catch in
// createListenHandle falls straight to `throw err` — the whole subscription
// dies with ZERO backoff, during exactly the reconnect storm the jittered
// backoff exists to survive (a server restart or a shared rate-limit bucket
// makes every client reconnect — and get 429'd — at once).
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createListenHandle } from '../src/listen'
import { BarkparkAuthError } from '../src/errors'
import type { BarkparkClientConfig, ListenEvent } from '../src/types'

const config: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
  token: 'test-token',
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('createListenHandle — 429 reconnect policy', () => {
  it('reconnects after a DELAYED backoff on 429 and yields events (not an immediate retry)', async () => {
    vi.useFakeTimers()
    // withJitter(ms) === ms with random pinned to 1 — the delay becomes deterministic.
    const rand = vi.spyOn(Math, 'random').mockReturnValue(1)
    try {
      // A stub fetch (not msw) so fake timers drive the whole sequence
      // deterministically — same convention as the 'unbounded' describe block
      // above, which hits the same real-I/O-vs-fake-timers friction.
      let calls = 0
      const fetchImpl = (() => {
        calls++
        if (calls === 1) {
          return Promise.resolve(
            new Response(
              JSON.stringify({
                error: { code: 'rate_limited', message: 'slow down', request_id: 'req_429' },
              }),
              { status: 429, headers: { 'content-type': 'application/json' } },
            ),
          )
        }
        const stream = new ReadableStream<Uint8Array>({
          start(controller) {
            const enc = new TextEncoder()
            controller.enqueue(enc.encode(`event: welcome\ndata: {"type":"welcome"}\n\n`))
            controller.enqueue(
              enc.encode(
                `id: 1\nevent: mutation\ndata: ${JSON.stringify({
                  eventId: 1,
                  mutation: 'create',
                  documentId: 'p1',
                  rev: 'a'.repeat(32),
                  previousRev: null,
                })}\n\n`,
              ),
            )
            controller.close()
          },
        })
        return Promise.resolve(
          new Response(stream, { status: 200, headers: { 'content-type': 'text/event-stream' } }),
        )
      }) as unknown as typeof globalThis.fetch

      const handle = createListenHandle({ ...config, fetch: fetchImpl }, 'post', undefined, {
        reconnectBaseMs: 100,
        maxReconnects: 3,
      })
      const iterator = handle[Symbol.asyncIterator]()
      const first = iterator.next()

      // Connect #1 lands immediately and answers 429 — no reconnect yet.
      await vi.advanceTimersByTimeAsync(0)
      expect(calls).toBe(1)

      // Just short of the backoff window: still no second connect — proves the
      // reconnect is DELAYED, not immediate.
      await vi.advanceTimersByTimeAsync(99)
      expect(calls).toBe(1)

      // Crossing the backoff window opens connect #2, which answers 200 + events.
      await vi.advanceTimersByTimeAsync(1)
      expect(calls).toBe(2)

      const welcome = await first
      expect(welcome.done).toBe(false)
      expect((welcome.value as ListenEvent).type).toBe('welcome')

      const mutation = await iterator.next()
      expect((mutation.value as ListenEvent).type).toBe('mutation')
      expect((mutation.value as ListenEvent).eventId).toBe('1')

      handle.unsubscribe()
      await vi.advanceTimersByTimeAsync(0)
    } finally {
      rand.mockRestore()
      vi.useRealTimers()
    }
  })

  it('still throws BarkparkAuthError on 403 and does NOT reconnect (auth class untouched)', async () => {
    let attempts = 0
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/listen/:dataset`, () => {
        attempts++
        return HttpResponse.json(
          { error: { code: 'forbidden', message: 'nope', request_id: 'req_403' } },
          { status: 403 },
        )
      }),
    )
    const handle = createListenHandle(config, 'post', undefined, { maxReconnects: 3 })
    await expect(handle[Symbol.asyncIterator]().next()).rejects.toBeInstanceOf(BarkparkAuthError)
    // One attempt only — the widened isNetworkish check must not have swallowed
    // the auth class into a retry loop.
    expect(attempts).toBe(1)
  })
})
