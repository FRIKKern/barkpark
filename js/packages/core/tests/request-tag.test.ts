import { describe, it, expect, vi } from 'vitest'
import { createClient } from '../src/client'

function captureFetch() {
  const seen: Array<Record<string, string>> = []
  const fetch = vi.fn(async (_url: string, init: { headers?: Record<string, string> }) => {
    seen.push({ ...(init.headers ?? {}) })
    return new Response(JSON.stringify({ result: { _id: 'p1', _type: 'post' } }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    })
  })
  return { seen, fetch }
}

function client(extra: Record<string, unknown>, fetch: unknown) {
  return createClient({
    projectUrl: 'https://api.test',
    dataset: 'production',
    apiVersion: '2026-04-01',
    fetch,
    ...extra,
  } as never)
}

describe('X-Barkpark-Request-Tag (observability)', () => {
  it('defaults to a bp-prefixed tag on every request', async () => {
    const { seen, fetch } = captureFetch()
    await client({}, fetch).doc('post', 'p1')
    expect(seen[0]?.['X-Barkpark-Request-Tag']).toMatch(/^bp-/)
  })

  it('uses a custom prefix when configured', async () => {
    const { seen, fetch } = captureFetch()
    await client({ requestTagPrefix: 'acme' }, fetch).doc('post', 'p1')
    expect(seen[0]?.['X-Barkpark-Request-Tag']).toMatch(/^acme-/)
  })

  it('omits the tag when requestTagPrefix is set to empty (opt out)', async () => {
    const { seen, fetch } = captureFetch()
    await client({ requestTagPrefix: '' }, fetch).doc('post', 'p1')
    expect(seen[0]?.['X-Barkpark-Request-Tag']).toBeUndefined()
  })
})
