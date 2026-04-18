import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest'
import { http, HttpResponse, delay } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createListenHandle } from '../src/listen'
import {
  BarkparkAPIError,
  BarkparkAuthError,
  BarkparkEdgeRuntimeError,
} from '../src/errors'
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
      for await (const _evt of handle) {
        /* not reached */
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
      for await (const _evt of handle) {
        /* not reached */
      }
    }).rejects.toBeInstanceOf(BarkparkAPIError)
  })
})
