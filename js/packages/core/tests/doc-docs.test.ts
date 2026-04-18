import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import {
  TEST_BASE_URL,
  TEST_DATASET,
  errorResponse,
  resetFixtures,
} from './fixtures/handlers'
import { getDoc } from '../src/doc'
import { createDocsOperation } from '../src/docs'
import {
  BarkparkAPIError,
  BarkparkAuthError,
} from '../src/errors'
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

describe('getDoc', () => {
  it('returns doc + unquoted etag on 200', async () => {
    const res = await getDoc(baseConfig, 'post', 'p1')
    expect(res.data).toMatchObject({ _id: 'p1', _type: 'post', title: 'Hello World' })
    expect(res.etag).toBe('1111111111111111111111111111aaaa')
  })

  it('returns { data: null } on 404 without throwing', async () => {
    const res = await getDoc(baseConfig, 'post', 'nonexistent')
    expect(res.data).toBeNull()
    expect(res.etag).toBeUndefined()
  })

  it('propagates non-404 errors', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, () => HttpResponse.json({}, { status: 200 })),
      http.get(`${TEST_BASE_URL}/v1/data/doc/:ds/:type/:id`, () =>
        errorResponse({ status: 401, code: 'unauthorized', message: 'bad token' }),
      ),
    )
    await expect(getDoc(baseConfig, 'post', 'p1')).rejects.toBeInstanceOf(BarkparkAuthError)
  })

  it('sends perspective query param when opts.perspective is set', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/doc/:ds/:type/:id`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json(
          {
            result: {
              _id: 'p1',
              _type: 'post',
              _rev: '1111111111111111111111111111aaaa',
              _draft: false,
              _publishedId: 'p1',
              _createdAt: 'x',
              _updatedAt: 'x',
            },
            syncTags: [],
            ms: 1,
            etag: '1111111111111111111111111111aaaa',
            schemaHash: 'abc1234567890def',
          },
          { status: 200, headers: { ETag: `"x"` } },
        )
      }),
    )
    await getDoc(baseConfig, 'post', 'p1', { perspective: 'drafts' })
    expect(seenUrl).toContain('perspective=drafts')
  })
})

describe('createDocsOperation', () => {
  it('returns documents array from ReadEnvelope.result.documents', async () => {
    const docs = await createDocsOperation(baseConfig, 'post').find()
    expect(Array.isArray(docs)).toBe(true)
    expect(docs.length).toBeGreaterThanOrEqual(1)
    expect(docs[0]).toMatchObject({ _type: 'post' })
  })

  it('builds URL with filters, order, limit, offset, and perspective', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json(
          {
            result: { perspective: 'published', documents: [], count: 0, limit: 10, offset: 0 },
            syncTags: [],
            ms: 1,
            etag: 'deadbeefcafebabef00dfaceabcdef01',
            schemaHash: 'abc1234567890def',
          },
          { status: 200 },
        )
      }),
    )
    await createDocsOperation(baseConfig, 'post', { perspective: 'drafts' })
      .where('title', 'eq', 'Hello')
      .order('_updatedAt:desc')
      .limit(10)
      .offset(5)
      .find()
    const url = new URL(seenUrl)
    expect(url.pathname).toBe(`/v1/data/query/${TEST_DATASET}/post`)
    expect(url.searchParams.get('filter[title][eq]')).toBe('Hello')
    expect(url.searchParams.get('order')).toBe('_updatedAt:desc')
    expect(url.searchParams.get('limit')).toBe('10')
    expect(url.searchParams.get('offset')).toBe('5')
    expect(url.searchParams.get('perspective')).toBe('drafts')
  })

  it('falls back to config.perspective when opts.perspective is unset', async () => {
    const cfg: BarkparkClientConfig = { ...baseConfig, perspective: 'drafts' }
    const docs = await createDocsOperation(cfg, 'post').find()
    // drafts perspective → fixture includes drafts.p2; published-only default would exclude it.
    expect(docs.some((d) => (d as { _id: string })._id === 'drafts.p2')).toBe(true)
  })
})
