import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createClient } from '../src/client'
import { BarkparkAPIError, isBarkparkError } from '../src/errors'
import type { BarkparkClientConfig } from '../src/types'

const baseConfig: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

async function collect<T>(it: AsyncIterable<T>): Promise<T[]> {
  const out: T[] = []
  for await (const x of it) out.push(x)
  return out
}

describe('exportDataset', () => {
  it('streams the NDJSON body as documents, one per line', async () => {
    const ndjson =
      JSON.stringify({ _id: 'a', _type: 'post', title: 'A' }) +
      '\n' +
      JSON.stringify({ _id: 'b', _type: 'post', title: 'B' }) +
      '\n'
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/export/:ds`, () =>
        new HttpResponse(ndjson, { headers: { 'content-type': 'application/x-ndjson' } }),
      ),
    )
    const bp = createClient(baseConfig)
    const docs = await collect(bp.exportDataset())
    expect(docs.map((d) => d._id)).toEqual(['a', 'b'])
    expect(docs[1]?.title).toBe('B')
  })

  it('yields the trailing line even when the stream ends without a newline', async () => {
    // Chunked NDJSON may end mid-line; the last record must not be dropped.
    const ndjson = JSON.stringify({ _id: 'only', _type: 'post' }) // no trailing \n
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/export/:ds`, () =>
        new HttpResponse(ndjson, { headers: { 'content-type': 'application/x-ndjson' } }),
      ),
    )
    const bp = createClient(baseConfig)
    const docs = await collect(bp.exportDataset())
    expect(docs.map((d) => d._id)).toEqual(['only'])
  })

  it('forwards type + perspective as query params', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/export/:ds`, ({ request }) => {
        seenUrl = request.url
        return new HttpResponse('', { headers: { 'content-type': 'application/x-ndjson' } })
      }),
    )
    const bp = createClient(baseConfig)
    await collect(bp.exportDataset({ type: 'post', perspective: 'published' }))
    const url = new URL(seenUrl)
    expect(url.searchParams.get('type')).toBe('post')
    expect(url.searchParams.get('perspective')).toBe('published')
  })

  it('wraps a malformed NDJSON line in a BarkparkAPIError (not a raw SyntaxError)', async () => {
    // A truncated stream or a proxy injecting an HTML error page mid-body makes
    // JSON.parse throw a SyntaxError isBarkparkError() would not recognize. One
    // valid line lands, then the non-JSON line must reject as a typed error.
    const ndjson = JSON.stringify({ _id: 'a', _type: 'post' }) + '\n' + '<html>oops</html>' + '\n'
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/export/:ds`, () => {
        const stream = new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(new TextEncoder().encode(ndjson))
            controller.close()
          },
        })
        return new HttpResponse(stream, {
          status: 200,
          headers: { 'content-type': 'application/x-ndjson' },
        })
      }),
    )
    const bp = createClient(baseConfig)
    const iterator = bp.exportDataset()[Symbol.asyncIterator]()
    const first = await iterator.next()
    expect(first.done).toBe(false)
    expect((first.value as { _id: string })._id).toBe('a')
    const err = await iterator.next().then(
      () => null,
      (e: unknown) => e,
    )
    expect(err).toBeInstanceOf(BarkparkAPIError)
    expect(isBarkparkError(err)).toBe(true)
  })

  it('throws on a non-ok response', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/export/:ds`, () =>
        HttpResponse.json({ error: { code: 'not_found' } }, { status: 404 }),
      ),
    )
    const bp = createClient(baseConfig)
    await expect(collect(bp.exportDataset())).rejects.toThrow(/export: HTTP 404/)
  })
})
