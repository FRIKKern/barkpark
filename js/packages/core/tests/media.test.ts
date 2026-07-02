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
  token: 'tok', // upload requires write
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('uploadAsset', () => {
  it('POSTs multipart to /v1/media/:ds/upload with a `file` part and returns the asset', async () => {
    let seenUrl = ''
    let contentType = ''
    let filePart: { name: string; type: string } | null = null

    server.use(
      http.post(`${TEST_BASE_URL}/v1/media/:ds/upload`, async ({ request }) => {
        seenUrl = request.url
        contentType = request.headers.get('content-type') ?? ''
        const form = await request.formData()
        const f = form.get('file')
        if (f instanceof File) filePart = { name: f.name, type: f.type }
        return HttpResponse.json(
          { result: { _id: 'asset-1', url: 'https://cdn/asset-1.png', filename: 'pic.png' } },
          { status: 201 },
        )
      }),
    )

    const bp = createClient(baseConfig)
    const blob = new Blob([new Uint8Array([1, 2, 3])], { type: 'image/png' })
    const asset = await bp.uploadAsset(blob, { filename: 'pic.png' })

    expect(asset._id).toBe('asset-1')
    expect(asset.url).toBe('https://cdn/asset-1.png')
    expect(new URL(seenUrl).pathname).toBe(`/v1/media/${TEST_DATASET}/upload`)
    // fetch set multipart (the transport dropped the JSON Content-Type)
    expect(contentType).toMatch(/^multipart\/form-data/)
    expect(filePart).toEqual({ name: 'pic.png', type: 'image/png' })
  })
})

describe('listAssets / getAsset / deleteAsset', () => {
  it('listAssets GETs /v1/media/:ds with limit/offset and returns the page', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/media/:ds`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({
          result: {
            assets: [{ _id: 'a1', url: 'https://cdn/a1.png' }],
            count: 7,
            limit: 2,
            offset: 4,
          },
        })
      }),
    )
    const bp = createClient(baseConfig)
    const page = await bp.listAssets({ limit: 2, offset: 4 })
    expect(page.assets).toHaveLength(1)
    expect(page.assets[0]!._id).toBe('a1')
    expect(page.count).toBe(7)
    const url = new URL(seenUrl)
    expect(url.pathname).toBe(`/v1/media/${TEST_DATASET}`)
    expect(url.searchParams.get('limit')).toBe('2')
    expect(url.searchParams.get('offset')).toBe('4')
  })

  it('getAsset GETs /v1/media/:ds/:id; returns null on 404', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/media/:ds/a1`, () =>
        HttpResponse.json({ result: { _id: 'a1', url: 'https://cdn/a1.png' } }),
      ),
      http.get(`${TEST_BASE_URL}/v1/media/:ds/gone`, () =>
        HttpResponse.json({ error: { code: 'not_found', message: 'no asset' } }, { status: 404 }),
      ),
    )
    const bp = createClient(baseConfig)
    expect((await bp.getAsset('a1'))?._id).toBe('a1')
    expect(await bp.getAsset('gone')).toBeNull()
  })

  it('deleteAsset DELETEs /v1/media/:ds/:id and returns { deleted }', async () => {
    let seenMethod = ''
    server.use(
      http.delete(`${TEST_BASE_URL}/v1/media/:ds/a1`, ({ request }) => {
        seenMethod = request.method
        return HttpResponse.json({ result: { deleted: 'a1' } })
      }),
    )
    const bp = createClient(baseConfig)
    const res = await bp.deleteAsset('a1')
    expect(res.deleted).toBe('a1')
    expect(seenMethod).toBe('DELETE')
  })

  it('updateAsset PATCHes /v1/media/:ds/:id with the metadata body and returns the asset', async () => {
    let seenMethod = ''
    let seenBody: unknown
    server.use(
      http.patch(`${TEST_BASE_URL}/v1/media/:ds/a1`, async ({ request }) => {
        seenMethod = request.method
        seenBody = await request.json()
        return HttpResponse.json({ result: { _id: 'a1', altText: 'A cat', tags: ['animal'] } })
      }),
    )
    const bp = createClient(baseConfig)
    const asset = await bp.updateAsset('a1', { altText: 'A cat', tags: ['animal'] })

    expect(seenMethod).toBe('PATCH')
    // Only the passed keys are sent (partial patch); the JSON body round-trips.
    expect(seenBody).toEqual({ altText: 'A cat', tags: ['animal'] })
    // The updated asset is unwrapped from the `{ result }` envelope.
    expect(asset._id).toBe('a1')
    expect(asset.altText).toBe('A cat')
  })

  it('checkoutAsset POSTs .../:id/checkout and returns the asset', async () => {
    let seenPath = ''
    server.use(
      http.post(`${TEST_BASE_URL}/v1/media/:ds/a1/checkout`, ({ request }) => {
        seenPath = new URL(request.url).pathname
        return HttpResponse.json({ result: { _id: 'a1', _checkedOutBy: 'me' } })
      }),
    )
    const bp = createClient(baseConfig)
    const asset = await bp.checkoutAsset('a1')
    expect(seenPath.endsWith('/a1/checkout')).toBe(true)
    expect(asset._id).toBe('a1')
  })

  it('undoCheckoutAsset POSTs .../:id/undo-checkout and returns the asset', async () => {
    let seenPath = ''
    server.use(
      http.post(`${TEST_BASE_URL}/v1/media/:ds/a1/undo-checkout`, ({ request }) => {
        seenPath = new URL(request.url).pathname
        return HttpResponse.json({ result: { _id: 'a1', _checkedOutBy: null } })
      }),
    )
    const bp = createClient(baseConfig)
    const asset = await bp.undoCheckoutAsset('a1')
    expect(seenPath.endsWith('/a1/undo-checkout')).toBe(true)
    expect(asset._id).toBe('a1')
  })

  it('getAssetRelations GETs .../:id/relations and returns outbound/inbound', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/media/:ds/a1/relations`, () =>
        HttpResponse.json({
          result: { outbound: [{ relation: 'relatedAssets', assetDocId: 'a2' }], inbound: [] },
        }),
      ),
    )
    const bp = createClient(baseConfig)
    const rel = await bp.getAssetRelations('a1')
    expect(rel.outbound[0]?.assetDocId).toBe('a2')
    expect(rel.inbound).toEqual([])
  })

  it('getAssetRelations defaults missing outbound/inbound to []', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/media/:ds/a1/relations`, () =>
        HttpResponse.json({ result: {} }),
      ),
    )
    const bp = createClient(baseConfig)
    const rel = await bp.getAssetRelations('a1')
    expect(rel).toEqual({ outbound: [], inbound: [] })
  })

  it('searchAssets GETs .../search with q + filters and parses the result envelope', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/media/:ds/search`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({
          result: {
            hits: [{ _id: 'a1', url: 'https://cdn/a1.png' }],
            total: 42,
            limit: 10,
            offset: 0,
            facets: { kind: [{ label: 'image', count: 42 }] },
            nextCursor: 'c2',
            hasMore: true,
          },
          highlights: { a1: { altText: ['<em>cat</em>'] } },
          parsedQuery: { terms: ['cat'] },
          ms: 7,
        })
      }),
    )
    const bp = createClient(baseConfig)
    const res = await bp.searchAssets('cat', { limit: 10, mimeType: 'image/png', tags: 'animal' })

    // hits/total/pagination come from the `result` envelope...
    expect(res.hits[0]?._id).toBe('a1')
    expect(res.total).toBe(42)
    expect(res.nextCursor).toBe('c2')
    expect(res.hasMore).toBe(true)
    expect(res.facets?.kind).toBeDefined()
    // ...highlights/parsedQuery/ms from the TOP level (asymmetric envelope).
    expect(res.highlights).toEqual({ a1: { altText: ['<em>cat</em>'] } })
    expect(res.ms).toBe(7)

    // `mimeType` is sent as the server's `type` param; q + filters forwarded.
    const url = new URL(seenUrl)
    expect(url.searchParams.get('q')).toBe('cat')
    expect(url.searchParams.get('type')).toBe('image/png')
    expect(url.searchParams.get('tags')).toBe('animal')
    expect(url.searchParams.get('limit')).toBe('10')
  })

  it('searchAssets joins array tags/facets into comma-separated params', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/media/:ds/search`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ result: { hits: [], total: 0 } })
      }),
    )
    const bp = createClient(baseConfig)
    await bp.searchAssets('', { tags: ['animal', 'cat'], facets: ['kind', 'status'] })
    const url = new URL(seenUrl)
    expect(url.searchParams.get('tags')).toBe('animal,cat')
    expect(url.searchParams.get('facets')).toBe('kind,status')
  })

  it('searchAssets cleans blank entries and omits an empty tags/facets list', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/media/:ds/search`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ result: { hits: [], total: 0 } })
      }),
    )
    const bp = createClient(baseConfig)
    // stray '' dropped (no phantom `tags=a,,b`); tags are values, not a
    // projection, so an empty list omits the param rather than throwing.
    await bp.searchAssets('', { tags: ['a', '', 'b'], facets: [] })
    const url = new URL(seenUrl)
    expect(url.searchParams.get('tags')).toBe('a,b')
    expect(url.searchParams.has('facets')).toBe(false)

    await bp.searchAssets('', { tags: [] })
    expect(new URL(seenUrl).searchParams.has('tags')).toBe(false)
  })

  it('searchAssets rejects a comma inside an ARRAY tags/facets entry but passes a single CSV string through', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/media/:ds/search`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ result: { hits: [], total: 0 } })
      }),
    )
    const bp = createClient(baseConfig)
    // An array entry with a comma would silently split into extra values — fail closed.
    await expect(bp.searchAssets('', { tags: ['a,b'] })).rejects.toMatchObject({
      code: 'BarkparkValidationError',
      field: 'tags',
    })
    await expect(bp.searchAssets('', { facets: ['kind,status'] })).rejects.toMatchObject({
      code: 'BarkparkValidationError',
      field: 'facets',
    })
    // A single pre-joined string is intentional CSV — passed through unchanged.
    await bp.searchAssets('', { tags: 'a,b' })
    expect(new URL(seenUrl).searchParams.get('tags')).toBe('a,b')
  })

  it('searchAssets defaults an empty/partial response and omits q when blank', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/media/:ds/search`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ result: {} })
      }),
    )
    const bp = createClient(baseConfig)
    // Empty q = filter-only browse; the `q` param must be absent, not `q=`.
    const res = await bp.searchAssets('', { collection: 'c1' })
    expect(new URL(seenUrl).searchParams.has('q')).toBe(false)
    expect(new URL(seenUrl).searchParams.get('collection')).toBe('c1')
    expect(res).toMatchObject({ hits: [], total: 0, hasMore: false, nextCursor: null })
  })

  it('getAssetSearchSuggestions GETs .../search/suggestions with the prefix + limit', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/media/:ds/search/suggestions`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({
          result: {
            recent: [{ query: 'cat', count: 3 }],
            popular: [{ query: 'cats', count: 40 }],
            nohits: [],
          },
        })
      }),
    )
    const bp = createClient(baseConfig)
    const sug = await bp.getAssetSearchSuggestions('ca', { limit: 5 })

    // prefix rides as `q`; the buckets unwrap from `result`.
    const url = new URL(seenUrl)
    expect(url.searchParams.get('q')).toBe('ca')
    expect(url.searchParams.get('limit')).toBe('5')
    expect(sug.recent[0]?.query).toBe('cat')
    expect(sug.popular[0]?.count).toBe(40)
    expect(sug.nohits).toEqual([])
  })

  it('getAssetSearchSuggestions omits q when no prefix and defaults missing buckets', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/media/:ds/search/suggestions`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ result: { popular: [{ query: 'dog' }] } })
      }),
    )
    const bp = createClient(baseConfig)
    // No prefix → no `q` param (unfiltered top lists); missing buckets → [].
    const sug = await bp.getAssetSearchSuggestions()
    expect(new URL(seenUrl).searchParams.has('q')).toBe(false)
    expect(sug).toEqual({ recent: [], popular: [{ query: 'dog' }], nohits: [] })
  })
})

describe('listCollections / getCollection / getCollectionAssets', () => {
  const aCollection = {
    id: 'c1',
    title: 'Brand',
    kind: 'folder',
    shareEnabled: false,
    createdAt: 't',
    updatedAt: 't',
  }

  it('listCollections GETs /v1/media/:ds/collections with limit/offset and returns the page', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/media/:ds/collections`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({
          result: { collections: [aCollection], count: 3, limit: 2, offset: 1 },
        })
      }),
    )
    const bp = createClient(baseConfig)
    const page = await bp.listCollections({ limit: 2, offset: 1 })
    expect(page.collections).toHaveLength(1)
    expect(page.collections[0]!.id).toBe('c1')
    expect(page.count).toBe(3)
    const url = new URL(seenUrl)
    expect(url.pathname).toBe(`/v1/media/${TEST_DATASET}/collections`)
    expect(url.searchParams.get('limit')).toBe('2')
    expect(url.searchParams.get('offset')).toBe('1')
  })

  it('getCollection GETs .../collections/:id; returns null on 404', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/media/:ds/collections/c1`, () =>
        HttpResponse.json({ result: aCollection }),
      ),
      http.get(`${TEST_BASE_URL}/v1/media/:ds/collections/gone`, () =>
        HttpResponse.json(
          { error: { code: 'not_found', message: 'no collection' } },
          { status: 404 },
        ),
      ),
    )
    const bp = createClient(baseConfig)
    expect((await bp.getCollection('c1'))?.id).toBe('c1')
    expect(await bp.getCollection('gone')).toBeNull()
  })

  it('getCollectionAssets GETs .../collections/:id/assets and returns hits + total', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/media/:ds/collections/c1/assets`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({
          result: {
            collectionId: 'c1',
            hits: [{ _id: 'a1', url: 'https://cdn/a1.png' }],
            total: 12,
            limit: 5,
            offset: 0,
            facets: { kind: [] },
          },
        })
      }),
    )
    const bp = createClient(baseConfig)
    const res = await bp.getCollectionAssets('c1', { limit: 5 })
    expect(res.collectionId).toBe('c1')
    expect(res.hits[0]!._id).toBe('a1')
    expect(res.total).toBe(12)
    const url = new URL(seenUrl)
    expect(url.pathname).toBe(`/v1/media/${TEST_DATASET}/collections/c1/assets`)
    expect(url.searchParams.get('limit')).toBe('5')
  })
})

describe('addCollectionMember / removeCollectionMember', () => {
  it('addCollectionMember POSTs {assetId} to .../members and returns the asset', async () => {
    let seenUrl = ''
    let seenBody: unknown
    server.use(
      http.post(`${TEST_BASE_URL}/v1/media/:ds/collections/:id/members`, async ({ request }) => {
        seenUrl = request.url
        seenBody = await request.json()
        return HttpResponse.json({ result: { _id: 'a1', _type: 'sanity.imageAsset' } })
      }),
    )
    const asset = await createClient(baseConfig).addCollectionMember('c1', 'a1')
    expect(asset._id).toBe('a1')
    expect(new URL(seenUrl).pathname).toBe(`/v1/media/${TEST_DATASET}/collections/c1/members`)
    // assetId rides the BODY (camelCase), not the path.
    expect(seenBody).toEqual({ assetId: 'a1' })
  })

  it('removeCollectionMember DELETEs .../members/:assetId (id in the path)', async () => {
    let seenUrl = ''
    let seenMethod = ''
    server.use(
      http.delete(
        `${TEST_BASE_URL}/v1/media/:ds/collections/:id/members/:assetId`,
        ({ request }) => {
          seenUrl = request.url
          seenMethod = request.method
          return HttpResponse.json({ result: { _id: 'a1', _type: 'sanity.imageAsset' } })
        },
      ),
    )
    const asset = await createClient(baseConfig).removeCollectionMember('c1', 'a1')
    expect(asset._id).toBe('a1')
    expect(seenMethod).toBe('DELETE')
    expect(new URL(seenUrl).pathname).toBe(`/v1/media/${TEST_DATASET}/collections/c1/members/a1`)
  })
})

describe('shareCollection / revokeCollectionShare', () => {
  it('shareCollection POSTs (ttl in the body) and returns token/shareUrl/expiresAt', async () => {
    let seenUrl = ''
    let seenBody: unknown
    server.use(
      http.post(`${TEST_BASE_URL}/v1/media/:ds/collections/:id/share`, async ({ request }) => {
        seenUrl = request.url
        seenBody = await request.json()
        return HttpResponse.json({
          result: {
            token: 'tok-9',
            shareUrl: `/v1/media/${TEST_DATASET}/share/tok-9`,
            expiresAt: '2026-07-07T00:00:00Z',
          },
        })
      }),
    )
    const share = await createClient(baseConfig).shareCollection('c1', { ttl: 3600 })
    expect(share.token).toBe('tok-9')
    expect(share.shareUrl).toContain('/share/tok-9')
    expect(share.expiresAt).toBe('2026-07-07T00:00:00Z')
    expect(new URL(seenUrl).pathname).toBe(`/v1/media/${TEST_DATASET}/collections/c1/share`)
    expect(seenBody).toEqual({ ttl: 3600 })
  })

  it('shareCollection rejects a non-positive / non-integer ttl before hitting the network', async () => {
    const client = createClient(baseConfig)
    await expect(client.shareCollection('c1', { ttl: -5 })).rejects.toBeInstanceOf(
      BarkparkValidationError,
    )
    await expect(client.shareCollection('c1', { ttl: 1.5 })).rejects.toBeInstanceOf(
      BarkparkValidationError,
    )
    await expect(client.shareCollection('c1', { ttl: NaN })).rejects.toBeInstanceOf(
      BarkparkValidationError,
    )
  })

  it('revokeCollectionShare DELETEs the share path', async () => {
    let seenUrl = ''
    let seenMethod = ''
    server.use(
      http.delete(`${TEST_BASE_URL}/v1/media/:ds/collections/:id/share`, ({ request }) => {
        seenUrl = request.url
        seenMethod = request.method
        return HttpResponse.json({ result: { revoked: 'c1' } })
      }),
    )
    await createClient(baseConfig).revokeCollectionShare('c1')
    expect(seenMethod).toBe('DELETE')
    expect(new URL(seenUrl).pathname).toBe(`/v1/media/${TEST_DATASET}/collections/c1/share`)
  })
})

describe('empty-id guard', () => {
  // Every write (and non-null-returning read) op must reject an empty id
  // client-side rather than encodeURIComponent('') collapsing the path (e.g.
  // `//checkout`) and the server answering with an opaque 404/405. A `wire` flag
  // fed by a catch-all handler proves nothing hit the network.
  let wire: string[]
  beforeAll(() => {
    server.use(
      http.all(`${TEST_BASE_URL}/*`, ({ request }) => {
        wire.push(request.url)
        return HttpResponse.json({ result: {} })
      }),
    )
  })
  afterEach(() => {
    wire = []
  })

  it('rejects an empty id and makes no HTTP request', async () => {
    wire = []
    const bp = createClient(baseConfig)
    const calls: Array<Promise<unknown>> = [
      bp.getAsset(''),
      bp.getCollection(''),
      bp.updateAsset('', { alt: 'x' }),
      bp.deleteAsset(''),
      bp.checkoutAsset(''),
      bp.undoCheckoutAsset(''),
      bp.getAssetRelations(''),
      bp.getCollectionAssets(''),
      bp.shareCollection(''),
      bp.revokeCollectionShare(''),
      bp.addCollectionMember('', 'a1'),
      bp.removeCollectionMember('', 'a1'),
    ]
    for (const call of calls) {
      await expect(call).rejects.toBeInstanceOf(BarkparkValidationError)
    }
    expect(wire).toEqual([])
  })

  it('addCollectionMember / removeCollectionMember reject an empty assetId too', async () => {
    wire = []
    const bp = createClient(baseConfig)
    await expect(bp.addCollectionMember('c1', '')).rejects.toBeInstanceOf(BarkparkValidationError)
    await expect(bp.removeCollectionMember('c1', '')).rejects.toBeInstanceOf(BarkparkValidationError)
    expect(wire).toEqual([])
  })
})
