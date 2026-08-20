import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createClient } from '../src/client'
import { normalizeTags } from '../src/tags'
import type { BarkparkClientConfig } from '../src/types'

const baseConfig: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
  token: 'tok',
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('listTags', () => {
  it('GETs /v1/data/tags/:ds and returns the {tags, count} registry', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/tags/:ds`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({
          result: {
            tags: [
              { tag: 'search', counts: { paper: 12, task: 3 }, total: 15 },
              { tag: 'sdk', counts: { paper: 4 }, total: 4 },
            ],
            count: 2,
          },
          syncTags: [`bp:ds:${TEST_DATASET}:tags`],
        })
      }),
    )
    const bp = createClient(baseConfig)
    const res = await bp.listTags()
    expect(res.count).toBe(2)
    expect(res.tags[0]!.tag).toBe('search')
    expect(res.tags[0]!.counts.paper).toBe(12)
    expect(res.tags[0]!.total).toBe(15)
    expect(new URL(seenUrl).pathname).toBe(`/v1/data/tags/${TEST_DATASET}`)
  })

  it('passes types as a comma-joined query param', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/tags/:ds`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ result: { tags: [], count: 0 } })
      }),
    )
    const bp = createClient(baseConfig)
    await bp.listTags({ types: ['paper', 'task'] })
    expect(new URL(seenUrl).searchParams.get('type')).toBe('paper,task')
  })

  it('rejects a type entry containing a comma (fail closed)', async () => {
    const bp = createClient(baseConfig)
    await expect(bp.listTags({ types: ['a,b'] })).rejects.toMatchObject({
      code: 'BarkparkValidationError',
    })
  })
})

describe('getTagDocs', () => {
  it('GETs /v1/data/tags/:ds/:tag and returns the {tag, documents, count} result', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/tags/:ds/:tag`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({
          result: {
            tag: 'search',
            documents: [
              {
                doc_id: 'p1',
                type: 'paper',
                title: 'Search FTS',
                strength: 90,
                rationale: 'core topic',
                main_tag_match: true,
              },
              {
                doc_id: 'p2',
                type: 'paper',
                title: 'Legacy',
                strength: null,
                rationale: null,
                main_tag_match: false,
              },
            ],
            count: 2,
          },
          syncTags: [`bp:ds:${TEST_DATASET}:tags:search`],
        })
      }),
    )
    const bp = createClient(baseConfig)
    const res = await bp.getTagDocs('search')
    expect(res.tag).toBe('search')
    expect(res.count).toBe(2)
    expect(res.documents[0]!.strength).toBe(90)
    expect(res.documents[0]!.main_tag_match).toBe(true)
    expect(res.documents[1]!.strength).toBeNull()
    expect(new URL(seenUrl).pathname).toBe(`/v1/data/tags/${TEST_DATASET}/search`)
  })

  it('encodes the tag in the path and passes types', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/tags/:ds/:tag`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ result: { tag: 'a/b', documents: [], count: 0 } })
      }),
    )
    const bp = createClient(baseConfig)
    await bp.getTagDocs('a/b', { types: ['paper'] })
    const url = new URL(seenUrl)
    expect(url.pathname).toBe(`/v1/data/tags/${TEST_DATASET}/a%2Fb`)
    expect(url.searchParams.get('type')).toBe('paper')
  })

  it('throws BarkparkValidationError for an empty tag (no network call)', async () => {
    const bp = createClient(baseConfig)
    await expect(bp.getTagDocs('')).rejects.toMatchObject({
      code: 'BarkparkValidationError',
      field: 'tag',
    })
  })
})

describe('normalizeTags', () => {
  it('collapses weighted objects into names + entries', () => {
    const { names, entries } = normalizeTags([
      { tag: 'search', strength: 80, rationale: 'topic' },
      { tag: 'sdk', strength: 40 },
    ])
    expect(names).toEqual(['search', 'sdk'])
    expect(entries[0]).toEqual({ tag: 'search', strength: 80, rationale: 'topic' })
    expect(entries[1]).toEqual({ tag: 'sdk', strength: 40 })
  })

  it('lifts legacy flat strings into { tag } entries', () => {
    const { names, entries } = normalizeTags(['news', 'release'])
    expect(names).toEqual(['news', 'release'])
    expect(entries).toEqual([{ tag: 'news' }, { tag: 'release' }])
  })

  it('handles a mixed dual-shape array', () => {
    const { names, entries } = normalizeTags(['news', { tag: 'search', strength: 80 }])
    expect(names).toEqual(['news', 'search'])
    expect(entries).toEqual([{ tag: 'news' }, { tag: 'search', strength: 80 }])
  })

  it('skips malformed entries and never throws on non-array input', () => {
    expect(normalizeTags(null)).toEqual({ names: [], entries: [] })
    expect(normalizeTags(undefined)).toEqual({ names: [], entries: [] })
    expect(normalizeTags('nope')).toEqual({ names: [], entries: [] })
    const { names } = normalizeTags(['', { strength: 5 }, { tag: '' }, 42, { tag: 'ok' }])
    expect(names).toEqual(['ok'])
  })
})
