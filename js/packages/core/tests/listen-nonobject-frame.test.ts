import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest'
import { http } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createListenHandle } from '../src/listen'
import type { BarkparkClientConfig, ListenEvent } from '../src/types'

// [malformed-frame-silent, second half] A frame whose `data:` does not PARSE is
// skipped and reported through onDroppedFrame — that half landed. This is the
// other half: a frame whose data parses fine but is not a JSON OBJECT.
//
// `data: null`, `data: 42`, `data: "hi"`, `data: [1,2]` all reached
// `payload = v && typeof v === 'object' ? v : {}` and collapsed to `{}`. An
// empty payload is not dropped — it is BUILT. `buildListenEvent` maps an
// unrecognised SSE event name to 'welcome' and a missing eventId to '', so the
// iterator YIELDED a synthetic `{ eventId: '', type: 'welcome' }` that the
// server never sent, on no channel at all.
//
// That is strictly worse than the case sitting next to it: the parse failure
// lost an event, this one INVENTED one. `welcome` is the stream's "I am
// (re)connected, reset your cursor" signal, so a consumer keying on it acts on
// a fabrication. Both are now the same skip with the same report channel.

const config: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
  token: 'test-token',
}

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

/** A frame whose data is valid JSON but not an object. */
function scalarFrame(id: string, json: string): string {
  return `id: ${id}\nevent: mutation\ndata: ${json}\n\n`
}

function serveFrames(frames: string[]): void {
  server.use(
    http.get(`${TEST_BASE_URL}/v1/data/listen/:dataset`, () => {
      const stream = new ReadableStream<Uint8Array>({
        start(controller) {
          for (const f of frames) controller.enqueue(enc.encode(f))
          // never close — the test decides when to stop
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

// Every JSON value that is not an object. `[1,2]` is the sharp one: an array IS
// `typeof 'object'`, so the old guard let it through and it fabricated an event
// exactly like the scalars did.
const NON_OBJECTS: Array<[string, string]> = [
  ['null', 'null'],
  ['a number', '42'],
  ['a string', '"hello"'],
  ['a boolean', 'true'],
  ['an array', '[1,2]'],
]

describe('listen(): a frame that parses to a non-object is a reported loss, not a fabricated event', () => {
  for (const [label, json] of NON_OBJECTS) {
    it(`does not yield a phantom welcome for ${label}`, async () => {
      serveFrames([scalarFrame(`bad-${label}`, json), goodFrame(1)])

      const dropped: Array<{ raw: string; err: unknown }> = []
      const events: ListenEvent[] = []
      const handle = createListenHandle(config, 'post', undefined, {
        onDroppedFrame: (raw, err) => dropped.push({ raw, err }),
      })
      for await (const evt of handle) {
        events.push(evt)
        break
      }
      handle.unsubscribe()

      // The ONLY event the consumer sees is the real one. Before the fix the
      // first event was `{ eventId: '', type: 'welcome' }` — a message the
      // server never sent — and the real mutation came second.
      expect(events).toHaveLength(1)
      expect(events[0]!.type).toBe('mutation')
      expect(events[0]!.documentId).toBe('drafts.m1')

      // …and the loss is visible on the same channel a parse failure uses.
      expect(dropped).toHaveLength(1)
      expect(dropped[0]!.raw).toBe(json)
      expect(dropped[0]!.err).toBeInstanceOf(TypeError)
    })
  }

  it('keeps skipping rather than crashing: the frames around a run of them still arrive', async () => {
    serveFrames([
      goodFrame(1),
      scalarFrame('a', 'null'),
      scalarFrame('b', '[]'),
      scalarFrame('c', '0'),
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
    expect(raws).toEqual(['null', '[]', '0'])
  })

  it('an OBJECT payload is untouched — including an empty one, which is a real server frame', async () => {
    // `data: {}` is legitimate: the welcome frame carries no fields. It must
    // keep yielding, so the guard has to reject non-objects WITHOUT rejecting
    // the empty object the old collapse produced by accident.
    serveFrames([`event: welcome\ndata: {}\n\n`, goodFrame(1)])

    const dropped: string[] = []
    const events: ListenEvent[] = []
    const handle = createListenHandle(config, 'post', undefined, {
      onDroppedFrame: (raw) => dropped.push(raw),
    })
    for await (const evt of handle) {
      events.push(evt)
      if (events.length >= 2) break
    }
    handle.unsubscribe()

    expect(dropped).toEqual([])
    expect(events.map((e) => e.type)).toEqual(['welcome', 'mutation'])
  })
})

// The guard above cost bytes that @barkpark/core's gzipped cap did not have, so
// it is paid for by dropping a dead `Number.isFinite` conjunct from the
// reconnectBaseMs check — `Number.isInteger` is already false for every
// non-finite number. That is a claim about behaviour, so it gets a test: the
// suite covered NaN but never Infinity, which is exactly the case the removed
// conjunct looked like it was there for.
describe('reconnectBaseMs still rejects every non-finite value with isInteger alone', () => {
  for (const bad of [Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY, 1.5, 0, -1]) {
    it(`throws on ${String(bad)}`, () => {
      expect(() => createListenHandle(config, 'post', undefined, { reconnectBaseMs: bad })).toThrow(
        'reconnectBaseMs must be a positive integer',
      )
    })
  }

  it('still accepts a positive integer', () => {
    expect(() =>
      createListenHandle(config, 'post', undefined, { reconnectBaseMs: 500 }),
    ).not.toThrow()
  })
})
