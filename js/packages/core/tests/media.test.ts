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
})
