import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createDocsOperation } from '../src/docs'
import type { BarkparkClientConfig } from '../src/types'

// [page-truncation-derived] `/v1/data/query` answers truncation EXACTLY and for
// free: query_controller.ex reads one row past the page and reports whether that
// row materialised, as `hasMore`, plus a `nextOffset` when a next page exists.
//
// `findPage()` received both on every response and threw them away. Its
// QueryPage was rebuilt from documents/total/count/limit/offset alone, so a
// caller had two ways to ask "is there more", and the cheap one is wrong:
//
//   count === limit    — a type holding exactly `limit` rows and one holding a
//                        million are byte-identical under it
//   offset+count<total — correct, but only because findPage pays for a second
//                        COUNT query on the server to learn `total`
//
// These tests pin that the server's own answer now reaches the caller, in both
// envelope shapes the SDK claims to accept, and that `nextOffset` is ABSENT
// rather than 0 when there is no next page.

const config: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
}

const DOC = { _id: 'p1', _type: 'post', title: 'Hello' }

/** Serve one query response body verbatim. `wrap` picks the envelope shape. */
function serveBody(inner: Record<string, unknown>, wrap: boolean): void {
  server.use(
    http.get(`${TEST_BASE_URL}/v1/data/query/:dataset/:type`, () =>
      HttpResponse.json(wrap ? { result: inner, ms: 1 } : inner),
    ),
  )
}

const page = (extra: Record<string, unknown>) => ({
  perspective: 'published',
  documents: [DOC],
  count: 1,
  limit: 1,
  offset: 0,
  total: 500,
  ...extra,
})

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('findPage() carries the server’s own truncation signal', () => {
  // docs.ts documents tolerance for BOTH shapes (`{ result: … }` when the
  // filter-response wrapper is on, flat when it is off). A field read from only
  // one of them is a field half the deployments never see.
  for (const wrap of [true, false]) {
    const shape = wrap ? 'wrapped' : 'flat'

    it(`reads hasMore + nextOffset from a ${shape} envelope`, async () => {
      serveBody(page({ hasMore: true, nextOffset: 1 }), wrap)
      const res = await createDocsOperation(config, 'post').limit(1).findPage()
      expect(res.hasMore).toBe(true)
      expect(res.nextOffset).toBe(1)
      // …without disturbing anything findPage already returned.
      expect(res.documents).toEqual([DOC])
      expect(res.total).toBe(500)
      expect(res.count).toBe(1)
      expect(res.limit).toBe(1)
      expect(res.offset).toBe(0)
    })

    it(`reads hasMore: false from a ${shape} envelope, with nextOffset ABSENT`, async () => {
      serveBody(page({ hasMore: false }), wrap)
      const res = await createDocsOperation(config, 'post').limit(1).findPage()
      expect(res.hasMore).toBe(false)
      // Absent, never 0 — a 0 here would read as a valid offset and re-serve
      // the page the caller just read.
      expect('nextOffset' in res).toBe(false)
    })
  }

  it('an exhausted page and a truncated one are now distinguishable at identical count/limit', async () => {
    // The whole point. Both responses are byte-identical on count, limit and
    // offset; only hasMore separates "that was everything" from "there are 499
    // more". Under the old QueryPage a caller comparing count to limit called
    // BOTH truncated, and a caller with no total had nothing else to look at.
    serveBody(page({ total: 1, hasMore: false }), false)
    const exhausted = await createDocsOperation(config, 'post').limit(1).findPage()

    serveBody(page({ total: 500, hasMore: true, nextOffset: 1 }), false)
    const truncated = await createDocsOperation(config, 'post').limit(1).findPage()

    expect(exhausted.count).toBe(truncated.count)
    expect(exhausted.limit).toBe(truncated.limit)
    expect(exhausted.count === exhausted.limit).toBe(true) // the wrong derivation fires on BOTH
    expect(exhausted.hasMore).toBe(false)
    expect(truncated.hasMore).toBe(true)
  })

  it('a server too old to send hasMore reports false rather than undefined', async () => {
    serveBody(page({}), false)
    const res = await createDocsOperation(config, 'post').limit(1).findPage()
    expect(res.hasMore).toBe(false)
    expect('nextOffset' in res).toBe(false)
  })
})

// The three executors now share one request helper. It deliberately returns the
// envelope WITHOUT unwrapping, because find and count use a different fallback
// chain (`data.result?.x ?? data.x`) from page (`data.result ?? data`). These
// pin that difference so the fold cannot quietly become a behaviour change.
describe('the shared read helper preserves each executor’s own envelope fallback', () => {
  it('find() falls back to the OUTER documents when a result wrapper omits them', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:dataset/:type`, () =>
        HttpResponse.json({ result: { perspective: 'published' }, documents: [DOC] }),
      ),
    )
    expect(await createDocsOperation(config, 'post').find()).toEqual([DOC])
  })

  it('count() falls back to the OUTER total when a result wrapper omits it', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:dataset/:type`, () =>
        HttpResponse.json({ result: { perspective: 'published' }, total: 42 }),
      ),
    )
    expect(await createDocsOperation(config, 'post').count()).toBe(42)
  })

  it('each executor still sends its own query string', async () => {
    const urls: string[] = []
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:dataset/:type`, ({ request }) => {
        urls.push(new URL(request.url).search)
        return HttpResponse.json(page({ hasMore: false }))
      }),
    )
    const b = () => createDocsOperation(config, 'post').eq('status', 'published').limit(20)
    await b().find()
    await b().count()
    await b().findPage()

    // find: no count. count: a minimal page AND count=true. page: the caller's
    // limit AND count=true.
    expect(urls[0]).toContain('limit=20')
    expect(urls[0]).not.toContain('count=true')
    expect(urls[1]).toContain('limit=1')
    expect(urls[1]).toContain('count=true')
    expect(urls[2]).toContain('limit=20')
    expect(urls[2]).toContain('count=true')
    // and every one still carries the filter
    expect(urls.every((u) => u.includes('status'))).toBe(true)
  })
})
