import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createClient } from '../src/client'
import { searchDocuments } from '../src/search'
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
  })
})
