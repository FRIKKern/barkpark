import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest'
import { http } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createListenHandle } from '../src/listen'
import type { BarkparkClientConfig, ListenEvent } from '../src/types'

// listen('post') used to yield ARTICLE mutations too. The server's listen route
// does not read `?types=` — it streams every type in scope — and the client
// trusted it to (stranger walk against a local instance, 2026-09-30). The
// requested type set is now applied client-side. These frames are the server's
// real shape: a top-level `type` beside `result._type`.

const config: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
  token: 'test-token',
}

const enc = new TextEncoder()

function frame(id: number, type: string): string {
  return `id: ${id}\nevent: mutation\ndata: ${JSON.stringify({
    eventId: id,
    type,
    mutation: 'update',
    documentId: `drafts.${type}-${id}`,
    previousRev: null,
    result: { _id: `drafts.${type}-${id}`, _type: type },
    syncTags: [`bp:ds:production:type:${type}`],
  })}\n\n`
}

const WELCOME = 'event: welcome\ndata: {"type":"welcome"}\n\n'

function serveFrames(frames: string[]): { urls: string[] } {
  const seen = { urls: [] as string[] }
  server.use(
    http.get(`${TEST_BASE_URL}/v1/data/listen/:dataset`, ({ request }) => {
      seen.urls.push(request.url)
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
  return seen
}

async function take(type: string | undefined, n: number): Promise<ListenEvent[]> {
  const events: ListenEvent[] = []
  const handle = createListenHandle(config, type)
  for await (const evt of handle) {
    events.push(evt)
    if (events.length >= n) break
  }
  handle.unsubscribe()
  return events
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('listen(type): only the requested types reach the consumer', () => {
  it("listen('post') skips another type's mutation and keeps the welcome", async () => {
    const seen = serveFrames([
      WELCOME,
      frame(1, 'article'),
      frame(2, 'post'),
      frame(3, 'article'),
      frame(4, 'post'),
    ])
    const events = await take('post', 3)

    expect(events.map((e) => e.type)).toEqual(['welcome', 'mutation', 'mutation'])
    expect(events.slice(1).map((e) => e.documentId)).toEqual(['drafts.post-2', 'drafts.post-4'])
    // The param still rides the request, for a server that learns to filter.
    expect(new URL(seen.urls[0]!).searchParams.get('types')).toBe('post')
  })

  it('a comma-separated list admits each named type', async () => {
    serveFrames([frame(1, 'author'), frame(2, 'article'), frame(3, 'post')])
    const events = await take('post, article', 2)
    expect(events.map((e) => e.documentId)).toEqual(['drafts.article-2', 'drafts.post-3'])
  })

  it('no type means every type, as before', async () => {
    serveFrames([frame(1, 'author'), frame(2, 'article')])
    const events = await take(undefined, 2)
    expect(events.map((e) => e.documentId)).toEqual(['drafts.author-1', 'drafts.article-2'])
  })

  it('falls back to result._type when a frame has no top-level type', async () => {
    const noTop = (id: number, t: string) =>
      `id: ${id}\nevent: mutation\ndata: ${JSON.stringify({ eventId: id, mutation: 'create', documentId: `drafts.${t}-${id}`, result: { _id: `drafts.${t}-${id}`, _type: t } })}\n\n`
    serveFrames([noTop(1, 'article'), noTop(2, 'post')])
    const events = await take('post', 1)
    expect(events.map((e) => e.documentId)).toEqual(['drafts.post-2'])
  })
})
