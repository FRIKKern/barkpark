// Regression tests for Phoenix flat-envelope SDK contract (defects #16 + #18).
//
// These tests use *exact* byte-level fixtures captured from the live Phoenix API
// (GET http://89.167.28.206:4000/v1/data/query/production/post and /v1/data/doc/...)
// to guarantee the SDK keeps reading the shipped shape. If Phoenix ever wraps
// responses in a `result` key again, these tests will fail first.

import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET } from './fixtures/handlers'
import { getDoc } from '../src/doc'
import { createDocsOperation } from '../src/docs'
import type { BarkparkClientConfig } from '../src/types'

const config: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
}

// Captured live response (anonymized rev, same shape as prod 2026-04-19).
const LIVE_QUERY_BODY = {
  count: 2,
  offset: 0,
  limit: 100,
  documents: [
    {
      _createdAt: '2026-04-12T13:12:01.833245Z',
      _draft: false,
      _id: 'p2',
      _publishedId: 'p2',
      _rev: '37147d15143be9ba6a4e80179db49670',
      _type: 'post',
      _updatedAt: '2026-04-19T09:32:53.014598Z',
      featured: 'false',
      title: 'Why Headless CMS Changes Everything',
    },
    {
      _createdAt: '2026-04-12T13:12:01.830404Z',
      _draft: false,
      _id: 'p1',
      _publishedId: 'p1',
      _rev: '1d659f3c933ec5651d92f329baac4f46',
      _type: 'post',
      _updatedAt: '2026-04-17T23:22:28.238870Z',
      author: 'spike-c',
      title: 'FINAL-RT3-1776468148217232321',
    },
  ],
  perspective: 'published',
}

const LIVE_DOC_BODY = {
  _createdAt: '2026-04-12T13:12:01.830404Z',
  _draft: false,
  _id: 'p1',
  _publishedId: 'p1',
  _rev: '1d659f3c933ec5651d92f329baac4f46',
  _type: 'post',
  _updatedAt: '2026-04-17T23:22:28.238870Z',
  author: 'spike-c',
  title: 'FINAL-RT3-1776468148217232321',
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => server.resetHandlers())
afterAll(() => server.close())

describe('Phoenix flat envelope contract', () => {
  it('query() unwraps data.documents from the flat envelope (defect #16)', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, () =>
        HttpResponse.json(LIVE_QUERY_BODY, { status: 200 }),
      ),
    )

    const docs = await createDocsOperation(config, 'post').find()
    expect(Array.isArray(docs)).toBe(true)
    expect(docs).toHaveLength(2)
    expect(docs[0]).toMatchObject({ _id: 'p2', _type: 'post' })
    expect(docs[1]).toMatchObject({ _id: 'p1', _type: 'post' })
  })

  it('surfaces the envelope `hint` on the thrown error (CLI/API/SDK parity)', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, () =>
        HttpResponse.json(
          { error: { code: 'unauthorized', message: 'token required', hint: 'set BARKPARK_API_TOKEN' } },
          { status: 401 },
        ),
      ),
    )
    await expect(createDocsOperation(config, 'post').find()).rejects.toMatchObject({
      code: 'BarkparkAuthError',
      hint: 'set BARKPARK_API_TOKEN',
    })
  })

  it('query() does NOT try to read data.result.documents (would throw TypeError)', async () => {
    // If the SDK regresses to data.result.documents, Phoenix's flat body has no `result`
    // key — the SDK would throw `Cannot read properties of undefined (reading 'documents')`.
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, () =>
        HttpResponse.json(LIVE_QUERY_BODY, { status: 200 }),
      ),
    )
    await expect(createDocsOperation(config, 'post').find()).resolves.toBeDefined()
  })

  it('query() returns [] when Phoenix sends documents:[]', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, () =>
        HttpResponse.json(
          { count: 0, offset: 0, limit: 100, documents: [], perspective: 'published' },
          { status: 200 },
        ),
      ),
    )
    const docs = await createDocsOperation(config, 'post').find()
    expect(docs).toEqual([])
  })

  it('doc() returns the document body directly (defect #18)', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/doc/:ds/:type/:id`, () =>
        HttpResponse.json(LIVE_DOC_BODY, {
          status: 200,
          headers: { ETag: `"${LIVE_DOC_BODY._rev}"` },
        }),
      ),
    )

    const res = await getDoc(config, 'post', 'p1')
    expect(res.data).not.toBeNull()
    expect(res.data).toMatchObject({
      _id: 'p1',
      _type: 'post',
      title: 'FINAL-RT3-1776468148217232321',
      author: 'spike-c',
    })
    expect(res.etag).toBe('1d659f3c933ec5651d92f329baac4f46')
  })

  it('doc() does NOT read data.result (would silently return undefined on the live shape)', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/doc/:ds/:type/:id`, () =>
        HttpResponse.json(LIVE_DOC_BODY, { status: 200 }),
      ),
    )
    const res = await getDoc(config, 'post', 'p1')
    // Regression guard: if SDK reads data.result, res.data would be undefined here.
    expect(res.data).toBeDefined()
    expect(res.data).not.toBeUndefined()
  })

  // Some admin/legacy endpoints answer with a BARE STRING error body —
  // {"error":"not_found"} rather than the canonical {"error":{"code":…}}. The bp
  // CLI's classifyError already decodes this; the SDK must reach parity, else a
  // string `error` was cast to {} and the caller lost the machine code AND the
  // message (which degraded to a bare `HTTP <status>`).
  it('decodes a bare-string `error` into serverCode + message (CLI parity)', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, () =>
        HttpResponse.json({ error: 'not_found' }, { status: 404 }),
      ),
    )
    await expect(createDocsOperation(config, 'post').find()).rejects.toMatchObject({
      serverCode: 'not_found',
      message: 'not_found',
    })
  })

  it('uses a sibling `reason` as the message for a bare-string `error`', async () => {
    // The pre-canonical veto shape {"error":"halted","reason":…} — the reason
    // carries the human message; the CLI's vetoMessage does the same.
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, () =>
        HttpResponse.json({ error: 'halted', reason: 'tenant is over quota' }, { status: 409 }),
      ),
    )
    await expect(createDocsOperation(config, 'post').find()).rejects.toMatchObject({
      serverCode: 'halted',
      message: 'tenant is over quota',
    })
  })

  // Regressions for wbt-jwt-sdk-error-details-reason: transport.ts parsed the
  // canonical envelope's `details` object (api/lib/barkpark/content/errors.ex
  // `build/1`) but only attached it to the 429/412/422 branches' thrown error —
  // the 401/403/409/404 branches dropped it on the floor, and the envelope's
  // top-level `reason` sub-code (sibling of `code`/`message`, e.g.
  // `forbidden_membership`'s `reason: "not_a_member"`) was never read on the
  // canonical object-envelope path at all. These RED without the `base` fix in
  // transport.ts that spreads `details` + `reason` into every thrown error.

  it('surfaces details.similar on a 409 duplicate_task (find-or-create gate)', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, () =>
        HttpResponse.json(
          {
            error: {
              code: 'duplicate_task',
              message: 'task duplicates an existing task',
              details: { similar: [{ id: 'task-1', title: 'Existing task' }], advise: 'claim task-1' },
            },
          },
          { status: 409 },
        ),
      ),
    )
    await expect(createDocsOperation(config, 'post').find()).rejects.toMatchObject({
      code: 'BarkparkConflictError',
      serverCode: 'duplicate_task',
      details: { similar: [{ id: 'task-1', title: 'Existing task' }], advise: 'claim task-1' },
    })
  })

  it('surfaces details.count on a 409 schema_has_documents', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, () =>
        HttpResponse.json(
          {
            error: {
              code: 'schema_has_documents',
              message: 'schema still has 3 document(s) of this type',
              details: { count: 3 },
            },
          },
          { status: 409 },
        ),
      ),
    )
    await expect(createDocsOperation(config, 'post').find()).rejects.toMatchObject({
      code: 'BarkparkConflictError',
      serverCode: 'schema_has_documents',
      details: { count: 3 },
    })
  })

  it('surfaces err.reason === "not_a_member" on a 403 forbidden_membership', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, () =>
        HttpResponse.json(
          {
            error: {
              code: 'forbidden',
              message: 'caller is not a member of this workspace',
              reason: 'not_a_member',
            },
          },
          { status: 403 },
        ),
      ),
    )
    await expect(createDocsOperation(config, 'post').find()).rejects.toMatchObject({
      code: 'BarkparkAuthError',
      serverCode: 'forbidden',
      reason: 'not_a_member',
    })
  })

  it('preserves details on a 404 not_found envelope', async () => {
    // Use the query path (not getDoc, which swallows a 404 into `{ data: null }`
    // by design — see doc.ts) so the error actually reaches the caller.
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/:ds/:type`, () =>
        HttpResponse.json(
          {
            error: {
              code: 'not_found',
              message: 'document not found',
              details: { searched: 'post/p1' },
            },
          },
          { status: 404 },
        ),
      ),
    )
    await expect(createDocsOperation(config, 'post').find()).rejects.toMatchObject({
      code: 'BarkparkNotFoundError',
      serverCode: 'not_found',
      details: { searched: 'post/p1' },
    })
  })
})
