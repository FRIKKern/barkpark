import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createClient } from '../src/client'
import { searchDocuments } from '../src/search'
import { BarkparkValidationError } from '../src/errors'
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

describe('search', () => {
  it('GETs /v1/data/search with q/limit/engine and returns the flat result', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/search/:ds`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json(
          {
            documents: [{ _id: 'p1', _type: 'post', title: 'Headless CMS' }],
            count: 1,
            query: 'headless',
            highlights: { title: ['<em>Headless</em> CMS'] },
            correctedTo: null,
            facets: {
              type: [
                { label: 'post', count: 1 },
                { label: 'page', count: 0 },
              ],
              status: [{ label: 'published', count: 1 }],
            },
            parsedQuery: { terms: ['headless'] },
            recovery: { applied: false },
            truncation: false,
            searchEventId: 'evt_abc123',
            ms: 42,
          },
          { status: 200 },
        )
      }),
    )

    const bp = createClient(baseConfig)
    const res = await bp.search('headless', { limit: 10, engine: 'postgres' })

    expect(res.count).toBe(1)
    expect(res.documents).toHaveLength(1)
    expect(res.query).toBe('headless')
    expect(res.correctedTo).toBeNull()
    // Facets are surfaced for faceted-search UIs (was dropped before).
    expect(res.facets?.type?.[0]).toEqual({ label: 'post', count: 1 })
    expect(res.facets?.status).toEqual([{ label: 'published', count: 1 }])
    // The remaining response fields are surfaced too (were dropped before).
    expect(res.parsedQuery).toEqual({ terms: ['headless'] })
    expect(res.recovery).toEqual({ applied: false })
    expect(res.truncation).toBe(false)
    expect(res.ms).toBe(42)
    // searchEventId round-trips — required by /search/interaction (was dropped before).
    expect(res.searchEventId).toBe('evt_abc123')

    const url = new URL(seenUrl)
    expect(url.pathname).toBe(`/v1/data/search/${TEST_DATASET}`)
    expect(url.searchParams.get('q')).toBe('headless')
    expect(url.searchParams.get('limit')).toBe('10')
    expect(url.searchParams.get('engine')).toBe('postgres')
  })

  it('forwards offset (pagination) and type (scope) to the query', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/search/:ds`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ documents: [], count: 42 }, { status: 200 })
      }),
    )

    const bp = createClient(baseConfig)
    const res = await bp.search('cms', { limit: 10, offset: 20, type: 'post' })

    // count is the TOTAL — the paginator's denominator
    expect(res.count).toBe(42)
    const url = new URL(seenUrl)
    expect(url.searchParams.get('offset')).toBe('20')
    expect(url.searchParams.get('type')).toBe('post')
    expect(url.searchParams.get('limit')).toBe('10')
  })

  it('forwards a multi-type allowlist as the `types` CSV param', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/search/:ds`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ documents: [], count: 0 }, { status: 200 })
      }),
    )

    const bp = createClient(baseConfig)
    // Cross-type search — the API supports `?types=a,b` (parse_types); before
    // this the SDK could only scope to a single `type`.
    await bp.search('cms', { types: ['post', 'author'] })
    expect(new URL(seenUrl).searchParams.get('types')).toBe('post,author')

    // An empty array sends nothing (no restriction), not `types=`.
    await bp.search('cms', { types: [] })
    expect(new URL(seenUrl).searchParams.has('types')).toBe(false)
  })

  it('forwards the client perspective (a drafts client searches drafts), with a per-call override', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/search/:ds`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ documents: [], count: 0 }, { status: 200 })
      }),
    )

    // config perspective flows through, matching doc/docs reads
    await createClient({ ...baseConfig, perspective: 'drafts' }).search('x')
    expect(new URL(seenUrl).searchParams.get('perspective')).toBe('drafts')

    // a per-call opts.perspective wins over the client config
    await createClient({ ...baseConfig, perspective: 'drafts' }).search('x', { perspective: 'raw' })
    expect(new URL(seenUrl).searchParams.get('perspective')).toBe('raw')
  })

  it('tolerates an enveloped { result } body and defaults missing fields', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/search/:ds`, () =>
        HttpResponse.json({ result: { documents: [], count: 0 } }, { status: 200 }),
      ),
    )
    const res = await searchDocuments(baseConfig, 'nothing')
    expect(res.documents).toEqual([])
    expect(res.count).toBe(0)
    expect(res.query).toBe('nothing') // falls back to the query arg
    expect(res.correctedTo).toBeNull()
    // Absent on the wire -> defaults to null, not undefined.
    expect(res.searchEventId).toBeNull()
  })

  it('rejects a types entry containing a comma (fail-closed, no request sent)', async () => {
    // A comma inside a type name would silently split into extra types on the
    // wire (`types=post,secret` → post OR secret), an over-broad allowlist.
    await expect(searchDocuments(baseConfig, 'cms', { types: ['post,author'] })).rejects.toMatchObject(
      { code: 'BarkparkValidationError', field: 'types' },
    )
  })

  it('rejects an empty query string (fail-closed, no request sent)', async () => {
    await expect(searchDocuments(baseConfig, '')).rejects.toThrow(BarkparkValidationError)
  })

  it('rejects a whitespace-only query string (fail-closed, no request sent)', async () => {
    await expect(searchDocuments(baseConfig, '   ')).rejects.toThrow(BarkparkValidationError)
  })
})

describe('getSearchSuggestions', () => {
  it('GETs /v1/data/search/:dataset/suggestions with the prefix + limit, unwrapping buckets', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/search/:ds/suggestions`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({
          result: {
            recent: [{ query: 'react', count: 3 }],
            popular: [{ query: 'reactivity', count: 40 }],
            nohits: [],
          },
        })
      }),
    )
    const bp = createClient(baseConfig)
    const sug = await bp.getSearchSuggestions('rea', { limit: 5 })

    const url = new URL(seenUrl)
    expect(url.pathname).toBe(`/v1/data/search/${TEST_DATASET}/suggestions`)
    expect(url.searchParams.get('q')).toBe('rea')
    expect(url.searchParams.get('limit')).toBe('5')
    expect(sug.recent[0]?.query).toBe('react')
    expect(sug.popular[0]?.count).toBe(40)
    expect(sug.nohits).toEqual([])
  })

  it('omits q when no prefix and defaults missing buckets to []', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/search/:ds/suggestions`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ result: {} })
      }),
    )
    const bp = createClient(baseConfig)
    const sug = await bp.getSearchSuggestions()

    expect(new URL(seenUrl).searchParams.has('q')).toBe(false)
    expect(sug).toEqual({ recent: [], popular: [], nohits: [] })
  })

  it('rejects limit:0 with BarkparkValidationError (fail-closed paging)', async () => {
    await expect(
      createClient(baseConfig).getSearchSuggestions('x', { limit: 0 }),
    ).rejects.toBeInstanceOf(BarkparkValidationError)
  })
})

// sessionKey (sdk-search-suggestions-session-key-opt): the tokenless
// per-session identity, threaded as x-bp-search-client on BOTH halves of the
// loop — search() records under the key, getSearchSuggestions() reads it back
// — mirroring the per-session UUID the browser UI mints. Without it, a
// header-less tokenless caller gets [] recents by design (the anon
// fail-close), which is correct but leaves SDK consumers no ergonomic opt-in.
describe('sessionKey → x-bp-search-client (tokenless per-session recents)', () => {
  it('getSearchSuggestions threads sessionKey as the x-bp-search-client header', async () => {
    let seenHeader: string | null = null
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/search/:ds/suggestions`, ({ request }) => {
        seenHeader = request.headers.get('x-bp-search-client')
        return HttpResponse.json({ result: {} })
      }),
    )
    await createClient(baseConfig).getSearchSuggestions('rea', {
      sessionKey: 'sess-uuid-1234',
    })
    expect(seenHeader).toBe('sess-uuid-1234')
  })

  it('search() threads the SAME opt — the record half of the recents loop', async () => {
    let seenHeader: string | null = null
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/search/:ds`, ({ request }) => {
        seenHeader = request.headers.get('x-bp-search-client')
        return HttpResponse.json({ result: { documents: [], count: 0, query: 'cms', correctedTo: null } })
      }),
    )
    await createClient(baseConfig).search('cms', { sessionKey: 'sess-uuid-1234' })
    expect(seenHeader).toBe('sess-uuid-1234')
  })

  it('no sessionKey → no header (the fail-closed default is untouched)', async () => {
    let present: boolean | null = null
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/search/:ds/suggestions`, ({ request }) => {
        present = request.headers.has('x-bp-search-client')
        return HttpResponse.json({ result: {} })
      }),
    )
    await createClient(baseConfig).getSearchSuggestions()
    expect(present).toBe(false)
  })
})
