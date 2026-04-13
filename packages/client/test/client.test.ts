/**
 * Integration tests for @barkpark/client. Hits a live Phoenix instance at
 * localhost:4000 and isolates state in a disposable `sdktest` dataset.
 *
 * Start the server before running:
 *     cd api && MIX_ENV=dev mix phx.server
 */
import { afterAll, beforeAll, describe, expect, test } from 'vitest'
import { BarkparkError, createClient } from '../src/index.js'
import type { DocumentEnvelope } from '../src/index.js'

const BASE = process.env.BARKPARK_TEST_URL ?? 'http://localhost:4000'
const TOKEN = process.env.BARKPARK_TEST_TOKEN ?? 'barkpark-dev-token'
const DATASET = 'sdktest'

interface TestPost extends DocumentEnvelope {
  _type: 'post'
  title: string
  body?: string
}

const client = createClient({
  projectUrl: BASE,
  dataset: DATASET,
  token: TOKEN,
})

async function upsertSchema(name: string) {
  const url = `${BASE}/v1/schemas/${DATASET}`
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${TOKEN}`,
    },
    body: JSON.stringify({ name, title: 'Post', visibility: 'public', fields: [] }),
  })
  if (!res.ok) throw new Error(`schema upsert failed: ${res.status} ${await res.text()}`)
}

async function purgeDataset() {
  // Delete any docs with the `sdk-` id prefix. We don't have a wildcard delete,
  // so we list via raw perspective and delete each. Ignores 404s.
  const res = await client
    .withPerspective('raw')
    .query<TestPost>('post', { limit: 1000 })
  for (const doc of res.documents) {
    const id = doc._publishedId
    try {
      await client.delete<TestPost>('post', id)
    } catch (err) {
      if (!(err instanceof BarkparkError && err.code === 'not_found')) throw err
    }
  }
}

beforeAll(async () => {
  await upsertSchema('post')
  await purgeDataset()
})

afterAll(async () => {
  await purgeDataset()
})

describe('reads', () => {
  test('createClient rejects missing config', () => {
    expect(() => createClient({ projectUrl: '', dataset: 'x' })).toThrow()
    expect(() => createClient({ projectUrl: 'http://x', dataset: '' })).toThrow()
  })

  test('query returns flat envelope with reserved keys', async () => {
    await client.create<TestPost>({ _id: 'sdk-1', _type: 'post', title: 'SDK 1', body: 'hi' })

    const res = await client
      .withPerspective('drafts')
      .query<TestPost>('post', { filter: { title: 'SDK 1' } })

    expect(res.count).toBe(1)
    const doc = res.documents[0]!
    expect(doc._id).toBe('drafts.sdk-1')
    expect(doc._type).toBe('post')
    expect(doc._rev).toMatch(/^[0-9a-f]{32}$/)
    expect(doc._draft).toBe(true)
    expect(doc._publishedId).toBe('sdk-1')
    expect(doc._createdAt).toMatch(/Z$/)
    expect(doc.title).toBe('SDK 1')
    expect(doc.body).toBe('hi')
    // reserved keys should not leak under `content`
    expect(doc).not.toHaveProperty('content')
  })

  test('getDocument returns a single envelope', async () => {
    await client.create<TestPost>({ _id: 'sdk-get', _type: 'post', title: 'get me' })
    const doc = await client
      .withPerspective('raw')
      .getDocument<TestPost>('post', 'drafts.sdk-get')
    expect(doc._id).toBe('drafts.sdk-get')
    expect(doc.title).toBe('get me')
  })

  test('getDocument throws BarkparkError with code=not_found on missing doc', async () => {
    await expect(
      client.withPerspective('raw').getDocument<TestPost>('post', 'drafts.sdk-nope'),
    ).rejects.toMatchObject({
      name: 'BarkparkError',
      code: 'not_found',
      status: 404,
    })
  })

  test('pagination returns disjoint pages', async () => {
    for (let i = 0; i < 5; i++) {
      await client.createOrReplace<TestPost>({
        _id: `sdk-page-${i}`,
        _type: 'post',
        title: `page-${i}`,
      })
    }
    const drafts = client.withPerspective('drafts')
    const p1 = await drafts.query<TestPost>('post', { limit: 2, offset: 0 })
    const p2 = await drafts.query<TestPost>('post', { limit: 2, offset: 2 })
    expect(p1.documents.length).toBe(2)
    expect(p2.documents.length).toBe(2)
    expect(p1.limit).toBe(2)
    expect(p1.offset).toBe(0)
    expect(p2.offset).toBe(2)
    const ids1 = new Set(p1.documents.map((d) => d._id))
    const ids2 = new Set(p2.documents.map((d) => d._id))
    for (const id of ids1) expect(ids2.has(id)).toBe(false)
  })

  test('order asc reverses order desc', async () => {
    const drafts = client.withPerspective('drafts')
    const desc = await drafts.query<TestPost>('post', {
      order: '_createdAt:desc',
      limit: 50,
    })
    const asc = await drafts.query<TestPost>('post', {
      order: '_createdAt:asc',
      limit: 50,
    })
    const descIds = desc.documents.map((d) => d._id)
    const ascIds = asc.documents.map((d) => d._id)
    expect(descIds.slice().reverse()).toEqual(ascIds)
  })
})

describe('mutations', () => {
  test('create returns a flat envelope with fresh rev', async () => {
    const doc = await client.create<TestPost>({
      _id: 'sdk-create',
      _type: 'post',
      title: 'created',
      body: 'hello',
    })
    expect(doc._id).toBe('drafts.sdk-create')
    expect(doc.title).toBe('created')
    expect(doc.body).toBe('hello')
    expect(doc._rev).toMatch(/^[0-9a-f]{32}$/)
  })

  test('duplicate create throws conflict', async () => {
    await client.create<TestPost>({ _id: 'sdk-dup', _type: 'post', title: 'one' })
    await expect(
      client.create<TestPost>({ _id: 'sdk-dup', _type: 'post', title: 'two' }),
    ).rejects.toMatchObject({ code: 'conflict', status: 409 })
  })

  test('createOrReplace upserts', async () => {
    await client.createOrReplace<TestPost>({
      _id: 'sdk-upsert',
      _type: 'post',
      title: 'v1',
    })
    const d2 = await client.createOrReplace<TestPost>({
      _id: 'sdk-upsert',
      _type: 'post',
      title: 'v2',
    })
    expect(d2.title).toBe('v2')
  })

  test('createIfNotExists is a noop on conflict', async () => {
    await client.createIfNotExists<TestPost>({
      _id: 'sdk-ifne',
      _type: 'post',
      title: 'first',
    })
    const result = await client.mutate<TestPost>([
      { createIfNotExists: { _id: 'sdk-ifne', _type: 'post', title: 'second' } },
    ])
    expect(result.results[0]!.operation).toBe('noop')
    expect(result.results[0]!.document.title).toBe('first')
  })

  test('patch with matching ifRevisionID succeeds; stale rev → rev_mismatch', async () => {
    const doc = await client.create<TestPost>({
      _id: 'sdk-rev',
      _type: 'post',
      title: 'v1',
    })

    const updated = await client.patch<TestPost>('post', doc._id, {
      set: { title: 'v2' },
      ifRevisionID: doc._rev,
    })
    expect(updated.title).toBe('v2')
    expect(updated._rev).not.toBe(doc._rev)

    await expect(
      client.patch<TestPost>('post', doc._id, {
        set: { title: 'v3' },
        ifRevisionID: 'deadbeef',
      }),
    ).rejects.toMatchObject({ code: 'rev_mismatch', status: 409 })
  })

  test('publish flips _draft', async () => {
    await client.create<TestPost>({ _id: 'sdk-pub', _type: 'post', title: 'to publish' })
    const published = await client.publish<TestPost>('post', 'sdk-pub')
    expect(published._draft).toBe(false)
    expect(published._id).toBe('sdk-pub')
  })

  test('batch mutate is atomic — failing batch leaves nothing behind', async () => {
    await expect(
      client.mutate<TestPost>([
        { create: { _id: 'sdk-atomic', _type: 'post', title: 'rollback me' } },
        { publish: { id: 'sdk-nonexistent', type: 'post' } },
      ]),
    ).rejects.toMatchObject({ code: 'not_found' })

    // Confirm sdk-atomic did NOT persist
    const probe = await client
      .withPerspective('raw')
      .query<TestPost>('post', { filter: { title: 'rollback me' } })
    expect(probe.count).toBe(0)
  })
})

describe('errors', () => {
  test('missing auth on mutate → BarkparkError unauthorized', async () => {
    const noauth = client.withToken(undefined)
    await expect(
      noauth.create<TestPost>({ _id: 'sdk-noauth', _type: 'post', title: 'x' }),
    ).rejects.toMatchObject({ code: 'unauthorized', status: 401 })
  })
})

describe('derivation', () => {
  test('withPerspective / withDataset / withToken return fresh instances', () => {
    const a = client.withPerspective('drafts')
    const b = client.withDataset('other')
    const c = client.withToken('different')
    expect(a).not.toBe(client)
    expect(b).not.toBe(client)
    expect(c).not.toBe(client)
  })
})
