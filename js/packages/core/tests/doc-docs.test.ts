import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, errorResponse, resetFixtures } from './fixtures/handlers'
import { getDoc } from '../src/doc'
import { createDocsOperation } from '../src/docs'
import { createClient } from '../src/client'
import { fetchRawDoc } from '../src/fetchRaw'
import { BarkparkAuthError } from '../src/errors'
import type { BarkparkClientConfig } from '../src/types'
// Imported from the PUBLIC entry (../src/index): these type the EXPORTED getDoc
// (GetDocOptions opts / DocResult return) and createDocsOperation
// (DocsOperationOptions opts). Un-export any from index.ts → this import fails → tsc
// errors. Protective export-completeness guard.
import type { GetDocOptions, DocResult, DocsOperationOptions } from '../src/index'

const _getDocOpts: GetDocOptions = { perspective: 'drafts', expand: 'author', fields: ['title'] }
const _docResult: DocResult<{ _id: string }> = { data: { _id: 'p1' }, etag: 'rev-1' }
const _docsOpts: DocsOperationOptions = { perspective: 'published' }
void _getDocOpts
void _docResult
void _docsOpts

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
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, () =>
        HttpResponse.json({}, { status: 200 }),
      ),
      http.get(`${TEST_BASE_URL}/v1/data/doc/:ds/:type/:id`, () =>
        errorResponse({ status: 401, code: 'unauthorized', message: 'bad token' }),
      ),
    )
    await expect(getDoc(baseConfig, 'post', 'p1')).rejects.toBeInstanceOf(BarkparkAuthError)
  })

  it('maps a 403 forbidden to BarkparkAuthError (documented 401/403 class)', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, () =>
        HttpResponse.json({}, { status: 200 }),
      ),
      http.get(`${TEST_BASE_URL}/v1/data/doc/:ds/:type/:id`, () =>
        errorResponse({ status: 403, code: 'forbidden', message: 'token lacks permission' }),
      ),
    )
    // Was a generic BarkparkAPIError before — the auth class advertised 403 but
    // the transport never threw it.
    await expect(getDoc(baseConfig, 'post', 'p1')).rejects.toBeInstanceOf(BarkparkAuthError)
  })

  it('carries the server code as `serverCode` (distinct from `code` = class name)', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, () =>
        HttpResponse.json({}, { status: 200 }),
      ),
      http.get(`${TEST_BASE_URL}/v1/data/doc/:ds/:type/:id`, () =>
        errorResponse({ status: 401, code: 'mfa_required', message: 'a TOTP code is required' }),
      ),
    )
    // Two BarkparkAuthErrors (mfa_required vs invalid_credentials) are only
    // distinguishable via serverCode — `code` stays the class name.
    await getDoc(baseConfig, 'post', 'p1').then(
      () => expect.fail('expected throw'),
      (err) => {
        expect(err).toBeInstanceOf(BarkparkAuthError)
        expect(err.serverCode).toBe('mfa_required')
        expect(err.code).toBe('BarkparkAuthError')
      },
    )
  })

  it('sends perspective query param when opts.perspective is set', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/doc/:ds/:type/:id`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json(
          {
            _id: 'p1',
            _type: 'post',
            _rev: '1111111111111111111111111111aaaa',
            _draft: false,
            _publishedId: 'p1',
            _createdAt: 'x',
            _updatedAt: 'x',
          },
          { status: 200, headers: { ETag: `"x"` } },
        )
      }),
    )
    await getDoc(baseConfig, 'post', 'p1', { perspective: 'drafts' })
    expect(seenUrl).toContain('perspective=drafts')
  })

  it('sends expand query param (single + array) alongside perspective', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/doc/:ds/:type/:id`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json(
          {
            _id: 'p1',
            _type: 'post',
            _rev: '1111111111111111111111111111aaaa',
            _draft: false,
            _publishedId: 'p1',
            _createdAt: 'x',
            _updatedAt: 'x',
          },
          { status: 200, headers: { ETag: `"x"` } },
        )
      }),
    )
    await getDoc(baseConfig, 'post', 'p1', { expand: 'author' })
    expect(seenUrl).toContain('expand=author')

    await getDoc(baseConfig, 'post', 'p1', { perspective: 'drafts', expand: ['author', 'tags'] })
    expect(seenUrl).toContain('perspective=drafts')
    expect(decodeURIComponent(seenUrl)).toContain('expand=author,tags')
  })

  it('sends fields query param (single-doc projection, single + array)', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/doc/:ds/:type/:id`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json(
          {
            _id: 'p1',
            _type: 'post',
            _rev: '1111111111111111111111111111aaaa',
            _draft: false,
            _publishedId: 'p1',
            _createdAt: 'x',
            _updatedAt: 'x',
          },
          { status: 200, headers: { ETag: `"x"` } },
        )
      }),
    )
    await getDoc(baseConfig, 'post', 'p1', { fields: 'title' })
    expect(seenUrl).toContain('fields=title')

    await getDoc(baseConfig, 'post', 'p1', { fields: ['title', 'slug'] })
    expect(decodeURIComponent(seenUrl)).toContain('fields=title,slug')
  })
})

describe('createDocsOperation', () => {
  it('returns documents array from flat query envelope (data.documents)', async () => {
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
          { perspective: 'published', documents: [], count: 0, limit: 10, offset: 0 },
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

  it('client.docs(type, opts) forwards perspective and threads an abort signal', async () => {
    let seenPerspective: string | null = null
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, ({ request }) => {
        seenPerspective = new URL(request.url).searchParams.get('perspective')
        return HttpResponse.json({ result: { documents: [], count: 0 } })
      }),
    )
    const bp = createClient(baseConfig)
    // per-query perspective override reaches the wire
    await bp.docs('post', { perspective: 'drafts' }).find()
    expect(seenPerspective).toBe('drafts')

    // an already-aborted signal makes the query reject (signal is threaded to fetch)
    const ac = new AbortController()
    ac.abort()
    await expect(bp.docs('post', { signal: ac.signal }).find()).rejects.toThrow()
  })

  it('count() requests ?count=true with the same filters and returns result.total', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json(
          { result: { perspective: 'published', documents: [], count: 1, total: 42 } },
          { status: 200 },
        )
      }),
    )
    const total = await createDocsOperation(baseConfig, 'post').eq('status', 'published').count()
    expect(total).toBe(42)
    const url = new URL(seenUrl)
    expect(url.searchParams.get('count')).toBe('true')
    expect(url.searchParams.get('filter[status][eq]')).toBe('published')
    expect(url.searchParams.get('limit')).toBe('1') // minimal page; total ignores it
  })

  it('findPage() returns the page + total in one ?count=true request (caller limit kept)', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json(
          {
            result: {
              perspective: 'published',
              documents: [{ _id: 'p1', _type: 'post' }],
              count: 1,
              limit: 20,
              offset: 0,
              total: 42,
            },
          },
          { status: 200 },
        )
      }),
    )
    const page = await createDocsOperation(baseConfig, 'post')
      .eq('status', 'published')
      .limit(20)
      .findPage()
    expect(page.total).toBe(42)
    expect(page.documents).toHaveLength(1)
    expect(page.limit).toBe(20)
    const url = new URL(seenUrl)
    expect(url.searchParams.get('count')).toBe('true')
    expect(url.searchParams.get('limit')).toBe('20') // caller's page size, not minimal
  })
})

describe('scoped read paths (workspace + project)', () => {
  const scopedConfig: BarkparkClientConfig = {
    ...baseConfig,
    workspace: 'acme',
    project: 'blog',
  }
  const PREFIX = '/w/acme/p/blog'

  it('getDoc prepends /w/<ws>/p/<project> to the doc path when both set', async () => {
    let seenPath = ''
    server.use(
      http.get(`${TEST_BASE_URL}${PREFIX}/v1/data/doc/:ds/:type/:id`, ({ request }) => {
        seenPath = new URL(request.url).pathname
        return HttpResponse.json(
          {
            _id: 'p1',
            _type: 'post',
            _rev: '1111111111111111111111111111aaaa',
            _draft: false,
            _publishedId: 'p1',
            _createdAt: 'x',
            _updatedAt: 'x',
          },
          { status: 200, headers: { ETag: `"x"` } },
        )
      }),
    )
    await getDoc(scopedConfig, 'post', 'p1')
    expect(seenPath).toBe(`${PREFIX}/v1/data/doc/${TEST_DATASET}/post/p1`)
  })

  it('getDoc stays flat /v1/... when workspace/project absent (back-compat)', async () => {
    let seenPath = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/doc/:ds/:type/:id`, ({ request }) => {
        seenPath = new URL(request.url).pathname
        return HttpResponse.json(
          {
            _id: 'p1',
            _type: 'post',
            _rev: '1111111111111111111111111111aaaa',
            _draft: false,
            _publishedId: 'p1',
            _createdAt: 'x',
            _updatedAt: 'x',
          },
          { status: 200, headers: { ETag: `"x"` } },
        )
      }),
    )
    await getDoc(baseConfig, 'post', 'p1')
    expect(seenPath).toBe(`/v1/data/doc/${TEST_DATASET}/post/p1`)
  })

  it('createDocsOperation prepends the scope prefix to the query path', async () => {
    let seenPath = ''
    server.use(
      http.get(`${TEST_BASE_URL}${PREFIX}/v1/data/query/:ds/:type`, ({ request }) => {
        seenPath = new URL(request.url).pathname
        return HttpResponse.json(
          { perspective: 'published', documents: [], count: 0, limit: 10, offset: 0 },
          { status: 200 },
        )
      }),
    )
    await createDocsOperation(scopedConfig, 'post').find()
    expect(seenPath).toBe(`${PREFIX}/v1/data/query/${TEST_DATASET}/post`)
  })

  it('createDocsOperation stays flat /v1/... when scope absent (back-compat)', async () => {
    let seenPath = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, ({ request }) => {
        seenPath = new URL(request.url).pathname
        return HttpResponse.json(
          { perspective: 'published', documents: [], count: 0, limit: 10, offset: 0 },
          { status: 200 },
        )
      }),
    )
    await createDocsOperation(baseConfig, 'post').find()
    expect(seenPath).toBe(`/v1/data/query/${TEST_DATASET}/post`)
  })

  it('fetchRawDoc prepends the scope prefix to the caller path', async () => {
    let seenPath = ''
    server.use(
      http.get(`${TEST_BASE_URL}${PREFIX}/v1/data/doc/:ds/:type/:id`, ({ request }) => {
        seenPath = new URL(request.url).pathname
        return HttpResponse.json({}, { status: 200 })
      }),
    )
    await fetchRawDoc(scopedConfig, `/v1/data/doc/${TEST_DATASET}/post/p1`)
    expect(seenPath).toBe(`${PREFIX}/v1/data/doc/${TEST_DATASET}/post/p1`)
  })

  it('fetchRawDoc does not double-prefix an already-scoped path', async () => {
    let seenPath = ''
    server.use(
      http.get(`${TEST_BASE_URL}${PREFIX}/v1/data/doc/:ds/:type/:id`, ({ request }) => {
        seenPath = new URL(request.url).pathname
        return HttpResponse.json({}, { status: 200 })
      }),
    )
    await fetchRawDoc(scopedConfig, `${PREFIX}/v1/data/doc/${TEST_DATASET}/post/p1`)
    expect(seenPath).toBe(`${PREFIX}/v1/data/doc/${TEST_DATASET}/post/p1`)
  })

  it('fetchRawDoc stays flat when scope absent (back-compat)', async () => {
    let seenPath = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/doc/:ds/:type/:id`, ({ request }) => {
        seenPath = new URL(request.url).pathname
        return HttpResponse.json({}, { status: 200 })
      }),
    )
    await fetchRawDoc(baseConfig, `/v1/data/doc/${TEST_DATASET}/post/p1`)
    expect(seenPath).toBe(`/v1/data/doc/${TEST_DATASET}/post/p1`)
  })
})

describe('getDocuments', () => {
  it('returns docs in input order with null for missing ids', async () => {
    let seenInParam: string | null = null
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, ({ request }) => {
        seenInParam = new URL(request.url).searchParams.get('filter[_id][in]')
        // server returns out of input order, and omits the missing id
        return HttpResponse.json({
          result: {
            documents: [
              { _id: 'c', _type: 'post', title: 'C' },
              { _id: 'a', _type: 'post', title: 'A' },
            ],
            count: 2,
          },
        })
      }),
    )
    const bp = createClient(baseConfig)
    const docs = await bp.getDocuments('post', ['a', 'missing', 'c'])
    // re-ordered to the input, null-padded for the missing id
    expect(docs.map((d) => (d as { _id?: string } | null)?._id ?? null)).toEqual(['a', null, 'c'])
    // fetched by the id-list filter
    expect(seenInParam).toBe('a,missing,c')
  })

  it('returns [] for an empty id list without a request', async () => {
    let called = false
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, () => {
        called = true
        return HttpResponse.json({ result: { documents: [], count: 0 } })
      }),
    )
    const bp = createClient(baseConfig)
    expect(await bp.getDocuments('post', [])).toEqual([])
    expect(called).toBe(false)
  })

  it('forwards expand and fields to the underlying query', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ result: { documents: [], count: 0 } })
      }),
    )
    const bp = createClient(baseConfig)
    await bp.getDocuments('post', ['a', 'b'], { expand: 'author', fields: ['title', 'slug'] })
    const url = new URL(seenUrl)
    expect(url.searchParams.get('expand')).toBe('author')
    expect(url.searchParams.get('fields')).toBe('title,slug')
    expect(url.searchParams.get('filter[_id][in]')).toBe('a,b')
  })

  it('forwards a per-call perspective override to the underlying query', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ result: { documents: [], count: 0 } })
      }),
    )
    const bp = createClient(baseConfig)
    await bp.getDocuments('post', ['a', 'b'], { perspective: 'drafts' })
    const url = new URL(seenUrl)
    expect(url.searchParams.get('perspective')).toBe('drafts')
    expect(url.searchParams.get('filter[_id][in]')).toBe('a,b')
  })

  it('threads an abort signal (cancellable batch fetch)', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, () =>
        HttpResponse.json({ result: { documents: [], count: 0 } }),
      ),
    )
    const bp = createClient(baseConfig)
    const ac = new AbortController()
    ac.abort()
    await expect(bp.getDocuments('post', ['a'], { signal: ac.signal })).rejects.toThrow()
  })
})
