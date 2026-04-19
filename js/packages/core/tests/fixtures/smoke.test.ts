import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest'
import { server } from './server'
import {
  TEST_BASE_URL,
  TEST_DATASET,
  TEST_API_VERSION,
  TEST_SCHEMA_HASH,
  resetFixtures,
} from './handlers'

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('MSW handlers smoke', () => {
  it('GET /v1/meta?dataset=production returns scalar schemaHash', async () => {
    const res = await fetch(`${TEST_BASE_URL}/v1/meta?dataset=${TEST_DATASET}`)
    expect(res.status).toBe(200)
    const body = (await res.json()) as Record<string, unknown>
    expect(body.maxApiVersion).toBe(TEST_API_VERSION)
    expect(body.currentDatasetSchemaHash).toBe(TEST_SCHEMA_HASH)
  })

  it('GET /v1/meta (no dataset) returns schemaHash map', async () => {
    const res = await fetch(`${TEST_BASE_URL}/v1/meta`)
    expect(res.status).toBe(200)
    const body = (await res.json()) as { currentDatasetSchemaHash: Record<string, string> }
    expect(body.currentDatasetSchemaHash[TEST_DATASET]).toBe(TEST_SCHEMA_HASH)
  })

  it('GET /v1/meta?dataset=unknown returns 404 error envelope', async () => {
    const res = await fetch(`${TEST_BASE_URL}/v1/meta?dataset=nope`)
    expect(res.status).toBe(404)
    const body = (await res.json()) as { error: { code: string; request_id: string } }
    expect(body.error.code).toBe('not_found')
    expect(body.error.request_id).toBeTruthy()
  })

  it('GET /v1/data/query/:dataset/post?perspective=drafts returns draft only (flat envelope)', async () => {
    const res = await fetch(
      `${TEST_BASE_URL}/v1/data/query/${TEST_DATASET}/post?perspective=drafts`,
    )
    expect(res.status).toBe(200)
    const body = (await res.json()) as {
      perspective: string
      documents: Array<{ _draft: boolean }>
      count: number
      limit: number
      offset: number
    }
    expect(body.perspective).toBe('drafts')
    expect(body.documents).toHaveLength(1)
    expect(body.documents[0]!._draft).toBe(true)
    expect(res.headers.get('etag')).toMatch(/^"[a-f0-9]+"$/)
    // schemaHash lives on /v1/meta per the Phoenix flat envelope — not on query response.
    expect(TEST_SCHEMA_HASH).toMatch(/^[a-f0-9]+$/)
  })

  it('GET /v1/data/doc returns 200 for existing doc and 404 for missing (flat shape)', async () => {
    const ok = await fetch(`${TEST_BASE_URL}/v1/data/doc/${TEST_DATASET}/post/p1`)
    expect(ok.status).toBe(200)
    const okBody = (await ok.json()) as { _id: string; _rev: string }
    expect(okBody._id).toBe('p1')
    expect(ok.headers.get('etag')).toBe(`"${okBody._rev}"`)

    const miss = await fetch(`${TEST_BASE_URL}/v1/data/doc/${TEST_DATASET}/post/zzz`)
    expect(miss.status).toBe(404)
    const missBody = (await miss.json()) as { error: { code: string } }
    expect(missBody.error.code).toBe('not_found')
  })

  it('POST /v1/data/mutate requires Bearer and returns MutateEnvelope on create', async () => {
    const missingAuth = await fetch(`${TEST_BASE_URL}/v1/data/mutate/${TEST_DATASET}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ mutations: [] }),
    })
    expect(missingAuth.status).toBe(401)

    const ok = await fetch(`${TEST_BASE_URL}/v1/data/mutate/${TEST_DATASET}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: 'Bearer test-token' },
      body: JSON.stringify({ mutations: [{ create: { _type: 'post', title: 'Mut test' } }] }),
    })
    expect(ok.status).toBe(200)
    const body = (await ok.json()) as {
      transactionId: string
      results: Array<{ id: string; operation: string; document: { _type: string } }>
    }
    expect(body.transactionId).toMatch(/^[a-f0-9]{32}$/)
    expect(body.results).toHaveLength(1)
    expect(body.results[0]!.operation).toBe('create')
    expect(body.results[0]!.document._type).toBe('post')
  })

  it('GET /v1/data/listen streams welcome + mutation SSE frames', async () => {
    const res = await fetch(`${TEST_BASE_URL}/v1/data/listen/${TEST_DATASET}`, {
      headers: { authorization: 'Bearer test-token' },
    })
    expect(res.status).toBe(200)
    expect(res.headers.get('content-type')).toContain('text/event-stream')
    const text = await res.text()
    expect(text).toContain('event: welcome')
    expect(text).toContain('event: mutation')
    expect(text).toContain('id: 1')
    expect(text).toContain(': keepalive')
  })
})
