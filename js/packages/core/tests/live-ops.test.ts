// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Block-op writes against a RUNNING Barkpark. Skipped unless
// BARKPARK_LIVE_URL is set, so CI (which has no server) stays green.
//
//   BARKPARK_LIVE_URL=http://localhost:4000 \
//   BARKPARK_LIVE_TOKEN=barkpark-dev-token \
//   pnpm vitest run -c vitest.config.ts tests/live-ops.test.ts
//
// Optional: BARKPARK_LIVE_DATASET (default `production`). The token needs
// write and admin tiers (the Bulldocs routes accept an admin api token). Every
// document the run creates carries a random suffix and is deleted afterwards.

import { afterAll, describe, expect, it } from 'vitest'
import { createClient } from '../src/client'
import { BarkparkConflictError } from '../src/errors'
import type { PaperOp } from '../src/types'

const url = process.env['BARKPARK_LIVE_URL']
const run = Math.random().toString(36).slice(2, 10)
const postId = `sdk-live-post-${run}`
const slug = `sdk-live-paper-${run}`

const para = (value: string): PaperOp => ({
  op: 'append-block',
  block: { type: 'paragraph', content: [{ type: 'text', value }] },
})

describe.skipIf(!url)('live: block ops, paper routes and media upload', () => {
  const bp = createClient({
    projectUrl: url ?? 'http://localhost:4000',
    dataset: process.env['BARKPARK_LIVE_DATASET'] ?? 'production',
    apiVersion: '2026-04-17',
    token: process.env['BARKPARK_LIVE_TOKEN'] ?? 'barkpark-dev-token',
  })
  const raw = bp.withConfig({ perspective: 'raw' })

  afterAll(async () => {
    await bp.delete(postId, 'post').catch(() => undefined)
    await bp.delete(slug, 'paper').catch(() => undefined)
  })

  it('applyDocOp edits a document and a stale ifRev throws a 412 conflict', async () => {
    await bp.createOrReplace({
      _id: postId,
      _type: 'post',
      title: 'SDK live op target',
      blocks: [{ id: 'p1', type: 'paragraph', content: [{ type: 'text', value: 'first' }] }],
    })
    const before = await raw.doc<{ _rev: string }>('post', `drafts.${postId}`)
    expect(before?._rev).toBeTruthy()

    const res = await bp.applyDocOp('post', postId, para('second'), before!._rev)
    expect(res.op_kind).toBe('append-block')
    expect(res.written_doc_id).toBe(`drafts.${postId}`)
    expect(res.rev).not.toBe(before!._rev)

    const err = await bp.applyDocOp('post', postId, para('third'), before!._rev).catch((e: unknown) => e)
    expect(err).toBeInstanceOf(BarkparkConflictError)
    expect((err as BarkparkConflictError).status).toBe(412)
    expect((err as BarkparkConflictError).serverCode).toBe('precondition_failed')
    expect((err as BarkparkConflictError).serverDoc).toEqual({ rev: res.rev })
  })

  it('publishPaper, applyPaperOps with ifRev, and proposePaperEdits round-trip', async () => {
    // The publish wall needs a registered tag; use whichever this instance has.
    const [tag] = await bp.docs<{ _id: string }>('tag').limit(1).find()
    expect(tag, 'the instance needs at least one registered tag').toBeTruthy()

    const published = await bp.publishPaper({
      slug,
      title: `SDK live paper ${run}`,
      description: `A throwaway paper the @barkpark/core live test publishes, edits and deletes (${run}).`,
      tags: [{ tag: tag!._id, strength: 50, rationale: 'SDK live test fixture' }],
      dedup_bypass: true,
      blocks: [
        { id: 'h', type: 'heading', level: 1, text: `SDK live paper ${run}` },
        para(`Run ${run} wrote this paragraph.`).block,
      ],
    })
    expect(published.slug).toBe(slug)
    const rev = Number(published.rev)
    expect(Number.isSafeInteger(rev)).toBe(true)

    const edited = await bp.applyPaperOps(slug, [para(`Run ${run} appended this.`)], { ifRev: rev })
    expect(edited.op_count).toBe(1)
    expect(edited.rev).toBeGreaterThan(rev)

    const stale = await bp
      .applyPaperOps(slug, [para('never written')], { ifRev: rev })
      .catch((e: unknown) => e)
    expect(stale).toBeInstanceOf(BarkparkConflictError)
    expect((stale as BarkparkConflictError).status).toBe(412)

    const proposal = await bp.proposePaperEdits(slug, {
      ops: [{ op: 'append-block', block: { id: `prop-${run}`, type: 'paragraph', content: [{ type: 'text', value: 'proposed' }] } }],
      source: { doc_id: postId, agent: 'sdk-live-test' },
    })
    expect(proposal.draft_id).toBe(`drafts.${slug}`)
    expect(proposal.applied_block_ids).toContain(`prop-${run}`)
  })

  it('uploadAsset returns the v1 shape: absoluteUrl and the asset document', async () => {
    // A 1x1 transparent PNG.
    const png = Uint8Array.from(
      atob(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
      ),
      (c) => c.charCodeAt(0),
    )
    const asset = await bp.uploadAsset(new Blob([png], { type: 'image/png' }), {
      filename: `sdk-live-${run}.png`,
    })
    expect(asset.id).toBeTruthy()
    expect(asset.absoluteUrl).toMatch(/^https?:\/\//)
    expect(asset.assetDocId).toBeTruthy()
    if (asset.id) await bp.deleteAsset(asset.id).catch(() => undefined)
  })
})
