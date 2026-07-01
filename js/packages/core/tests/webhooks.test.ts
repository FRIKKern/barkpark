import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createClient } from '../src/client'
import { BarkparkValidationError } from '../src/errors'
import type { BarkparkClientConfig } from '../src/types'

const baseConfig: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('webhook management', () => {
  it('listWebhooks GETs /v1/webhooks/:ds and unwraps { webhooks }', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/webhooks/:ds`, () =>
        HttpResponse.json({ webhooks: [{ id: 'wh1', name: 'ci', url: 'https://x/y' }] }),
      ),
    )
    const bp = createClient(baseConfig)
    const hooks = await bp.listWebhooks()
    expect(hooks[0]?.id).toBe('wh1')
  })

  it('getWebhook returns the single webhook, or null on 404', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/webhooks/:ds/wh1`, () =>
        HttpResponse.json({ webhook: { id: 'wh1', name: 'ci', url: 'https://x/y' } }),
      ),
      http.get(`${TEST_BASE_URL}/v1/webhooks/:ds/gone`, () =>
        HttpResponse.json({ code: 'not_found' }, { status: 404 }),
      ),
    )
    const bp = createClient(baseConfig)
    expect((await bp.getWebhook('wh1'))?.name).toBe('ci')
    expect(await bp.getWebhook('gone')).toBeNull()
  })

  it('createWebhook POSTs the body and returns the created webhook (secret not echoed)', async () => {
    let seenMethod = ''
    let seenBody: unknown
    server.use(
      http.post(`${TEST_BASE_URL}/v1/webhooks/:ds`, async ({ request }) => {
        seenMethod = request.method
        seenBody = await request.json()
        return HttpResponse.json(
          { webhook: { id: 'wh2', name: 'deploy', url: 'https://x/hook', events: ['publish'] } },
          { status: 201 },
        )
      }),
    )
    const bp = createClient(baseConfig)
    const wh = await bp.createWebhook({
      name: 'deploy',
      url: 'https://x/hook',
      events: ['publish'],
      secret: 's3cr3t',
    })

    expect(seenMethod).toBe('POST')
    // The full input (including the write-only secret) is sent as the JSON body.
    expect(seenBody).toEqual({
      name: 'deploy',
      url: 'https://x/hook',
      events: ['publish'],
      secret: 's3cr3t',
    })
    // The created webhook is unwrapped from { webhook }.
    expect(wh.id).toBe('wh2')
    expect(wh.secret).toBeUndefined()
  })

  it('updateWebhook PUTs the partial patch and returns the updated webhook', async () => {
    let seenMethod = ''
    let seenBody: unknown
    server.use(
      http.put(`${TEST_BASE_URL}/v1/webhooks/:ds/wh1`, async ({ request }) => {
        seenMethod = request.method
        seenBody = await request.json()
        return HttpResponse.json({ webhook: { id: 'wh1', name: 'ci', active: false } })
      }),
    )
    const bp = createClient(baseConfig)
    const wh = await bp.updateWebhook('wh1', { active: false })
    expect(seenMethod).toBe('PUT')
    expect(seenBody).toEqual({ active: false })
    expect(wh.active).toBe(false)
  })

  it('deleteWebhook DELETEs /v1/webhooks/:ds/:id and returns { deleted }', async () => {
    let seenMethod = ''
    server.use(
      http.delete(`${TEST_BASE_URL}/v1/webhooks/:ds/wh1`, ({ request }) => {
        seenMethod = request.method
        return HttpResponse.json({ deleted: 'wh1' })
      }),
    )
    const bp = createClient(baseConfig)
    const res = await bp.deleteWebhook('wh1')
    expect(seenMethod).toBe('DELETE')
    expect(res.deleted).toBe('wh1')
  })

  it('createWebhook fast-fails (no network) with a field-tagged error on empty name or url', async () => {
    // No handler registered: onUnhandledRequest:'error' would throw if these
    // reached the network, proving the guard short-circuits before the round-trip.
    const bp = createClient(baseConfig)
    await expect(
      bp.createWebhook({ name: '', url: 'https://x/hook' }),
    ).rejects.toBeInstanceOf(BarkparkValidationError)
    await expect(
      bp.createWebhook({ name: '', url: 'https://x/hook' }),
    ).rejects.toMatchObject({ field: 'name' })
    await expect(
      bp.createWebhook({ name: 'deploy', url: '' }),
    ).rejects.toBeInstanceOf(BarkparkValidationError)
    await expect(
      bp.createWebhook({ name: 'deploy', url: '' }),
    ).rejects.toMatchObject({ field: 'url' })
  })

  it('updateWebhook/deleteWebhook fast-fail (no network) with a field-tagged error on an empty id', async () => {
    // No handler registered: onUnhandledRequest:'error' would throw if these
    // reached the network, proving the guard short-circuits before the round-trip
    // (and never fires a PUT/DELETE at the collection route with a trailing empty segment).
    const bp = createClient(baseConfig)
    await expect(bp.updateWebhook('', { active: false })).rejects.toBeInstanceOf(
      BarkparkValidationError,
    )
    await expect(bp.updateWebhook('', { active: false })).rejects.toMatchObject({ field: 'id' })
    await expect(bp.deleteWebhook('')).rejects.toBeInstanceOf(BarkparkValidationError)
    await expect(bp.deleteWebhook('')).rejects.toMatchObject({ field: 'id' })
  })

  it('each webhook method threads an already-aborted signal into the request (rejects)', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/webhooks/:ds`, () => HttpResponse.json({ webhooks: [] })),
      http.get(`${TEST_BASE_URL}/v1/webhooks/:ds/wh1`, () =>
        HttpResponse.json({ webhook: { id: 'wh1', name: 'ci', url: 'https://x/y' } }),
      ),
      http.post(`${TEST_BASE_URL}/v1/webhooks/:ds`, () =>
        HttpResponse.json({ webhook: { id: 'wh2', name: 'deploy', url: 'https://x/hook' } }, { status: 201 }),
      ),
      http.put(`${TEST_BASE_URL}/v1/webhooks/:ds/wh1`, () =>
        HttpResponse.json({ webhook: { id: 'wh1', name: 'ci' } }),
      ),
      http.delete(`${TEST_BASE_URL}/v1/webhooks/:ds/wh1`, () => HttpResponse.json({ deleted: 'wh1' })),
    )
    const bp = createClient(baseConfig)
    const ac = new AbortController()
    ac.abort()
    // An already-aborted signal makes each call reject (signal is threaded to fetch).
    await expect(bp.listWebhooks({ signal: ac.signal })).rejects.toThrow()
    await expect(bp.getWebhook('wh1', { signal: ac.signal })).rejects.toThrow()
    await expect(
      bp.createWebhook({ name: 'deploy', url: 'https://x/hook' }, { signal: ac.signal }),
    ).rejects.toThrow()
    await expect(bp.updateWebhook('wh1', { active: false }, { signal: ac.signal })).rejects.toThrow()
    await expect(bp.deleteWebhook('wh1', { signal: ac.signal })).rejects.toThrow()
  })
})
