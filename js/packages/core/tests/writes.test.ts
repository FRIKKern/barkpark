import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest'
import type { BarkparkClientConfig, MutateEnvelope } from '../src/types'
import { createTransaction } from '../src/transaction'
import { createClient } from '../src/client'
import { publishDoc, unpublishDoc, discardDraftDoc } from '../src/publish'
import { fetchRawDoc } from '../src/fetchRaw'
import { BarkparkAPIError, BarkparkValidationError } from '../src/errors'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'

beforeAll(() => server.listen({ onUnhandledRequest: 'bypass' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

interface SpyCall {
  url: string
  method: string
  headers: Record<string, string>
  body: unknown
}

/**
 * Build a config backed by a spy `fetch` that captures each call and
 * returns a canned MutateEnvelope. Unlike MSW, this lets us assert the
 * exact request body shape the SDK emits (e.g. presence of `ifMatch`
 * inside a patch op) without relying on MSW's looser handler semantics.
 */
function makeSpyConfig(response: MutateEnvelope = { transactionId: 'tx_spy', results: [] }): {
  config: BarkparkClientConfig
  calls: SpyCall[]
} {
  const calls: SpyCall[] = []
  const spy: typeof globalThis.fetch = async (input, init) => {
    const url = typeof input === 'string' ? input : (input as Request).url
    const headers: Record<string, string> = {}
    const rawHeaders = init?.headers
    if (rawHeaders) {
      if (rawHeaders instanceof Headers) {
        rawHeaders.forEach((v, k) => {
          headers[k.toLowerCase()] = v
        })
      } else if (Array.isArray(rawHeaders)) {
        for (const [k, v] of rawHeaders) headers[k.toLowerCase()] = v
      } else {
        for (const [k, v] of Object.entries(rawHeaders as Record<string, string>)) {
          headers[k.toLowerCase()] = v
        }
      }
    }
    let body: unknown = undefined
    if (typeof init?.body === 'string') {
      try {
        body = JSON.parse(init.body)
      } catch {
        body = init.body
      }
    }
    calls.push({ url, method: init?.method ?? 'GET', headers, body })
    return new Response(JSON.stringify(response), {
      status: 200,
      headers: { 'content-type': 'application/json', 'x-request-id': 'req_spy' },
    })
  }
  const config: BarkparkClientConfig = {
    projectUrl: 'http://spy.local',
    dataset: 'production',
    apiVersion: '2026-04-17',
    token: 'test-token',
    fetch: spy,
  }
  return { config, calls }
}

/** Spy config scoped to a workspace + project — exercises scopePrefix(). */
function makeScopedSpyConfig(response: MutateEnvelope = { transactionId: 'tx_spy', results: [] }): {
  config: BarkparkClientConfig
  calls: SpyCall[]
} {
  const { config, calls } = makeSpyConfig(response)
  return {
    config: { ...config, workspace: 'acme', project: 'blog' },
    calls,
  }
}

describe('transaction', () => {
  it('commits a single create mutation and returns MutateEnvelope', async () => {
    const { config, calls } = makeSpyConfig({
      transactionId: 'tx_1',
      results: [
        {
          id: 'drafts.post-1',
          operation: 'create',
          document: {
            _id: 'drafts.post-1',
            _type: 'post',
            _rev: 'r1',
            _draft: true,
            _publishedId: 'post-1',
            _createdAt: '2026-04-12T09:11:20Z',
            _updatedAt: '2026-04-12T09:11:20Z',
            title: 'x',
          },
        },
      ],
    })
    const env = await createTransaction(config).create({ _type: 'post', title: 'x' }).commit()
    expect(env.transactionId).toBe('tx_1')
    expect(env.results).toHaveLength(1)
    expect(calls).toHaveLength(1)
    expect(calls[0]!.method).toBe('POST')
    expect(calls[0]!.url).toBe('http://spy.local/v1/data/mutate/production')
    expect(calls[0]!.body).toEqual({
      mutations: [{ create: { _type: 'post', title: 'x' } }],
    })
  })

  it('client single-mutation conveniences (create / delete / createOrReplace / createIfNotExists) each commit one op', async () => {
    const { config, calls } = makeSpyConfig()
    const bp = createClient(config)

    await bp.create({ _type: 'post', title: 'New' })
    expect(calls[0]!.body).toEqual({ mutations: [{ create: { _type: 'post', title: 'New' } }] })

    await bp.delete('p2', 'post')
    expect(calls[1]!.body).toEqual({ mutations: [{ delete: { id: 'p2', type: 'post' } }] })

    await bp.createOrReplace({ _id: 'p3', _type: 'post', title: 'R' })
    expect(calls[2]!.body).toEqual({
      mutations: [{ createOrReplace: { _id: 'p3', _type: 'post', title: 'R' } }],
    })

    await bp.createIfNotExists({ _id: 'p4', _type: 'post', title: 'Seed' })
    expect(calls[3]!.body).toEqual({
      mutations: [{ createIfNotExists: { _id: 'p4', _type: 'post', title: 'Seed' } }],
    })
  })

  it('commits publish op with MutateEnvelope result', async () => {
    const { config, calls } = makeSpyConfig({
      transactionId: 'tx_pub',
      results: [
        {
          id: 'p1',
          operation: 'publish',
          document: {
            _id: 'p1',
            _type: 'post',
            _rev: 'r2',
            _draft: false,
            _publishedId: 'p1',
            _createdAt: '2026-04-12T09:11:20Z',
            _updatedAt: '2026-04-12T09:11:20Z',
          },
        },
      ],
    })
    const env = await createTransaction(config).publish('p1', 'post').commit()
    expect(env.results[0]!.operation).toBe('publish')
    expect(calls[0]!.body).toEqual({
      mutations: [{ publish: { id: 'p1', type: 'post' } }],
    })
  })

  it('transaction discardDraft op posts a discardDraft mutation', async () => {
    const { config, calls } = makeSpyConfig()
    await createTransaction(config).discardDraft('p1', 'post').commit()
    expect(calls[0]!.body).toEqual({
      mutations: [{ discardDraft: { id: 'p1', type: 'post' } }],
    })
  })

  it('batches create + patch + publish in a single POST with 3 mutations', async () => {
    const { config, calls } = makeSpyConfig()
    await createTransaction(config)
      .create({ _type: 'post', title: 'fresh' })
      .patch('p1', 'post', (b) => b.set({ title: 'changed' }))
      .publish('p1', 'post')
      .commit()
    expect(calls).toHaveLength(1)
    const body = calls[0]!.body as { mutations: unknown[] }
    expect(body.mutations).toHaveLength(3)
    expect(body.mutations[0]).toHaveProperty('create')
    expect(body.mutations[1]).toHaveProperty('patch')
    expect(body.mutations[2]).toHaveProperty('publish')
  })

  it('rejects commit() when no mutations have been added', async () => {
    const { config } = makeSpyConfig()
    await expect(createTransaction(config).commit()).rejects.toBeInstanceOf(BarkparkValidationError)
  })

  it('patch with ifMatch propagates to body', async () => {
    const { config, calls } = makeSpyConfig()
    await createTransaction(config)
      .patch('p1', 'post', (b) => b.set({ title: 'x' }), { ifMatch: 'rev-abc' })
      .commit()
    const body = calls[0]!.body as {
      mutations: Array<{ patch: { id: string; set: Record<string, unknown>; ifMatch?: string } }>
    }
    expect(body.mutations[0]!.patch.ifMatch).toBe('rev-abc')
    expect(body.mutations[0]!.patch.set).toEqual({ title: 'x' })
    expect(body.mutations[0]!.patch.id).toBe('p1')
  })

  it('commit with idempotencyKey sets Idempotency-Key header', async () => {
    const { config, calls } = makeSpyConfig()
    await createTransaction(config).publish('p1', 'post').commit({ idempotencyKey: 'k1' })
    expect(calls[0]!.headers['idempotency-key']).toBe('k1')
  })

  it('transaction patch carries setIfMissing / unset / inc / dec ops (Phase-1B)', async () => {
    const { config, calls } = makeSpyConfig()
    await createTransaction(config)
      .patch('p1', 'post', (b) =>
        b
          .set({ title: 'New' })
          .setIfMissing({ lang: 'en' })
          .unset(['draft'])
          .inc({ views: 1 })
          .dec({ stock: 2 }),
      )
      .commit()
    const patch = (calls[0]!.body as { mutations: Array<{ patch: Record<string, unknown> }> })
      .mutations[0]!.patch
    expect(patch.set).toEqual({ title: 'New' })
    expect(patch.setIfMissing).toEqual({ lang: 'en' })
    expect(patch.unset).toEqual(['draft'])
    expect(patch.inc).toEqual({ views: 1 })
    expect(patch.dec).toEqual({ stock: 2 })
  })

  it('transaction patch with only inc (no set) is valid', async () => {
    const { config, calls } = makeSpyConfig()
    await createTransaction(config)
      .patch('p1', 'post', (b) => b.inc({ views: 1 }))
      .commit()
    const patch = (calls[0]!.body as { mutations: Array<{ patch: Record<string, unknown> }> })
      .mutations[0]!.patch
    expect(patch.inc).toEqual({ views: 1 })
    expect(patch.set).toEqual({})
  })

  it('transaction patch carries append / prepend ops (selector→field; Phase-1B)', async () => {
    const { config, calls } = makeSpyConfig()
    await createTransaction(config)
      .patch('p1', 'post', (b) => b.append('tags[-1]', ['a']).prepend('tags', ['z']))
      .commit()
    const patch = (calls[0]!.body as { mutations: Array<{ patch: Record<string, unknown> }> })
      .mutations[0]!.patch
    expect(patch.append).toEqual({ tags: ['a'] })
    expect(patch.prepend).toEqual({ tags: ['z'] })
  })

  it('patch.set blocks reserved _-fields', () => {
    const { config } = makeSpyConfig()
    expect(() =>
      createTransaction(config).patch('p1', 'post', (b) => b.set({ _rev: 'r1' } as any)),
    ).toThrow(BarkparkValidationError)
  })

  it('patch rejects an empty document id (parity with createPatch + sibling ops)', () => {
    const { config } = makeSpyConfig()
    expect(() =>
      createTransaction(config).patch('', 'post', (p) => p.set({ title: 'x' })),
    ).toThrow(BarkparkValidationError)
  })
})

describe('scoped write paths (workspace + project)', () => {
  it('transaction.commit hits flat /v1/... without workspace/project', async () => {
    const { config, calls } = makeSpyConfig()
    await createTransaction(config).create({ _type: 'post', title: 'x' }).commit()
    expect(calls[0]!.url).toBe('http://spy.local/v1/data/mutate/production')
  })

  it('transaction.commit hits /w/.../p/.../v1/... when scoped', async () => {
    const { config, calls } = makeScopedSpyConfig()
    await createTransaction(config).create({ _type: 'post', title: 'x' }).commit()
    expect(calls[0]!.url).toBe('http://spy.local/w/acme/p/blog/v1/data/mutate/production')
  })

  it('publishDoc / unpublishDoc honor the scope prefix', async () => {
    const okResult: MutateEnvelope = {
      transactionId: 'tx_scope',
      results: [
        {
          id: 'p1',
          operation: 'publish',
          document: {
            _id: 'p1',
            _type: 'post',
            _rev: 'r1',
            _draft: false,
            _publishedId: 'p1',
            _createdAt: '2026-04-12T09:11:20Z',
            _updatedAt: '2026-04-12T09:11:20Z',
          },
        },
      ],
    }
    const scoped = makeScopedSpyConfig(okResult)
    await publishDoc(scoped.config, 'p1', 'post')
    expect(scoped.calls[0]!.url).toBe('http://spy.local/w/acme/p/blog/v1/data/mutate/production')

    const flat = makeSpyConfig(okResult)
    await unpublishDoc(flat.config, 'p1', 'post')
    expect(flat.calls[0]!.url).toBe('http://spy.local/v1/data/mutate/production')
  })
})

describe('publish / unpublish helpers', () => {
  it('publishDoc wraps a single publish op and returns first result', async () => {
    const { config, calls } = makeSpyConfig({
      transactionId: 'tx_p',
      results: [
        {
          id: 'p1',
          operation: 'publish',
          document: {
            _id: 'p1',
            _type: 'post',
            _rev: 'r3',
            _draft: false,
            _publishedId: 'p1',
            _createdAt: '2026-04-12T09:11:20Z',
            _updatedAt: '2026-04-12T09:11:20Z',
          },
        },
      ],
    })
    const res = await publishDoc(config, 'p1', 'post')
    expect(res.operation).toBe('publish')
    expect(calls[0]!.body).toEqual({
      mutations: [{ publish: { id: 'p1', type: 'post' } }],
    })
  })

  it('publishDoc forwards CommitOptions.idempotencyKey to the request header', async () => {
    const { config, calls } = makeSpyConfig({
      transactionId: 'tx_pk',
      results: [
        {
          id: 'p1',
          operation: 'publish',
          document: {
            _id: 'p1',
            _type: 'post',
            _rev: 'r5',
            _draft: false,
            _publishedId: 'p1',
            _createdAt: '2026-04-12T09:11:20Z',
            _updatedAt: '2026-04-12T09:11:20Z',
          },
        },
      ],
    })
    await publishDoc(config, 'p1', 'post', { idempotencyKey: 'idem-pub-1' })
    expect(calls[0]!.headers['idempotency-key']).toBe('idem-pub-1')
    // body stays a plain publish op — opts must not leak into the mutation
    expect(calls[0]!.body).toEqual({ mutations: [{ publish: { id: 'p1', type: 'post' } }] })
  })

  it('unpublishDoc wraps a single unpublish op and returns first result', async () => {
    const { config, calls } = makeSpyConfig({
      transactionId: 'tx_u',
      results: [
        {
          id: 'drafts.p1',
          operation: 'unpublish',
          document: {
            _id: 'drafts.p1',
            _type: 'post',
            _rev: 'r4',
            _draft: true,
            _publishedId: 'p1',
            _createdAt: '2026-04-12T09:11:20Z',
            _updatedAt: '2026-04-12T09:11:20Z',
          },
        },
      ],
    })
    const res = await unpublishDoc(config, 'p1', 'post')
    expect(res.operation).toBe('unpublish')
    expect(calls[0]!.body).toEqual({
      mutations: [{ unpublish: { id: 'p1', type: 'post' } }],
    })
  })

  it('discardDraftDoc wraps a single discardDraft op and returns first result', async () => {
    const { config, calls } = makeSpyConfig({
      transactionId: 'tx_d',
      results: [
        {
          id: 'p1',
          operation: 'discardDraft',
          document: {
            _id: 'p1',
            _type: 'post',
            _rev: 'r5',
            _draft: false,
            _publishedId: 'p1',
            _createdAt: '2026-04-12T09:11:20Z',
            _updatedAt: '2026-04-12T09:11:20Z',
          },
        },
      ],
    })
    const res = await discardDraftDoc(config, 'p1', 'post')
    expect(res.operation).toBe('discardDraft')
    expect(calls[0]!.body).toEqual({
      mutations: [{ discardDraft: { id: 'p1', type: 'post' } }],
    })
  })

  it('discardDraftDoc rejects missing id/type', async () => {
    const { config } = makeSpyConfig()
    await expect(discardDraftDoc(config, '', 'post')).rejects.toThrow(BarkparkValidationError)
    await expect(discardDraftDoc(config, 'p1', '')).rejects.toThrow(BarkparkValidationError)
  })

  it('publishDoc rejects missing id/type', async () => {
    const { config } = makeSpyConfig()
    await expect(publishDoc(config, '', 'post')).rejects.toBeInstanceOf(BarkparkValidationError)
    await expect(publishDoc(config, 'p1', '')).rejects.toBeInstanceOf(BarkparkValidationError)
  })
})

describe('fetchRawDoc', () => {
  it('returns a raw Response for a GET path', async () => {
    const config: BarkparkClientConfig = {
      projectUrl: TEST_BASE_URL,
      dataset: TEST_DATASET,
      apiVersion: '2026-04-17',
    }
    const res = await fetchRawDoc(config, `/v1/meta?dataset=${TEST_DATASET}`)
    expect(res).toBeInstanceOf(Response)
    expect(res.ok).toBe(true)
    const body = (await res.json()) as { maxApiVersion: string }
    expect(body.maxApiVersion).toBeTruthy()
  })

  it('rejects relative paths that do not start with /', async () => {
    const config: BarkparkClientConfig = {
      projectUrl: TEST_BASE_URL,
      dataset: TEST_DATASET,
      apiVersion: '2026-04-17',
    }
    await expect(fetchRawDoc(config, 'v1/meta')).rejects.toBeInstanceOf(BarkparkValidationError)
  })

  it('a 422 whose details is JSON null throws a typed BarkparkValidationError (not a raw TypeError)', async () => {
    // A Phoenix changeset-less validation error serializes `details` as JSON
    // null. typeof null === 'object', so the transport used to let null through
    // to `Object.entries(null)` → a raw TypeError that escapes the error
    // taxonomy (caller loses status/serverCode/message/request_id).
    const errorBody = {
      error: {
        code: 'validation_failed',
        message: 'Title is required',
        details: null,
        request_id: 'req_abc',
      },
    }
    const config: BarkparkClientConfig = {
      projectUrl: 'http://spy.local',
      dataset: 'production',
      apiVersion: '2026-04-17',
      token: 'test-token',
      fetch: async () =>
        new Response(JSON.stringify(errorBody), {
          status: 422,
          headers: { 'content-type': 'application/json' },
        }),
    }
    const bp = createClient(config)

    await expect(bp.create({ _type: 'post', title: 'x' })).rejects.toBeInstanceOf(
      BarkparkValidationError,
    )

    // …and it carries the server's taxonomy rather than a bare TypeError.
    const err = await bp.create({ _type: 'post', title: 'x' }).then(
      () => {
        throw new Error('expected the create to reject')
      },
      (e: unknown) => e as BarkparkValidationError,
    )
    expect(err).toBeInstanceOf(BarkparkValidationError)
    expect(err.status).toBe(422)
    expect(err.serverCode).toBe('validation_failed')
    expect(err.requestId).toBe('req_abc')
    expect(err.message).toBe('Title is required')
  })

  it('a 2xx that omits results throws the typed error, not a raw TypeError', async () => {
    // A malformed 2xx (e.g. from a misbehaving proxy) with no `results` field.
    // `data.results[0]` used to throw `TypeError: cannot read '0' of undefined`
    // BEFORE the guard that is meant to raise a typed error on missing results.
    const noResults = { transactionId: 'tx_spy' } as unknown as MutateEnvelope

    const { config: pubConfig } = makeSpyConfig(noResults)
    await expect(publishDoc(pubConfig, 'p1', 'post')).rejects.toBeInstanceOf(
      BarkparkValidationError,
    )

    const { config: patchConfig } = makeSpyConfig(noResults)
    await expect(
      createClient(patchConfig).patch('p1', 'post').set({ title: 'x' }).commit(),
    ).rejects.toBeInstanceOf(BarkparkAPIError)
  })
})
