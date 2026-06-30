import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createClient } from '../src/client'
import type { BarkparkClientConfig } from '../src/types'

const baseConfig: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
  token: 'tok',
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('getBacklinks', () => {
  it('GETs /v1/data/backlinks/:ds/:id and returns the {backlinks, count} result', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/backlinks/:ds/:id`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({
          result: {
            backlinks: [
              { from_doc_id: 'art-1', title: 'Refs Target', type: 'article', kind: 'references' },
            ],
            count: 1,
          },
        })
      }),
    )
    const bp = createClient(baseConfig)
    const res = await bp.getBacklinks('author-1')
    expect(res.count).toBe(1)
    expect(res.backlinks).toHaveLength(1)
    expect(res.backlinks[0]!.from_doc_id).toBe('art-1')
    expect(res.backlinks[0]!.title).toBe('Refs Target')
    const url = new URL(seenUrl)
    expect(url.pathname).toBe(`/v1/data/backlinks/${TEST_DATASET}/author-1`)
  })

  it('returns an empty list for a doc with no referencers', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/backlinks/:ds/:id`, () =>
        HttpResponse.json({ result: { backlinks: [], count: 0 } }),
      ),
    )
    const bp = createClient(baseConfig)
    const res = await bp.getBacklinks('art-1')
    expect(res.backlinks).toEqual([])
    expect(res.count).toBe(0)
  })

  it('encodes the id in the path', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/backlinks/:ds/:id`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ result: { backlinks: [], count: 0 } })
      }),
    )
    const bp = createClient(baseConfig)
    await bp.getBacklinks('drafts.weird id')
    expect(new URL(seenUrl).pathname).toBe(`/v1/data/backlinks/${TEST_DATASET}/drafts.weird%20id`)
  })
})
