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
