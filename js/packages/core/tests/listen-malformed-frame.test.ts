import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest'
import { http } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createListenHandle } from '../src/listen'
import type { BarkparkClientConfig, ListenEvent } from '../src/types'
import type { ListenOptions } from '../src/index'

// [malformed-frame-silent] A frame whose `data:` does not parse as JSON is
// dropped. That part is correct — killing a live subscription over one corrupt
// event is worse than losing it. What was wrong is that the drop was reported on
// NO channel: no throw, no callback, no counter, while the async iterator's
// "here is every event" contract stayed nominally true. A consumer doing cache
// revalidation went quietly stale with a green process.
//
// onDroppedFrame is that missing channel. These tests pin BOTH halves: the skip
// still happens (the frames around a bad one still arrive) AND it is now visible.

const config: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
  token: 'test-token',
}

// onDroppedFrame is part of the PUBLIC option type, imported from ../src/index —
// drop it from the exported interface and tsc fails here.
const _optionsCarryTheCallback: ListenOptions = { onDroppedFrame: () => {} }
void _optionsCarryTheCallback

const enc = new TextEncoder()

function goodFrame(id: number): string {
  return `id: ${id}\nevent: mutation\ndata: ${JSON.stringify({
    eventId: id,
    mutation: 'create',
    documentId: `drafts.m${id}`,
    previousRev: null,
    result: { _id: `drafts.m${id}`, _type: 'post' },
  })}\n\n`
}

function badFrame(n: number): string {
  return `id: bad-${n}\nevent: mutation\ndata: {"eventId": ${n}, TRUNCATED\n\n`
}

// Serve exactly these frames, then hold the connection open forever so the
// generator never reaches the clean-close reconnect path — the test decides when
// to stop, not the transport.
function serveFrames(frames: string[]): void {
  server.use(
    http.get(`${TEST_BASE_URL}/v1/data/listen/:dataset`, () => {
      const stream = new ReadableStream<Uint8Array>({
        start(controller) {
          for (const f of frames) controller.enqueue(enc.encode(f))
          // never close
        },
      })
      return new Response(stream, {
        headers: { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' },
      })
    }),
  )
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('listen(): a malformed frame is a reported loss, not a silent one', () => {
  it('still yields the surrounding good events, and reports the dropped one', async () => {
    serveFrames([goodFrame(1), badFrame(1), goodFrame(2)])

    const dropped: Array<{ raw: string; err: unknown }> = []
    const events: ListenEvent[] = []
    const handle = createListenHandle(config, 'post', undefined, {
      onDroppedFrame: (raw, err) => dropped.push({ raw, err }),
    })
    for await (const evt of handle) {
      events.push(evt)
      if (events.length >= 2) break
    }
    handle.unsubscribe()

    // The skip-and-continue behaviour is preserved: one bad frame does not cost
    // the caller the frames around it.
    expect(events.map((e) => e.documentId)).toEqual(['drafts.m1', 'drafts.m2'])

    // …and the loss is visible, which is the whole point.
    expect(dropped).toHaveLength(1)
    expect(dropped[0]!.raw).toContain('TRUNCATED')
    expect(dropped[0]!.err).toBeInstanceOf(Error)
  })

  it('reports EVERY drop, not just the first', async () => {
    // A run of bad frames is the case where silent loss compounds — a consumer
    // that only learned about the first one would still under-count the damage.
    serveFrames([
      ...Array.from({ length: 4 }, (_, i) => badFrame(i)),
      goodFrame(1),
      ...Array.from({ length: 4 }, (_, i) => badFrame(10 + i)),
      goodFrame(2),
    ])

    const raws: string[] = []
    const events: ListenEvent[] = []
    const handle = createListenHandle(config, 'post', undefined, {
      onDroppedFrame: (raw) => raws.push(raw),
    })
    for await (const evt of handle) {
      events.push(evt)
      if (events.length >= 2) break
    }
    handle.unsubscribe()

    expect(events.map((e) => e.documentId)).toEqual(['drafts.m1', 'drafts.m2'])
    expect(raws).toHaveLength(8)
  })

  it('a broken encoder is diagnosable ONLY through the callback — the eventual throw names the wrong cause', async () => {
    // The pathological case: every frame is malformed. The subscription stays
    // alive by design, so the idle watchdog eventually recycles it, and after
    // MAX_CONSECUTIVE_CLEAN_CLOSES cycles the [clean-close-infinite-silent]
    // escalation fires — naming an EMPTY stream, when the stream was never
    // empty. That mis-attribution is the residual this row flagged and the
    // follow-up escalation row will fix; it is pinned here so the follow-up has
    // a red to turn green rather than a claim to re-derive.
    serveFrames(Array.from({ length: 5 }, (_, i) => badFrame(i)))

    const raws: string[] = []
    const handle = createListenHandle(config, 'post', undefined, {
      onDroppedFrame: (raw) => raws.push(raw),
      idleTimeoutMs: 50,
      reconnectBaseMs: 1,
    })
    const events: ListenEvent[] = []
    let thrown: unknown
    try {
      for await (const evt of handle) {
        events.push(evt)
        break
      }
    } catch (err) {
      thrown = err
    }
    handle.unsubscribe()

    // No event ever reached the consumer…
    expect(events).toHaveLength(0)
    // …every lost frame was reported, across every reconnect cycle…
    expect(raws.length).toBeGreaterThanOrEqual(5)
    expect(raws.every((r) => r.includes('TRUNCATED'))).toBe(true)
    // …and the only error the stream raises on its own blames the transport.
    expect((thrown as Error | undefined)?.message).toContain('repeated empty stream closes')
  })

  it('a throwing onDroppedFrame cannot take down the subscription', async () => {
    serveFrames([badFrame(1), goodFrame(1)])

    const events: ListenEvent[] = []
    const handle = createListenHandle(config, 'post', undefined, {
      onDroppedFrame: () => {
        throw new Error('a logger blew up')
      },
    })
    for await (const evt of handle) {
      events.push(evt)
      break
    }
    handle.unsubscribe()

    expect(events.map((e) => e.documentId)).toEqual(['drafts.m1'])
  })
})
