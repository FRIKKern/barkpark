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
  token: 't',
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('getAnalytics', () => {
  it('fetches + returns the dataset content-stats overview', async () => {
    let seenPath = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/analytics/:ds`, ({ request }) => {
        seenPath = new URL(request.url).pathname
        return HttpResponse.json({
          dataset: 'production',
          total_documents: 3,
          types: [{ type: 'post', total: 2, published: 1, drafts: 1 }],
          recent_activity: [{ type: 'post', doc_id: 'p1' }],
        })
      }),
    )
    const bp = createClient(baseConfig)
    const a = await bp.getAnalytics()
    expect(a.total_documents).toBe(3)
    expect(a.types[0]?.published).toBe(1)
    expect(a.types[0]?.drafts).toBe(1)
    expect(a.recent_activity).toHaveLength(1)
    expect(seenPath).toContain(`/v1/data/analytics/${TEST_DATASET}`)
  })

  it('propagates a server error', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/analytics/:ds`, () =>
        HttpResponse.json({ error: { code: 'unauthorized' } }, { status: 401 }),
      ),
    )
    const bp = createClient(baseConfig)
    await expect(bp.getAnalytics()).rejects.toThrow()
  })
})
