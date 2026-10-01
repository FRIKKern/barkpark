import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createDocsOperation } from '../src/docs'
import type { BarkparkClientConfig } from '../src/types'

// docs(type).find() promised "all matches" and resolved one 100-row page with
// nothing said: a type with 131 documents came back as 100 (stranger walk,
// 2026-10-01). A find() without .limit() whose response says hasMore now warns
// once per type with the two ways past the page.

const config: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
}

function serve(hasMore: boolean): void {
  server.use(
    http.get(`${TEST_BASE_URL}/v1/data/query/:dataset/:type`, () =>
      HttpResponse.json({
        result: {
          perspective: 'published',
          documents: [{ _id: 'w1', _type: 'widget' }],
          count: 1,
          limit: 100,
          offset: 0,
          hasMore,
        },
      }),
    ),
  )
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
  vi.restoreAllMocks()
})
afterAll(() => server.close())

describe('find() says when it left documents behind', () => {
  it('warns once per type when the page is truncated and no limit was set', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    serve(true)
    const docs = await createDocsOperation(config, 'gadgetA').find()
    await createDocsOperation(config, 'gadgetA').find()
    expect(docs).toHaveLength(1)
    expect(warn).toHaveBeenCalledTimes(1)
    expect(String(warn.mock.calls[0]![0])).toContain(`docs('gadgetA').find() returned one page`)
    expect(String(warn.mock.calls[0]![0])).toContain('.findPage()')
  })

  it('stays quiet when the page is complete', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    serve(false)
    await createDocsOperation(config, 'gadgetB').find()
    expect(warn).not.toHaveBeenCalled()
  })

  it('stays quiet when the caller chose a limit', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    serve(true)
    await createDocsOperation(config, 'gadgetC').limit(10).find()
    expect(warn).not.toHaveBeenCalled()
  })
})
