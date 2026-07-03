import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createClient } from '../src/client'
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

describe('schema introspection', () => {
  it('schemas() returns the list from the for-sdk envelope', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/schemas/:ds`, () =>
        HttpResponse.json(
          {
            _schemaVersion: 1,
            datasetSchemaHash: 'h1',
            schemas: [
              { id: 'post', name: 'post', title: 'Post', fields: [{ name: 'title', type: 'string' }] },
              { id: 'author', name: 'author', fields: [] },
            ],
          },
          { status: 200 },
        ),
      ),
    )
    const bp = createClient(baseConfig)
    const schemas = await bp.schemas()
    expect(schemas.map((s) => s.name)).toEqual(['post', 'author'])
    expect(schemas[0]!.fields[0]).toEqual({ name: 'title', type: 'string' })
  })

  it('schemas(opts) rejects when passed an already-aborted signal', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/schemas/:ds`, () =>
        HttpResponse.json({ _schemaVersion: 1, schemas: [] }),
      ),
    )
    const bp = createClient(baseConfig)
    // an already-aborted signal makes the read reject (signal is threaded to fetch)
    const ac = new AbortController()
    ac.abort()
    await expect(bp.schemas({ signal: ac.signal })).rejects.toThrow()
  })

  it('getSchema(name) returns the single schema, or null on 404', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/schemas/:ds/post`, () =>
        HttpResponse.json({ _schemaVersion: 1, schema: { id: 'post', name: 'post', fields: [] } }),
      ),
      http.get(`${TEST_BASE_URL}/v1/schemas/:ds/ghost`, () =>
        HttpResponse.json({ code: 'not_found' }, { status: 404 }),
      ),
    )
    const bp = createClient(baseConfig)
    expect((await bp.getSchema('post'))?.name).toBe('post')
    expect(await bp.getSchema('ghost')).toBeNull()
  })

  it('getSchema fast-fails on a blank name (no network call — would hit the LIST route)', async () => {
    // A blank name would build `/v1/schemas/:ds/` which routes to the list
    // endpoint and returns surprising data; fail closed like deleteSchema.
    const bp = createClient(baseConfig)
    await expect(bp.getSchema('')).rejects.toThrow(/schema name is required/)
    await expect(bp.getSchema('   ')).rejects.toThrow(/schema name is required/)
    await expect(bp.getSchema('')).rejects.toBeInstanceOf(BarkparkValidationError)
  })

  it('upsertSchema POSTs the definition to /v1/schemas/:ds and returns the schema', async () => {
    let seenMethod = ''
    let seenBody: unknown
    server.use(
      http.post(`${TEST_BASE_URL}/v1/schemas/:ds`, async ({ request }) => {
        seenMethod = request.method
        seenBody = await request.json()
        return HttpResponse.json(
          { name: 'review', title: 'Review', fields: [{ name: 'body', type: 'text' }] },
          { status: 201 },
        )
      }),
    )
    const bp = createClient(baseConfig)
    const schema = await bp.upsertSchema({
      name: 'review',
      title: 'Review',
      fields: [{ name: 'body', type: 'text' }],
    })

    expect(seenMethod).toBe('POST')
    // The full definition is sent as the JSON body (no `dataset` in it).
    expect(seenBody).toEqual({
      name: 'review',
      title: 'Review',
      fields: [{ name: 'body', type: 'text' }],
    })
    // The echoed schema is returned directly (no envelope wrapper).
    expect(schema.name).toBe('review')
    expect(schema.fields[0]?.name).toBe('body')
  })

  it('upsertSchema fast-fails on missing name or non-array fields (no network call)', async () => {
    const bp = createClient(baseConfig)
    // no handler registered → any network call would 500 under onUnhandledRequest: 'error'
    await expect(bp.upsertSchema({ fields: [] } as never)).rejects.toThrow(/schema name is required/)
    await expect(bp.upsertSchema({ name: '  ', fields: [] })).rejects.toThrow(/schema name is required/)
    await expect(bp.upsertSchema({ name: 'review' } as never)).rejects.toThrow(/fields must be an array/)
  })

  it('upsertSchema fast-fails on structurally-invalid field entries (no network call)', async () => {
    const bp = createClient(baseConfig)
    // missing name
    await expect(
      bp.upsertSchema({ name: 'review', fields: [{ type: 'string' }] } as never),
    ).rejects.toThrow(/each field requires a non-empty string name and type/)
    // non-object entry (a bare string)
    await expect(
      bp.upsertSchema({ name: 'review', fields: ['title'] } as never),
    ).rejects.toThrow(/each field requires a non-empty string name and type/)
    // missing type
    await expect(
      bp.upsertSchema({ name: 'review', fields: [{ name: 'title' }] } as never),
    ).rejects.toThrow(/each field requires a non-empty string name and type/)
    // it's a BarkparkValidationError, like the sibling guards
    await expect(
      bp.upsertSchema({ name: 'review', fields: [{ type: 'string' }] } as never),
    ).rejects.toBeInstanceOf(BarkparkValidationError)
  })

  it('upsertSchema lets a well-formed field pass the guard', async () => {
    let seenBody: unknown
    server.use(
      http.post(`${TEST_BASE_URL}/v1/schemas/:ds`, async ({ request }) => {
        seenBody = await request.json()
        return HttpResponse.json(
          { name: 'review', fields: [{ name: 'body', type: 'text' }] },
          { status: 201 },
        )
      }),
    )
    const bp = createClient(baseConfig)
    const schema = await bp.upsertSchema({ name: 'review', fields: [{ name: 'body', type: 'text' }] })
    expect(seenBody).toEqual({ name: 'review', fields: [{ name: 'body', type: 'text' }] })
    expect(schema.name).toBe('review')
  })

  it('deleteSchema fast-fails on a blank name (no network call)', async () => {
    const bp = createClient(baseConfig)
    await expect(bp.deleteSchema('')).rejects.toThrow(/schema name is required/)
    await expect(bp.deleteSchema('   ')).rejects.toThrow(/schema name is required/)
  })

  it('deleteSchema DELETEs /v1/schemas/:ds/:name and returns { deleted }', async () => {
    let seenMethod = ''
    server.use(
      http.delete(`${TEST_BASE_URL}/v1/schemas/:ds/review`, ({ request }) => {
        seenMethod = request.method
        return HttpResponse.json({ deleted: 'review' })
      }),
    )
    const bp = createClient(baseConfig)
    const res = await bp.deleteSchema('review')
    expect(seenMethod).toBe('DELETE')
    expect(res.deleted).toBe('review')
  })
})
