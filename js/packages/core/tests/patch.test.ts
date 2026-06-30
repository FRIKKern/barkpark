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
          results: [{ id: p.id, operation: 'update', document: fakeDoc(p.id, p.set) }],
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
    expect(() => createPatch(config, 'p1').set({ _id: 'other' })).toThrow(BarkparkValidationError)
    expect(() => createPatch(config, 'p1').set({ _rev: 'x' })).toThrow(BarkparkValidationError)
  })

  it('setIfMissing() (still Phase 1A) throws a helpful not-implemented error', () => {
    // A migrant reaching for it gets an actionable message, not "x is not a function".
    expect(() => createPatch(config, 'p1').setIfMissing({ a: 1 })).toThrow(
      /patch\.setIfMissing.*Phase 1A/,
    )
    expect(() => createPatch(config, 'p1').setIfMissing({ a: 1 })).toThrow(BarkparkValidationError)
  })

  it('inc()/dec() send patch.inc/patch.dec wire ops (Phase-1B), composing with set', async () => {
    let seen:
      | {
          id: string
          set?: Record<string, unknown>
          inc?: Record<string, number>
          dec?: Record<string, number>
        }
      | undefined
    server.use(
      http.post(`${TEST_BASE_URL}/v1/data/mutate/:dataset`, async ({ request }) => {
        const body = (await request.json()) as { mutations: Array<{ patch: typeof seen }> }
        seen = body.mutations[0]!.patch
        const env: MutateEnvelope = {
          transactionId: TEST_TX_ID,
          results: [{ id: seen!.id, operation: 'update', document: fakeDoc(seen!.id, {}) }],
        }
        return HttpResponse.json(env, { status: 200 })
      }),
    )

    // inc-only: no set() required.
    await createPatch(config, 'p1').inc({ views: 1, hits: 5 }).commit()
    expect(seen?.inc).toEqual({ views: 1, hits: 5 })

    // set + inc + dec compose in one commit.
    await createPatch(config, 'p2').set({ title: 'New' }).inc({ a: 2 }).dec({ b: 3 }).commit()
    expect(seen?.set).toEqual({ title: 'New' })
    expect(seen?.inc).toEqual({ a: 2 })
    expect(seen?.dec).toEqual({ b: 3 })
  })

  it('inc()/dec() validate: non-object, system fields, and non-finite deltas throw', () => {
    expect(() => createPatch(config, 'p1').inc(42 as unknown as Record<string, number>)).toThrow(
      BarkparkValidationError,
    )
    expect(() => createPatch(config, 'p1').inc({ _rev: 1 })).toThrow(/system field/)
    expect(() => createPatch(config, 'p1').dec({ x: Infinity })).toThrow(/finite/)
    expect(() => createPatch(config, 'p1').inc({ x: 'nope' as unknown as number })).toThrow(
      /finite/,
    )
  })

  it('unset() sends a patch.unset wire op (Phase-1B), with or without set', async () => {
    let seen: { id: string; set?: Record<string, unknown>; unset?: string[] } | undefined
    server.use(
      http.post(`${TEST_BASE_URL}/v1/data/mutate/:dataset`, async ({ request }) => {
        const body = (await request.json()) as {
          mutations: Array<{ patch: typeof seen }>
        }
        seen = body.mutations[0]!.patch
        const env: MutateEnvelope = {
          transactionId: TEST_TX_ID,
          results: [{ id: seen!.id, operation: 'update', document: fakeDoc(seen!.id, {}) }],
        }
        return HttpResponse.json(env, { status: 200 })
      }),
    )

    // unset-only: no set() call required (was "requires at least one set" before).
    await createPatch(config, 'p1').unset(['draft', 'legacy']).commit()
    expect(seen?.unset).toEqual(['draft', 'legacy'])

    // set + unset compose in one commit.
    await createPatch(config, 'p2').set({ title: 'New' }).unset(['draft']).commit()
    expect(seen?.set).toEqual({ title: 'New' })
    expect(seen?.unset).toEqual(['draft'])
  })

  it('unset() validates: non-array, non-string keys, and system fields all throw', () => {
    expect(() => createPatch(config, 'p1').unset('draft' as unknown as string[])).toThrow(
      BarkparkValidationError,
    )
    expect(() => createPatch(config, 'p1').unset([1 as unknown as string])).toThrow(
      BarkparkValidationError,
    )
    expect(() => createPatch(config, 'p1').unset(['_rev'])).toThrow(/system field/)
  })

  it('the array ops (insert/append/prepend) and diffMatchPatch throw helpful Phase 1A errors', () => {
    expect(() => createPatch(config, 'p1').append('tags[-1]', ['x'])).toThrow(/Phase 1A/)
    expect(() => createPatch(config, 'p1').prepend('tags[0]', ['x'])).toThrow(/Phase 1A/)
    expect(() => createPatch(config, 'p1').insert('after', 'tags[-1]', ['x'])).toThrow(/Phase 1A/)
    expect(() => createPatch(config, 'p1').diffMatchPatch({ body: '@@ -1 +1 @@' })).toThrow(
      /patch\.diffMatchPatch.*Phase 1A/,
    )
    expect(() => createPatch(config, 'p1').append('tags[-1]', ['x'])).toThrow(
      BarkparkValidationError,
    )
  })

  it('commit() without any set() throws BarkparkValidationError', async () => {
    await expect(createPatch(config, 'p1').commit()).rejects.toThrow(BarkparkValidationError)
  })

  it('commit({ ifMatch }) includes ifMatch in the mutation body', async () => {
    let capturedPatch: { id: string; ifMatch?: string; set: Record<string, unknown> } | null = null
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

    await createPatch(config, 'p1').set({ title: 'v2' }).commit({ ifMatch: 'W/"abc"' })

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
