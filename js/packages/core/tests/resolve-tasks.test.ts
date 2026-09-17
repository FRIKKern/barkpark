/**
 * `?resolve=tasks` — the OPT-IN server block-resolution seam, through core.
 *
 * WHY THIS EXISTS (task-d54c8a595e68ad5d). The API has honoured
 * `?resolve=tasks` since p-resolve-seam (`query_controller.ex`,
 * `maybe_resolve_tasks/3`): it swaps every query-shaped PortableDoc task block
 * for a live snapshot. Nothing in `js/` or `web/` had a way to SEND it, so
 * every query-shaped task block reached a renderer with no rows — and
 * `@barkpark/react`'s task-board reads `snapshot` only, so it drew the
 * `bp-tasks--empty` placeholder permanently. Not a staleness bug: the data
 * never arrived.
 *
 * Each test below pairs an ARM with a CONTROL on the same read, because the
 * failure mode here is a param that is always sent (breaking every other
 * consumer's default) just as much as one that is never sent.
 *
 * NAMED MUTANTS each test kills:
 *   • drop `qp.set('resolve', …)` from doc.ts        → "doc read carries it"
 *   • drop the `parts.push('resolve=…')` in docs.ts  → "query read carries it"
 *   • send it unconditionally (ignore `opts`)        → both CONTROL tests
 *   • send the wrong value / drop the encoding       → the exact-value asserts
 *   • un-export ResolveSpec / drop it from the opts  → this file stops compiling
 */
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { getDoc } from '../src/doc'
import { createClient } from '../src/client'
import type { BarkparkClientConfig } from '../src/types'
// From the PUBLIC entry: un-export ResolveSpec, or drop `resolve` from either
// options interface, and this import/assignment fails tsc. Export-completeness guard.
import type { GetDocOptions, DocsOperationOptions, ResolveSpec } from '../src/index'

const _resolve: ResolveSpec = 'tasks'
const _docOpts: GetDocOptions = { resolve: 'tasks' }
const _docsOpts: DocsOperationOptions = { resolve: 'tasks' }
void _resolve
void _docOpts
void _docsOpts

const baseConfig: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
}

/** A task block the author wrote as a QUERY — the shape the server fills. */
const QUERY_BLOCK = { type: 'task-board', query: { parent_id: 'epic-1' } }
/** What `?resolve=tasks` hands back instead: the same block, snapshot-filled. */
const RESOLVED_BLOCK = {
  type: 'task-board',
  snapshot: [{ doc_id: 'task-1', title: 'A live row' }],
}

/**
 * One handler for BOTH routes. It records every URL it sees AND answers
 * DIFFERENTLY depending on the param, the way the real controller does — so a
 * test can assert on the consumed document, not only on the request line.
 */
function captureRoute(path: string): { urls: URL[] } {
  const urls: URL[] = []
  server.use(
    http.get(`${TEST_BASE_URL}${path}`, ({ request }) => {
      const url = new URL(request.url)
      urls.push(url)
      const blocks = url.searchParams.get('resolve') === 'tasks' ? [RESOLVED_BLOCK] : [QUERY_BLOCK]
      const document = { _id: 'pd1', _type: 'paper', slug: 'plan', content: { blocks } }
      return HttpResponse.json(
        path.includes('/query/')
          ? {
              result: {
                perspective: 'published',
                documents: [document],
                count: 1,
                limit: 1,
                offset: 0,
              },
            }
          : { result: document, etag: 'rev-1' },
      )
    }),
  )
  return { urls }
}

const DOC_ROUTE = '/v1/data/doc/:ds/:type/:id'
const QUERY_ROUTE = '/v1/data/query/:ds/:type'

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('resolve: tasks — single-document read (GET /v1/data/doc)', () => {
  it('ARM: the param reaches the request URL, and the resolved blocks come back', async () => {
    const { urls } = captureRoute(DOC_ROUTE)
    const res = await getDoc<{ content: { blocks: unknown[] } }>(baseConfig, 'paper', 'pd1', {
      resolve: 'tasks',
    })
    expect(urls).toHaveLength(1)
    expect(urls[0]!.searchParams.get('resolve')).toBe('tasks')
    expect(res.data?.content.blocks).toEqual([RESOLVED_BLOCK])
  })

  it('CONTROL: omitting it sends NO resolve param at all', async () => {
    const { urls } = captureRoute(DOC_ROUTE)
    const res = await getDoc<{ content: { blocks: unknown[] } }>(baseConfig, 'paper', 'pd1')
    expect(urls[0]!.searchParams.has('resolve')).toBe(false)
    expect(res.data?.content.blocks).toEqual([QUERY_BLOCK])
  })

  it('rides beside the other shaping params rather than replacing them', async () => {
    const { urls } = captureRoute(DOC_ROUTE)
    await getDoc(baseConfig, 'paper', 'pd1', {
      resolve: 'tasks',
      perspective: 'drafts',
      fields: ['title', 'content'],
    })
    const qp = urls[0]!.searchParams
    expect(qp.get('resolve')).toBe('tasks')
    expect(qp.get('perspective')).toBe('drafts')
    expect(qp.get('fields')).toBe('title,content')
  })

  it('client.doc() threads it through (the seam app code actually calls)', async () => {
    const { urls } = captureRoute(DOC_ROUTE)
    const bp = createClient(baseConfig)
    await bp.doc('paper', 'pd1', { resolve: 'tasks' })
    expect(urls[0]!.searchParams.get('resolve')).toBe('tasks')
  })
})

describe('resolve: tasks — list query (GET /v1/data/query)', () => {
  it('ARM: client.docs(type, { resolve }) puts it on every page this builder reads', async () => {
    const { urls } = captureRoute(QUERY_ROUTE)
    const bp = createClient(baseConfig)
    const doc = await bp
      .docs<{ content: { blocks: unknown[] } }>('paper', { resolve: 'tasks' })
      .where('slug', 'eq', 'plan')
      .findOne()
    expect(urls).toHaveLength(1)
    const qp = urls[0]!.searchParams
    expect(qp.get('resolve')).toBe('tasks')
    // the filter is still there — resolve is additive, not a replacement
    expect(urls[0]!.search).toContain('filter')
    expect(doc?.content.blocks).toEqual([RESOLVED_BLOCK])
  })

  it('CONTROL: a builder without it sends NO resolve param', async () => {
    const { urls } = captureRoute(QUERY_ROUTE)
    const bp = createClient(baseConfig)
    const doc = await bp
      .docs<{ content: { blocks: unknown[] } }>('paper')
      .where('slug', 'eq', 'plan')
      .findOne()
    expect(urls[0]!.searchParams.has('resolve')).toBe(false)
    expect(doc?.content.blocks).toEqual([QUERY_BLOCK])
  })

  it('survives the count and page executors too, not just find()', async () => {
    const { urls } = captureRoute(QUERY_ROUTE)
    const bp = createClient(baseConfig)
    await bp.docs('paper', { resolve: 'tasks' }).limit(5).findPage()
    expect(urls[0]!.searchParams.get('resolve')).toBe('tasks')
    expect(urls[0]!.searchParams.get('count')).toBe('true')
  })
})
