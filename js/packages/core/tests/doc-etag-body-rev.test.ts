// `DocResult.etag` is the document's `_rev` (the WRITE PRECONDITION), never the
// HTTP `ETag` response header (a CACHE VALIDATOR). task-288e6ccee42289bd.
//
// ## The defect these pin
//
// `getDoc` used to read `response.headers.get('ETag')`. On main the header and
// the body's rev happened to be the same string, so the documented contract
// ("Unquoted ETag ( = document _rev). Pass back as ifMatch on writes") held BY
// COINCIDENCE. PR #15786 makes the header a cache validator that additionally
// folds the dataset schema hash — it has to, because `Envelope.render/3` picks
// the visible field set out of the SCHEMA and a schema edit moves no `_rev`,
// which is how an anonymous 304 kept serving a newly-private field. The moment
// that lands, every documented read-then-write round-trip sends the folded
// validator as `ifMatch` and gets `rev_mismatch` (412).
//
// So every fake server below emits a header that DIFFERS from the body rev —
// the shape #15786 ships (`cache_validator/2` = sha256("<rev>|<schema_hash>")
// truncated to 32 lowercase hex chars). Under the old header read these tests
// return the validator and fail; under the body read they return the rev.
//
// ## Mutation proof
//
// Restore `const etag = stripEtagQuotes(response.headers.get('ETag'))` in
// `getDoc` and all four `DocResult.etag` assertions red with the validator.
//
// Non-vacuity control: every test asserts the header and the body rev are
// actually different strings first, so a fixture that accidentally emits the
// old identity cannot pass by luck.

import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { getDoc } from '../src/doc'
import type { BarkparkClientConfig } from '../src/types'

const config: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
}

// The document rev — what `ifMatch` must carry.
const DOC_REV = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaa1111'

// The folded cache validator #15786 puts in the ETag header: a 32-char lowercase
// hex digest of `"<etag>|<schema_hash>"`. Deliberately a DIFFERENT string.
const CACHE_VALIDATOR = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbb2222'

const DOC = {
  _id: 'p1',
  _type: 'post',
  _rev: DOC_REV,
  _draft: false,
  _publishedId: 'p1',
  title: 'Hello World',
}

// The filtered (default) envelope: `etag` is the bare `_rev`, `schemaHash` is
// the very input the header folds in — the two tokens ride the same response.
const ENVELOPE = {
  result: DOC,
  syncTags: [`bp:ds:${TEST_DATASET}:doc:p1`],
  ms: 3,
  etag: DOC_REV,
  schemaHash: 'cccccccccccccccccccccccccccc3333',
}

function docHandler(body: Record<string, unknown>) {
  return http.get(`${TEST_BASE_URL}/v1/data/doc/:ds/:type/:id`, () =>
    HttpResponse.json(body, {
      status: 200,
      headers: { ETag: `"${CACHE_VALIDATOR}"`, 'x-request-id': 'req_doc_split' },
    }),
  )
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('DocResult.etag is the body rev, not the ETag header', () => {
  it('non-vacuity: the fixture header and the document rev are different strings', () => {
    expect(CACHE_VALIDATOR).not.toBe(DOC_REV)
    expect(ENVELOPE.etag).toBe(DOC_REV)
  })

  it('filtered envelope shape: etag is the envelope `etag` (= _rev), not the folded header', async () => {
    server.use(docHandler(ENVELOPE))

    const res = await getDoc(config, 'post', 'p1')

    expect(res.data).toMatchObject({ _id: 'p1', _rev: DOC_REV })
    expect(res.etag).toBe(DOC_REV)
    expect(res.etag).not.toBe(CACHE_VALIDATOR)
  })

  it('flat shape: etag is the document `_rev`, not the folded header', async () => {
    server.use(docHandler(DOC))

    const res = await getDoc(config, 'post', 'p1')

    expect(res.data).toMatchObject({ _id: 'p1', _rev: DOC_REV })
    expect(res.etag).toBe(DOC_REV)
    expect(res.etag).not.toBe(CACHE_VALIDATOR)
  })

  it('the documented read-then-write round-trip survives the split header', async () => {
    // The exact snippet the DocResult.etag docstring promises. The fake mutate
    // endpoint enforces the server rule (`Content.Mutations.if_rev/1`): an
    // `ifMatch` that is not the stored rev is a 412. Reading the header instead
    // of the body makes THIS call fail, which is the user-visible consequence.
    let seenIfMatch: string | undefined
    server.use(
      docHandler(ENVELOPE),
      http.post(`${TEST_BASE_URL}/v1/data/mutate/:ds`, async ({ request }) => {
        const body = (await request.json()) as {
          mutations: Array<{ patch: { ifMatch?: string } }>
        }
        seenIfMatch = body.mutations[0]!.patch.ifMatch
        if (seenIfMatch !== DOC_REV) {
          return HttpResponse.json(
            {
              error: {
                code: 'precondition_failed',
                message: 'rev_mismatch',
                details: { expected: seenIfMatch, actual: DOC_REV },
                request_id: 'req_mut_412',
              },
            },
            { status: 412, headers: { 'x-request-id': 'req_mut_412' } },
          )
        }
        return HttpResponse.json(
          { transactionId: 'tx_1', results: [{ id: 'p1', operation: 'update' }] },
          { status: 200, headers: { 'x-request-id': 'req_mut_ok' } },
        )
      }),
    )

    const { etag } = await getDoc(config, 'post', 'p1')

    const { createPatch } = await import('../src/patch')
    await expect(
      createPatch({ ...config, token: 'test-token' }, 'p1', 'post')
        .set({ title: 'v2' })
        .commit(etag !== undefined ? { ifMatch: etag } : undefined),
    ).resolves.toBeDefined()

    expect(seenIfMatch).toBe(DOC_REV)
  })

  it('envelope without an `etag` field degrades to the document `_rev`, still not the header', async () => {
    const { etag: _dropped, ...partial } = ENVELOPE
    void _dropped
    server.use(docHandler(partial))

    const res = await getDoc(config, 'post', 'p1')

    expect(res.etag).toBe(DOC_REV)
    expect(res.etag).not.toBe(CACHE_VALIDATOR)
  })
})
