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

describe('getHistory / getRevision / restoreRevision', () => {
  it('getHistory GETs /v1/data/history/:ds/:type/:id and returns the revisions', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/history/:ds/:type/:id`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({
          revisions: [
            { id: 'r2', action: 'update', title: 'v2', timestamp: '2026-04-18T01:00:00Z' },
            { id: 'r1', action: 'create', title: 'v1', timestamp: '2026-04-18T00:00:00Z' },
          ],
        })
      }),
    )
    const bp = createClient(baseConfig)
    const revs = await bp.getHistory('post', 'p1', { limit: 10 })
    expect(revs).toHaveLength(2)
    expect(revs[0]!.id).toBe('r2')
    const url = new URL(seenUrl)
    expect(url.pathname).toBe(`/v1/data/history/${TEST_DATASET}/post/p1`)
    expect(url.searchParams.get('limit')).toBe('10')
  })

  it('getHistory validates limit client-side (rejects -1 / NaN, accepts 10)', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/history/:ds/:type/:id`, () =>
        HttpResponse.json({ revisions: [] }),
      ),
    )
    const bp = createClient(baseConfig)
    await expect(bp.getHistory('post', 'p1', { limit: -1 })).rejects.toThrow(
      /limit must be a positive integer/,
    )
    await expect(bp.getHistory('post', 'p1', { limit: NaN })).rejects.toThrow(
      /limit must be a positive integer/,
    )
    await expect(bp.getHistory('post', 'p1', { limit: 10 })).resolves.toEqual([])
  })

  it('getHistory returns [] for an unknown document', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/history/:ds/:type/:id`, () =>
        HttpResponse.json({ revisions: [] }),
      ),
    )
    expect(await createClient(baseConfig).getHistory('post', 'gone')).toEqual([])
  })

  it('getRevision GETs .../revision/:ds/:revId (content); returns null on 404', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/revision/:ds/r1`, () =>
        HttpResponse.json({
          revision: {
            id: 'r1',
            action: 'create',
            title: 'v1',
            timestamp: 't',
            content: { body: 'hi' },
          },
        }),
      ),
      http.get(`${TEST_BASE_URL}/v1/data/revision/:ds/gone`, () =>
        HttpResponse.json(
          { error: { code: 'not_found', message: 'no revision' } },
          { status: 404 },
        ),
      ),
    )
    const bp = createClient(baseConfig)
    const rev = await bp.getRevision('r1')
    expect(rev?.id).toBe('r1')
    expect(rev?.content).toEqual({ body: 'hi' })
    expect(await bp.getRevision('gone')).toBeNull()
  })

  it('restoreRevision POSTs .../restore with {type} and returns {restored, document}', async () => {
    let seenBody: unknown
    let seenMethod = ''
    server.use(
      http.post(`${TEST_BASE_URL}/v1/data/revision/:ds/r1/restore`, async ({ request }) => {
        seenMethod = request.method
        seenBody = await request.json()
        return HttpResponse.json({
          restored: true,
          document: { _id: 'drafts.p1', _type: 'post', _draft: true },
        })
      }),
    )
    const bp = createClient(baseConfig)
    const res = await bp.restoreRevision('r1', 'post')
    expect(res.restored).toBe(true)
    expect(res.document._draft).toBe(true)
    expect(seenMethod).toBe('POST')
    expect(seenBody).toEqual({ type: 'post' })
  })

  it('getHistory throws BarkparkValidationError for an empty type/id (no network call)', async () => {
    const bp = createClient(baseConfig)
    await expect(bp.getHistory('', 'p1')).rejects.toMatchObject({
      code: 'BarkparkValidationError',
      field: 'type',
    })
    await expect(bp.getHistory('post', '')).rejects.toMatchObject({
      code: 'BarkparkValidationError',
      field: 'id',
    })
  })

  it('restoreRevision throws BarkparkValidationError for an empty revId/type (no network call)', async () => {
    const bp = createClient(baseConfig)
    await expect(bp.restoreRevision('', 'post')).rejects.toMatchObject({
      code: 'BarkparkValidationError',
      field: 'revId',
    })
    await expect(bp.restoreRevision('r1', '')).rejects.toMatchObject({
      code: 'BarkparkValidationError',
      field: 'type',
    })
  })
})
