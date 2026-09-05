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

    const result = await createPatch(config, 'p1', 'post').set({ title: 'New' }).commit()
    expect(result.id).toBe('p1')
    expect(result.operation).toBe('update')
    expect(result.document.title).toBe('New')
  })

  it('set() rejects forbidden system fields', () => {
    expect(() => createPatch(config, 'p1', 'post').set({ _id: 'other' })).toThrow(
      BarkparkValidationError,
    )
    expect(() => createPatch(config, 'p1', 'post').set({ _rev: 'x' })).toThrow(
      BarkparkValidationError,
    )
  })

  it('setIfMissing() sends a patch.setIfMissing wire op (Phase-1B), composing with set', async () => {
    let seen:
      | { id: string; set?: Record<string, unknown>; setIfMissing?: Record<string, unknown> }
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

    // setIfMissing-only: no set() required.
    await createPatch(config, 'p1', 'post').setIfMissing({ lang: 'en', region: 'EU' }).commit()
    expect(seen?.setIfMissing).toEqual({ lang: 'en', region: 'EU' })

    // set + setIfMissing compose in one commit.
    await createPatch(config, 'p2', 'post')
      .set({ tier: 'pro' })
      .setIfMissing({ plan: 'basic' })
      .commit()
    expect(seen?.set).toEqual({ tier: 'pro' })
    expect(seen?.setIfMissing).toEqual({ plan: 'basic' })
  })

  it('setIfMissing() validates: non-object and system fields throw', () => {
    expect(() =>
      createPatch(config, 'p1', 'post').setIfMissing([] as unknown as Record<string, unknown>),
    ).toThrow(BarkparkValidationError)
    expect(() => createPatch(config, 'p1', 'post').setIfMissing({ _rev: 'x' })).toThrow(
      /system field/,
    )
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
    await createPatch(config, 'p1', 'post').inc({ views: 1, hits: 5 }).commit()
    expect(seen?.inc).toEqual({ views: 1, hits: 5 })

    // set + inc + dec compose in one commit.
    await createPatch(config, 'p2', 'post')
      .set({ title: 'New' })
      .inc({ a: 2 })
      .dec({ b: 3 })
      .commit()
    expect(seen?.set).toEqual({ title: 'New' })
    expect(seen?.inc).toEqual({ a: 2 })
    expect(seen?.dec).toEqual({ b: 3 })
  })

  it('inc()/dec() validate: non-object, system fields, and non-finite deltas throw', () => {
    expect(() =>
      createPatch(config, 'p1', 'post').inc(42 as unknown as Record<string, number>),
    ).toThrow(BarkparkValidationError)
    expect(() => createPatch(config, 'p1', 'post').inc({ _rev: 1 })).toThrow(/system field/)
    expect(() => createPatch(config, 'p1', 'post').dec({ x: Infinity })).toThrow(/finite/)
    expect(() => createPatch(config, 'p1', 'post').inc({ x: 'nope' as unknown as number })).toThrow(
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
    await createPatch(config, 'p1', 'post').unset(['draft', 'legacy']).commit()
    expect(seen?.unset).toEqual(['draft', 'legacy'])

    // set + unset compose in one commit.
    await createPatch(config, 'p2', 'post').set({ title: 'New' }).unset(['draft']).commit()
    expect(seen?.set).toEqual({ title: 'New' })
    expect(seen?.unset).toEqual(['draft'])
  })

  it('unset() validates: non-array, non-string keys, and system fields all throw', () => {
    expect(() => createPatch(config, 'p1', 'post').unset('draft' as unknown as string[])).toThrow(
      BarkparkValidationError,
    )
    expect(() => createPatch(config, 'p1', 'post').unset([1 as unknown as string])).toThrow(
      BarkparkValidationError,
    )
    expect(() => createPatch(config, 'p1', 'post').unset(['_rev'])).toThrow(/system field/)
  })

  it('insert / diffMatchPatch (still Phase 1A) throw helpful errors', () => {
    expect(() => createPatch(config, 'p1', 'post').insert('after', 'tags[-1]', ['x'])).toThrow(
      /Phase 1A/,
    )
    expect(() => createPatch(config, 'p1', 'post').diffMatchPatch({ body: '@@ -1 +1 @@' })).toThrow(
      /patch\.diffMatchPatch.*Phase 1A/,
    )
  })

  it('append()/prepend() send patch.append/patch.prepend wire ops (Phase-1B)', async () => {
    let seen:
      | { id: string; append?: Record<string, unknown[]>; prepend?: Record<string, unknown[]> }
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

    // selector `tags[-1]` / `tags[0]` resolve to the field `tags`; repeated
    // append on the same field concatenates.
    await createPatch(config, 'p1', 'post')
      .append('tags[-1]', ['a'])
      .append('tags', ['b'])
      .prepend('tags[0]', ['z'])
      .commit()
    expect(seen?.append).toEqual({ tags: ['a', 'b'] })
    expect(seen?.prepend).toEqual({ tags: ['z'] })
  })

  it('append()/prepend() validate: non-array items, nested selectors, and system fields throw', () => {
    expect(() =>
      createPatch(config, 'p1', 'post').append('tags', 'x' as unknown as unknown[]),
    ).toThrow(BarkparkValidationError)
    expect(() => createPatch(config, 'p1', 'post').append('obj.tags', ['x'])).toThrow(/top-level/)
    expect(() => createPatch(config, 'p1', 'post').prepend('_rev', ['x'])).toThrow(/system field/)
  })

  it('commit() without any set() throws BarkparkValidationError', async () => {
    await expect(createPatch(config, 'p1', 'post').commit()).rejects.toThrow(
      BarkparkValidationError,
    )
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

    await createPatch(config, 'p1', 'post').set({ title: 'v2' }).commit({ ifMatch: 'W/"abc"' })

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

    await createPatch(config, 'p1', 'post')
      .set({ title: 'x' })
      .commit({ idempotencyKey: 'user-supplied-key-xyz' })

    expect(capturedKey).toBe('user-supplied-key-xyz')
  })

  it('commit({ retry }) sends ONE stable Idempotency-Key on every attempt, including the first', async () => {
    const keys: Array<string | null> = []
    let calls = 0
    server.use(
      http.post(`${TEST_BASE_URL}/v1/data/mutate/:dataset`, ({ request }) => {
        keys.push(request.headers.get('idempotency-key'))
        calls += 1
        // Fail the first attempt, succeed on the retry. The code must be
        // `internal_error`: that is the ONLY 5xx the narrowed policy repeats
        // (RETRYABLE_SERVER_CODE in src/retry.ts). This fixture used to say
        // `boom`, which worked only while any 5xx was retried.
        if (calls === 1) {
          return HttpResponse.json(
            { error: { code: 'internal_error', message: 'transient' } },
            { status: 500 },
          )
        }
        const env: MutateEnvelope = {
          transactionId: TEST_TX_ID,
          results: [{ id: 'p1', operation: 'update', document: fakeDoc('p1') }],
        }
        return HttpResponse.json(env, { status: 200 })
      }),
    )

    await createPatch(config, 'p1', 'post').set({ title: 'x' }).commit({ retry: true })

    expect(calls).toBe(2)
    // Attempt 1 must already carry a key (regression: it used to be omitted).
    expect(keys[0]).toBeTruthy()
    // Both attempts must carry the SAME key so server-side dedup collapses them.
    expect(keys[1]).toBe(keys[0])
  })
})
