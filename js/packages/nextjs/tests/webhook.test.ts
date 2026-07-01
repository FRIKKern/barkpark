// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { createHmac } from 'node:crypto'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import {
  __resetDedupForTests,
  createWebhookHandler,
  type WebhookPayload,
} from '../src/webhook/index'

const SECRET = 'whsec_primary_test_value'
const PREV_SECRET = 'whsec_previous_test_value'

function sign(secret: string, t: number, body: string): string {
  return createHmac('sha256', secret).update(`${t}.${body}`).digest('hex')
}

function makeRequest(opts: {
  body: string
  t?: number
  secret?: string
  sigOverride?: string
  deliveryHeader?: string | null
  method?: 'POST' | 'GET'
}): Request {
  const t = opts.t ?? Math.floor(Date.now() / 1000)
  const secret = opts.secret ?? SECRET
  const sig = opts.sigOverride ?? `t=${t},v1=${sign(secret, t, opts.body)}`
  const headers: Record<string, string> = {
    'x-barkpark-signature': sig,
    'content-type': 'application/json',
  }
  if (opts.deliveryHeader !== null && opts.deliveryHeader !== undefined) {
    headers['x-barkpark-delivery-id'] = opts.deliveryHeader
  }
  const init: RequestInit = { method: opts.method ?? 'POST', headers }
  if ((opts.method ?? 'POST') !== 'GET') init.body = opts.body
  return new Request('https://example.test/api/webhook', init)
}

describe('createWebhookHandler', () => {
  beforeEach(() => {
    __resetDedupForTests()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('accepts a valid signature and invokes onMutation', async () => {
    const onMutation = vi.fn(async (_p: WebhookPayload) => {})
    const { POST } = createWebhookHandler({ secret: SECRET, onMutation })

    const body = JSON.stringify({ event: 'create', documentId: 'p1' })
    const res = await POST(makeRequest({ body }))

    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ ok: true })
    expect(onMutation).toHaveBeenCalledTimes(1)
    expect(onMutation).toHaveBeenCalledWith({ event: 'create', documentId: 'p1' })
  })

  it('rejects an invalid signature with 401 and never calls onMutation', async () => {
    const onMutation = vi.fn()
    const { POST } = createWebhookHandler({ secret: SECRET, onMutation })

    const body = JSON.stringify({ event: 'create' })
    const t = Math.floor(Date.now() / 1000)
    // Same-length hex but wrong bytes.
    const wrong = sign('different-secret', t, body)
    const res = await POST(makeRequest({ body, t, sigOverride: `t=${t},v1=${wrong}` }))

    expect(res.status).toBe(401)
    expect(await res.json()).toEqual({ error: 'bad_signature' })
    expect(onMutation).not.toHaveBeenCalled()
  })

  it('rejects a stale timestamp (>5 min) with 401 stale', async () => {
    const onMutation = vi.fn()
    const { POST } = createWebhookHandler({ secret: SECRET, onMutation })

    const t = Math.floor(Date.now() / 1000) - 6 * 60 // 6 minutes ago
    const body = JSON.stringify({ event: 'create' })
    const res = await POST(makeRequest({ body, t }))

    expect(res.status).toBe(401)
    expect(await res.json()).toEqual({ error: 'stale' })
    expect(onMutation).not.toHaveBeenCalled()
  })

  it('accepts a signature under previousSecret during rotation', async () => {
    const onMutation = vi.fn()
    const { POST } = createWebhookHandler({
      secret: SECRET,
      previousSecret: PREV_SECRET,
      onMutation,
    })

    const body = JSON.stringify({ event: 'update' })
    const res = await POST(makeRequest({ body, secret: PREV_SECRET }))

    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ ok: true })
    expect(onMutation).toHaveBeenCalledTimes(1)
  })

  it('dedups repeat deliveryId via header (second call returns deduped:true)', async () => {
    const onMutation = vi.fn()
    const { POST } = createWebhookHandler({ secret: SECRET, onMutation })

    const body = JSON.stringify({ event: 'create' })
    const r1 = await POST(makeRequest({ body, deliveryHeader: 'dlv-1' }))
    const r2 = await POST(makeRequest({ body, deliveryHeader: 'dlv-1' }))

    expect(r1.status).toBe(200)
    expect(await r1.json()).toEqual({ ok: true })
    expect(r2.status).toBe(200)
    expect(await r2.json()).toEqual({ deduped: true })
    expect(onMutation).toHaveBeenCalledTimes(1)
  })

  it('falls back to body.deliveryId when header is absent', async () => {
    const onMutation = vi.fn()
    const { POST } = createWebhookHandler({ secret: SECRET, onMutation })

    const body = JSON.stringify({ event: 'create', deliveryId: 'body-dlv-1' })
    const r1 = await POST(makeRequest({ body }))
    const r2 = await POST(makeRequest({ body }))

    expect(r1.status).toBe(200)
    expect(await r2.json()).toEqual({ deduped: true })
    expect(onMutation).toHaveBeenCalledTimes(1)
  })

  it('returns 500 handler_failed when onMutation throws', async () => {
    const onMutation = vi.fn(() => {
      throw new Error('boom')
    })
    const { POST } = createWebhookHandler({ secret: SECRET, onMutation })

    const body = JSON.stringify({ event: 'create' })
    const res = await POST(makeRequest({ body }))

    expect(res.status).toBe(500)
    expect(await res.json()).toEqual({ error: 'handler_failed' })
    expect(onMutation).toHaveBeenCalledTimes(1)
  })

  it('rolls back dedup when onMutation throws, so a redelivery reprocesses', async () => {
    // First invocation throws (transient hiccup), second succeeds. Same
    // deliveryId across both. Without rollback, the retry short-circuits to
    // deduped:true and the mutation is dropped forever.
    const onMutation = vi
      .fn(async (_p: WebhookPayload) => {})
      .mockImplementationOnce(async () => {
        throw new Error('transient boom')
      })
    const { POST } = createWebhookHandler({ secret: SECRET, onMutation })

    const body = JSON.stringify({ event: 'create' })
    const r1 = await POST(makeRequest({ body, deliveryHeader: 'retry-dlv-1' }))
    expect(r1.status).toBe(500)
    expect(await r1.json()).toEqual({ error: 'handler_failed' })

    const r2 = await POST(makeRequest({ body, deliveryHeader: 'retry-dlv-1' }))
    expect(r2.status).toBe(200)
    expect(await r2.json()).toEqual({ ok: true })
    expect(onMutation).toHaveBeenCalledTimes(2)
  })

  it('GET returns 405 method_not_allowed', async () => {
    const onMutation = vi.fn()
    const { GET } = createWebhookHandler({ secret: SECRET, onMutation })

    const res = await GET(new Request('https://example.test/api/webhook'))

    expect(res.status).toBe(405)
    expect(await res.json()).toEqual({ error: 'method_not_allowed' })
    expect(onMutation).not.toHaveBeenCalled()
  })

  it('rejects when signature header is missing', async () => {
    const onMutation = vi.fn()
    const { POST } = createWebhookHandler({ secret: SECRET, onMutation })

    const req = new Request('https://example.test/api/webhook', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{}',
    })
    const res = await POST(req)

    expect(res.status).toBe(401)
    expect(await res.json()).toEqual({ error: 'bad_signature' })
  })

  it('rejects malformed JSON with 400 bad_request', async () => {
    const onMutation = vi.fn()
    const { POST } = createWebhookHandler({ secret: SECRET, onMutation })

    const body = '{not-json'
    const res = await POST(makeRequest({ body }))

    expect(res.status).toBe(400)
    expect(await res.json()).toEqual({ error: 'bad_request' })
    expect(onMutation).not.toHaveBeenCalled()
  })

  it('throws on construction with empty secret', () => {
    expect(() => createWebhookHandler({ secret: '', onMutation: () => {} } as never)).toThrow(
      /secret/,
    )
  })

  it('onMutation receives a TYPED WebhookEvent payload (not Record<string, unknown>)', async () => {
    let captured: { docId: string; tags: string[]; event: string } | null = null
    const onMutation = async (payload: WebhookPayload) => {
      // These typed assignments compile ONLY because WebhookPayload is core's
      // WebhookEvent (doc_id: string, sync_tags: string[], event: string). If it
      // were Record<string, unknown>, each would be `unknown` and fail tsc — so
      // this test is protective at the TYPE level (revert types.ts → tsc fails).
      const docId: string = payload.doc_id
      const tags: string[] = payload.sync_tags
      const event: string = payload.event
      captured = { docId, tags, event }
    }
    const { POST } = createWebhookHandler({ secret: SECRET, onMutation })

    const body = JSON.stringify({
      event: 'document.published',
      type: 'post',
      doc_id: 'p1',
      document: { _id: 'p1', _type: 'post' },
      dataset: 'production',
      workspace: null,
      project: null,
      workspace_id: null,
      project_id: null,
      sync_tags: ['bp:ds:production:doc:p1'],
      timestamp: '2026-06-30T00:00:00Z',
    })
    const res = await POST(makeRequest({ body }))

    expect(res.status).toBe(200)
    expect(captured).toEqual({
      docId: 'p1',
      tags: ['bp:ds:production:doc:p1'],
      event: 'document.published',
    })
  })
})
