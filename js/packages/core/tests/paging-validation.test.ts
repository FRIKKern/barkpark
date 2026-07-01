import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET } from './fixtures/handlers'
import { BarkparkValidationError } from '../src/errors'
import { searchDocuments } from '../src/search'
import {
  listAssets,
  searchAssets,
  getAssetSearchSuggestions,
  listCollections,
  getCollectionAssets,
} from '../src/media'
import type { BarkparkClientConfig } from '../src/types'

const baseConfig: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
}

// Each ad-hoc read builder that ships limit/offset on a raw query string. The
// invoker takes paging opts so one table drives every throw/no-throw assertion.
const entrypoints: Array<{
  name: string
  // `hasOffset` is false for the suggestions builder, which paginates by `limit`
  // only (no `offset` param) — so the offset guard doesn't apply to it.
  hasOffset: boolean
  call: (opts: { limit?: number; offset?: number }) => Promise<unknown>
}> = [
  { name: 'searchDocuments', hasOffset: true, call: (o) => searchDocuments(baseConfig, 'q', o) },
  { name: 'listAssets', hasOffset: true, call: (o) => listAssets(baseConfig, o) },
  { name: 'searchAssets', hasOffset: true, call: (o) => searchAssets(baseConfig, 'q', o) },
  {
    name: 'getAssetSearchSuggestions',
    hasOffset: false,
    call: (o) =>
      getAssetSearchSuggestions(
        baseConfig,
        'pre',
        o.limit === undefined ? {} : { limit: o.limit },
      ),
  },
  { name: 'listCollections', hasOffset: true, call: (o) => listCollections(baseConfig, o) },
  {
    name: 'getCollectionAssets',
    hasOffset: true,
    call: (o) => getCollectionAssets(baseConfig, 'col1', o),
  },
]

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => server.resetHandlers())
afterAll(() => server.close())

describe('paging validation (assertPaging)', () => {
  for (const { name, hasOffset, call } of entrypoints) {
    describe(name, () => {
      it.runIf(hasOffset)('rejects offset:-1 with BarkparkValidationError', async () => {
        await expect(call({ offset: -1 })).rejects.toBeInstanceOf(BarkparkValidationError)
      })

      it('rejects limit:0 with BarkparkValidationError', async () => {
        await expect(call({ limit: 0 })).rejects.toBeInstanceOf(BarkparkValidationError)
      })

      it('rejects limit:NaN with BarkparkValidationError', async () => {
        await expect(call({ limit: Number.NaN })).rejects.toBeInstanceOf(BarkparkValidationError)
      })
    })
  }

  it('does NOT throw for valid paging or when limit/offset are omitted', async () => {
    // Stub every read endpoint with a permissive 200 so a valid call resolves —
    // the point is that assertPaging let it through, not the response shape.
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/search/:ds`, () => HttpResponse.json({})),
      http.get(`${TEST_BASE_URL}/v1/media/:ds`, () => HttpResponse.json({})),
      http.get(`${TEST_BASE_URL}/v1/media/:ds/search`, () => HttpResponse.json({ result: {} })),
      http.get(`${TEST_BASE_URL}/v1/media/:ds/search/suggestions`, () =>
        HttpResponse.json({ result: {} }),
      ),
      http.get(`${TEST_BASE_URL}/v1/media/:ds/collections`, () => HttpResponse.json({})),
      http.get(`${TEST_BASE_URL}/v1/media/:ds/collections/:id/assets`, () =>
        HttpResponse.json({}),
      ),
    )

    for (const { name, call } of entrypoints) {
      await expect(call({ limit: 5000, offset: 100 }), `${name} valid paging`).resolves.toBeDefined()
      await expect(call({}), `${name} omitted paging`).resolves.toBeDefined()
    }
  })
})
