import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import {
  TEST_API_VERSION,
  TEST_BASE_URL,
  TEST_DATASET,
  TEST_TX_ID,
  resetFixtures,
} from './fixtures/handlers'
import { createPatch } from '../src/patch'
import { BarkparkValidationError } from '../src/errors'
import type {
  ApiVersion,
  BarkparkClientConfig,
  BarkparkDocument,
  MutateEnvelope,
} from '../src/types'

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

const config: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: TEST_API_VERSION as ApiVersion,
  token: 'test-token',
}

function fakeDoc(id: string, extra: Record<string, unknown> = {}): BarkparkDocument {
  return {
    _id: id,
    _type: 'post',
    _rev: 'ffffffffffffffffffffffffffffffff',
    _draft: false,
    _publishedId: id,
    _createdAt: '2026-04-18T00:00:00.000Z',
    _updatedAt: '2026-04-18T00:00:00.000Z',
    ...extra,
  }
}

describe('createPatch', () => {
  it('commit() returns a MutateResult on success', async () => {
    server.use(
      http.post(`${TEST_BASE_URL}/v1/data/mutate/:dataset`, async ({ request }) => {
        const body = (await request.json()) as {
          mutations: Array<{ patch: { id: string; set: Record<string, unknown> } }>
        }
        const p = body.mutations[0]!.patch
        const env: MutateEnvelope = {
          transactionId: TEST_TX_ID,
          results: [
            { id: p.id, operation: 'update', document: fakeDoc(p.id, p.set) },
          ],
        }
        return HttpResponse.json(env, { status: 200 })
      }),
    )

    const result = await createPatch(config, 'p1').set({ title: 'New' }).commit()
    expect(result.id).toBe('p1')
    expect(result.operation).toBe('update')
    expect(result.document.title).toBe('New')
  })

  it('set() rejects forbidden system fields', () => {
    expect(() => createPatch(config, 'p1').set({ _id: 'other' })).toThrow(
      BarkparkValidationError,
    )
    expect(() => createPatch(config, 'p1').set({ _rev: 'x' })).toThrow(
      BarkparkValidationError,
    )
  })

  it('inc() throws with a Phase 1A not-implemented message', () => {
    expect(() => createPatch(config, 'p1').inc({ views: 1 })).toThrow(/Phase 1A/)
    expect(() => createPatch(config, 'p1').inc({ views: 1 })).toThrow(
      BarkparkValidationError,
    )
  })

  it('commit() without any set() throws BarkparkValidationError', async () => {
    await expect(createPatch(config, 'p1').commit()).rejects.toThrow(
      BarkparkValidationError,
    )
  })

  it('commit({ ifMatch }) includes ifMatch in the mutation body', async () => {
    let capturedPatch: { id: string; ifMatch?: string; set: Record<string, unknown> } | null =
      null
    server.use(
      http.post(`${TEST_BASE_URL}/v1/data/mutate/:dataset`, async ({ request }) => {
        const body = (await request.json()) as {
          mutations: Array<{
            patch: { id: string; set: Record<string, unknown>; ifMatch?: string }
          }>
        }
        capturedPatch = body.mutations[0]!.patch
        const env: MutateEnvelope = {
          transactionId: TEST_TX_ID,
          results: [
            { id: capturedPatch.id, operation: 'update', document: fakeDoc(capturedPatch.id) },
          ],
        }
        return HttpResponse.json(env, { status: 200 })
      }),
    )

    await createPatch(config, 'p1')
      .set({ title: 'v2' })
      .commit({ ifMatch: 'W/"abc"' })

    expect(capturedPatch).not.toBeNull()
    expect(capturedPatch!.id).toBe('p1')
    expect(capturedPatch!.ifMatch).toBe('W/"abc"')
    expect(capturedPatch!.set).toEqual({ title: 'v2' })
  })

  it('commit({ idempotencyKey }) sends Idempotency-Key header', async () => {
    let capturedKey: string | null = null
    server.use(
      http.post(`${TEST_BASE_URL}/v1/data/mutate/:dataset`, ({ request }) => {
        capturedKey = request.headers.get('idempotency-key')
        const env: MutateEnvelope = {
          transactionId: TEST_TX_ID,
          results: [{ id: 'p1', operation: 'update', document: fakeDoc('p1') }],
        }
        return HttpResponse.json(env, { status: 200 })
      }),
    )

    await createPatch(config, 'p1')
      .set({ title: 'x' })
      .commit({ idempotencyKey: 'user-supplied-key-xyz' })

    expect(capturedKey).toBe('user-supplied-key-xyz')
  })
})
