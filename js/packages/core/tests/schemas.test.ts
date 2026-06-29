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
})
