// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Block-op writes: applyDocOp, publishPaper, applyPaperOps, proposePaperEdits.
// Each test pins the request the server sees (path, body, headers) and how a
// refusal maps onto the typed errors. The 412 cases use the server's real
// envelopes: DocumentOpsController answers `details.{expected,actual}`; the
// Bulldocs batch route answers a bare `precondition_failed`.

import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createClient } from '../src/client'
import { BarkparkConflictError, BarkparkValidationError, isBarkparkError } from '../src/errors'
import type { BarkparkClientConfig, PaperOp } from '../src/types'

const baseConfig: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
  token: 'tok',
}
const scoped: BarkparkClientConfig = { ...baseConfig, workspace: 'acme', project: 'blog' }

const append: PaperOp = {
  op: 'append-block',
  block: { type: 'paragraph', content: [{ type: 'text', value: 'second' }] },
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

type Seen = { url: string; body: Record<string, unknown>; headers: Headers }

function capture(method: 'post', path: string, reply: Record<string, unknown>, status = 200) {
  const seen: Seen[] = []
  server.use(
    http[method](`${TEST_BASE_URL}${path}`, async ({ request }) => {
      seen.push({
        url: request.url,
        body: (await request.json()) as Record<string, unknown>,
        headers: request.headers,
      })
      return HttpResponse.json(reply, { status })
    }),
  )
  return seen
}

describe('applyDocOp', () => {
  it('POSTs {op, ifRev} to the flat doc ops route and returns the result', async () => {
    const seen = capture('post', '/v1/data/doc/:ds/:type/:id/ops', {
      result: { op_kind: 'append-block', block_id: 'b2', written_doc_id: 'drafts.p1', rev: 'r2' },
    })
    const res = await createClient(baseConfig).applyDocOp('post', 'p1', append, 'r1')

    expect(new URL(seen[0]!.url).pathname).toBe(`/v1/data/doc/${TEST_DATASET}/post/p1/ops`)
    expect(seen[0]!.body).toEqual({ op: append, ifRev: 'r1' })
    expect(seen[0]!.headers.get('authorization')).toBe('Bearer tok')
    expect(res.rev).toBe('r2')
    expect(res.written_doc_id).toBe('drafts.p1')
  })

  it('uses the /w/:ws/p/:proj route on a scoped client', async () => {
    const seen = capture('post', '/w/acme/p/blog/v1/data/doc/:ds/:type/:id/ops', {
      result: { op_kind: 'append-block', block_id: 'b2', written_doc_id: 'p1', rev: 'r2' },
    })
    await createClient(scoped).applyDocOp('post', 'p1', append, 'r1')
    expect(new URL(seen[0]!.url).pathname).toBe(`/w/acme/p/blog/v1/data/doc/${TEST_DATASET}/post/p1/ops`)
  })

  it('a stale ifRev throws BarkparkConflictError with status 412 and the current rev', async () => {
    capture(
      'post',
      '/v1/data/doc/:ds/:type/:id/ops',
      {
        error: {
          code: 'precondition_failed',
          message: 'document revision mismatch',
          details: { expected: 'r1', actual: 'r9' },
        },
      },
      412,
    )
    const err = await createClient(baseConfig)
      .applyDocOp('post', 'p1', append, 'r1')
      .catch((e: unknown) => e)

    expect(err).toBeInstanceOf(BarkparkConflictError)
    expect(isBarkparkError(err, 'BarkparkConflictError')).toBe(true)
    const c = err as BarkparkConflictError
    expect(c.status).toBe(412)
    expect(c.serverCode).toBe('precondition_failed')
    expect(c.serverDoc).toEqual({ rev: 'r9' })
  })

  it('forwards idempotencyKey as the Idempotency-Key header', async () => {
    const seen = capture('post', '/v1/data/doc/:ds/:type/:id/ops', {
      result: { op_kind: 'append-block', block_id: 'b2', written_doc_id: 'p1', rev: 'r2' },
    })
    await createClient(baseConfig).applyDocOp('post', 'p1', append, 'r1', { idempotencyKey: 'k-1' })
    expect(seen[0]!.headers.get('idempotency-key')).toBe('k-1')
  })

  it('refuses a relative-path segment before any request', async () => {
    // onUnhandledRequest: 'error' — reaching the network would fail differently.
    await expect(createClient(baseConfig).applyDocOp('post', '..', append, 'r1')).rejects.toBeInstanceOf(
      BarkparkValidationError,
    )
    await expect(createClient(baseConfig).applyDocOp('', 'p1', append, 'r1')).rejects.toBeInstanceOf(
      BarkparkValidationError,
    )
  })
})

describe('publishPaper', () => {
  it('POSTs the payload plus the client dataset and returns the receipt', async () => {
    const seen = capture('post', '/v1/plugins/bulldocs/papers', {
      ok: true,
      slug: 'notes',
      rev: '3',
      title: 'Notes',
      liveview_path: '/papers/notes',
      scoped_liveview_path: null,
    })
    const blocks = [{ id: 'h', type: 'heading', level: 1, text: 'Notes' }]
    const res = await createClient(baseConfig).publishPaper({ slug: 'notes', title: 'Notes', blocks })

    expect(seen[0]!.body).toEqual({ slug: 'notes', title: 'Notes', blocks, dataset: TEST_DATASET })
    expect(res.rev).toBe('3')
    expect(res.liveview_path).toBe('/papers/notes')
  })

  it('refuses a missing slug before any request', async () => {
    await expect(
      createClient(baseConfig).publishPaper({ slug: '', blocks: [] }),
    ).rejects.toBeInstanceOf(BarkparkValidationError)
  })
})

describe('applyPaperOps', () => {
  it('POSTs {ops, ifRev, dataset} and returns the integer rev', async () => {
    const seen = capture('post', '/v1/plugins/bulldocs/papers/:slug/ops', {
      ok: true,
      slug: 'notes',
      op_count: 1,
      rev: 8,
      block_ids: ['b2'],
    })
    const res = await createClient(baseConfig).applyPaperOps('notes', [append], { ifRev: 7 })

    expect(new URL(seen[0]!.url).pathname).toBe('/v1/plugins/bulldocs/papers/notes/ops')
    expect(seen[0]!.body).toEqual({ ops: [append], ifRev: 7, dataset: TEST_DATASET })
    expect(res).toEqual({ ok: true, slug: 'notes', op_count: 1, rev: 8, block_ids: ['b2'] })
  })

  it('omits ifRev when none is given', async () => {
    const seen = capture('post', '/v1/plugins/bulldocs/papers/:slug/ops', {
      ok: true,
      slug: 'notes',
      op_count: 1,
      rev: 8,
      block_ids: [],
    })
    await createClient(baseConfig).applyPaperOps('notes', [append])
    expect('ifRev' in seen[0]!.body).toBe(false)
  })

  it('names the workspace and project in headers on a scoped client', async () => {
    const seen = capture('post', '/v1/plugins/bulldocs/papers/:slug/ops', {
      ok: true,
      slug: 'notes',
      op_count: 1,
      rev: 8,
      block_ids: [],
    })
    await createClient(scoped).applyPaperOps('notes', [append], { ifRev: 7 })
    expect(seen[0]!.headers.get('x-barkpark-workspace')).toBe('acme')
    expect(seen[0]!.headers.get('x-barkpark-project')).toBe('blog')
  })

  it('sends no scope headers on a flat client', async () => {
    const seen = capture('post', '/v1/plugins/bulldocs/papers/:slug/ops', {
      ok: true,
      slug: 'notes',
      op_count: 1,
      rev: 8,
      block_ids: [],
    })
    await createClient(baseConfig).applyPaperOps('notes', [append])
    expect(seen[0]!.headers.get('x-barkpark-workspace')).toBeNull()
  })

  it('a stale ifRev throws BarkparkConflictError with status 412', async () => {
    capture(
      'post',
      '/v1/plugins/bulldocs/papers/:slug/ops',
      {
        error: {
          code: 'precondition_failed',
          message: "ifRev did not match the paper's current rev; no ops applied",
        },
      },
      412,
    )
    const err = await createClient(baseConfig)
      .applyPaperOps('notes', [append], { ifRev: 1 })
      .catch((e: unknown) => e)
    expect(err).toBeInstanceOf(BarkparkConflictError)
    expect((err as BarkparkConflictError).status).toBe(412)
    expect((err as BarkparkConflictError).serverCode).toBe('precondition_failed')
  })

  it('refuses a relative-path slug before any request', async () => {
    await expect(createClient(baseConfig).applyPaperOps('..', [append])).rejects.toBeInstanceOf(
      BarkparkValidationError,
    )
  })
})

describe('proposePaperEdits', () => {
  it('POSTs {ops, source, dataset} to the proposals route', async () => {
    const seen = capture('post', '/v1/plugins/bulldocs/papers/:slug/proposals', {
      ok: true,
      slug: 'notes',
      draft_id: 'drafts.notes',
      rev: 2,
      applied_block_ids: ['b2'],
      skipped_block_ids: [],
    })
    const proposal = { ops: [append], source: { doc_id: 'note-1', agent: 'barkdown' } }
    const res = await createClient(baseConfig).proposePaperEdits('notes', proposal)

    expect(new URL(seen[0]!.url).pathname).toBe('/v1/plugins/bulldocs/papers/notes/proposals')
    expect(seen[0]!.body).toEqual({ ...proposal, dataset: TEST_DATASET })
    expect(res.draft_id).toBe('drafts.notes')
    expect(res.applied_block_ids).toEqual(['b2'])
  })
})
