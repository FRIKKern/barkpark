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

describe('getRelated', () => {
  it('GETs /v1/data/related/:ds/:id and returns the {related, count} result', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/related/:ds/:id`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({
          result: {
            related: [
              {
                doc_id: 'p2',
                type: 'paper',
                title: 'Sibling',
                score: 1.5,
                sources: ['tags', 'references'],
                shared_tags: [{ tag: 'search', src_strength: 80, cand_strength: 60 }],
              },
            ],
            count: 1,
          },
          syncTags: [`bp:ds:${TEST_DATASET}:related:p1`],
        })
      }),
    )
    const bp = createClient(baseConfig)
    const res = await bp.getRelated('p1')
    expect(res.count).toBe(1)
    expect(res.related).toHaveLength(1)
    expect(res.related[0]!.doc_id).toBe('p2')
    expect(res.related[0]!.sources).toEqual(['tags', 'references'])
    expect(res.related[0]!.shared_tags[0]!.tag).toBe('search')
    const url = new URL(seenUrl)
    expect(url.pathname).toBe(`/v1/data/related/${TEST_DATASET}/p1`)
  })

  it('passes limit as a query param', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/related/:ds/:id`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ result: { related: [], count: 0 } })
      }),
    )
    const bp = createClient(baseConfig)
    await bp.getRelated('p1', { limit: 5 })
    expect(new URL(seenUrl).searchParams.get('limit')).toBe('5')
  })

  it('omits the limit param when not given', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/related/:ds/:id`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ result: { related: [], count: 0 } })
      }),
    )
    const bp = createClient(baseConfig)
    await bp.getRelated('p1')
    expect(new URL(seenUrl).searchParams.has('limit')).toBe(false)
  })

  it('encodes the id in the path', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/related/:ds/:id`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ result: { related: [], count: 0 } })
      }),
    )
    const bp = createClient(baseConfig)
    await bp.getRelated('drafts.weird id')
    expect(new URL(seenUrl).pathname).toBe(`/v1/data/related/${TEST_DATASET}/drafts.weird%20id`)
  })

  it('throws BarkparkValidationError for an empty id (no network call)', async () => {
    const bp = createClient(baseConfig)
    await expect(bp.getRelated('')).rejects.toMatchObject({
      code: 'BarkparkValidationError',
      field: 'id',
    })
  })

  it('throws BarkparkValidationError for a non-integer limit (no network call)', async () => {
    const bp = createClient(baseConfig)
    await expect(bp.getRelated('p1', { limit: 0 })).rejects.toMatchObject({
      code: 'BarkparkValidationError',
      field: 'limit',
    })
    await expect(bp.getRelated('p1', { limit: 2.5 })).rejects.toMatchObject({
      code: 'BarkparkValidationError',
      field: 'limit',
    })
  })
})
