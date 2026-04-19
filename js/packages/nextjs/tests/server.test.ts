import { describe, it, expect, beforeEach, vi } from 'vitest'

const { draftModeMock } = vi.hoisted(() => ({
  draftModeMock: vi.fn(async () => ({ isEnabled: false })),
}))
vi.mock('next/headers', () => ({
  draftMode: draftModeMock,
}))

import { BarkparkAuthError } from '@barkpark/core'
import { barkparkFetch, createBarkparkServer, defineLive } from '../src/server/index'
import type { BarkparkServerConfig } from '../src/server/index'

interface FakeClient {
  config: { projectUrl: string; dataset: string; apiVersion: string }
}

function makeClient(): FakeClient {
  return {
    config: {
      projectUrl: 'http://localhost:4000',
      dataset: 'production',
      apiVersion: '2026-01-01',
    },
  }
}

function makeCfg(extra?: Partial<BarkparkServerConfig>): BarkparkServerConfig {
  // unsafe cast — test fake client supplies only what server core reads
  return {
    client: makeClient() as unknown as BarkparkServerConfig['client'],
    serverToken: 's-tok-123',
    ...extra,
  }
}

function jsonResponse(body: unknown, init?: ResponseInit): Response {
  return new Response(JSON.stringify(body), { status: 200, ...init })
}

function envelope<T>(result: T) {
  return { result, syncTags: [], ms: 1, etag: '"x"', schemaHash: 'h' }
}

beforeEach(() => {
  draftModeMock.mockReset()
  draftModeMock.mockResolvedValue({ isEnabled: false })
  vi.restoreAllMocks()
})

describe('barkparkFetch — published branch', () => {
  it('uses cache:force-cache and includes dataset + user tags', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      jsonResponse(envelope({ documents: [{ _id: 'p1' }] })),
    )

    const cfg = makeCfg()
    await barkparkFetch(cfg, { type: 'post', tags: ['custom-tag'] })

    expect(fetchSpy).toHaveBeenCalledOnce()
    const [url, init] = fetchSpy.mock.calls[0]!
    expect(typeof url).toBe('string')
    expect(url as string).toContain('/v1/data/query/production/post')
    expect(url as string).not.toContain('perspective=')

    const i = init as RequestInit & { cache?: RequestCache; next?: { tags?: string[]; revalidate?: number | false } }
    expect(i.cache).toBe('force-cache')
    expect(i.next?.tags).toEqual(['bp:ds:production:_all', 'bp:ds:production:type:post', 'custom-tag'])

    const headers = i.headers as Record<string, string>
    expect(headers.Authorization).toBeUndefined()
    expect(headers.Accept).toBe('application/vnd.barkpark+json')
  })

  it('omits perspective when caller did not supply one', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      jsonResponse(envelope({ documents: [] })),
    )
    await barkparkFetch(makeCfg(), { type: 'post' })
    const [url] = fetchSpy.mock.calls[0]!
    expect(url as string).not.toMatch(/perspective=/)
  })

  it('appends caller-provided perspective on the published branch', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      jsonResponse(envelope({ documents: [] })),
    )
    await barkparkFetch(makeCfg(), { type: 'post', perspective: 'raw' })
    const [url] = fetchSpy.mock.calls[0]!
    expect(url as string).toContain('perspective=raw')
  })
})

describe('barkparkFetch — draft branch', () => {
  beforeEach(() => {
    draftModeMock.mockResolvedValue({ isEnabled: true })
  })

  it('uses cache:no-store, sends Bearer serverToken, omits next.tags entirely', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      jsonResponse(envelope({ documents: [{ _id: 'drafts.p1' }] })),
    )
    const cfg = makeCfg()
    await barkparkFetch(cfg, { type: 'post', tags: ['x'] })

    const [url, init] = fetchSpy.mock.calls[0]!
    const i = init as RequestInit & { cache?: RequestCache; next?: { tags?: string[] } }
    expect(i.cache).toBe('no-store')
    expect(i.next).toBeUndefined()
    expect(url as string).toContain('perspective=drafts')
    const headers = i.headers as Record<string, string>
    expect(headers.Authorization).toBe('Bearer s-tok-123')
  })

  it('forces draft perspective even if caller passes a different one', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      jsonResponse(envelope({ documents: [] })),
    )
    await barkparkFetch(makeCfg(), { type: 'post', perspective: 'raw' })
    const [url] = fetchSpy.mock.calls[0]!
    expect(url as string).toContain('perspective=drafts')
    expect(url as string).not.toContain('perspective=raw')
  })

  it('on 401, retries once with reissuePreviewToken and succeeds', async () => {
    const reissue = vi.fn(async () => 'fresh-tok')
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(new Response('', { status: 401 }))
      .mockResolvedValueOnce(jsonResponse(envelope({ documents: [{ _id: 'p1' }] })))

    const cfg = makeCfg({ reissuePreviewToken: reissue })
    const out = await barkparkFetch<{ documents: Array<{ _id: string }> }>(cfg, { type: 'post' })

    expect(reissue).toHaveBeenCalledOnce()
    expect(fetchSpy).toHaveBeenCalledTimes(2)
    const secondInit = fetchSpy.mock.calls[1]![1] as RequestInit
    expect((secondInit.headers as Record<string, string>).Authorization).toBe('Bearer fresh-tok')
    expect(out.documents[0]!._id).toBe('p1')
  })

  it('on second 401 throws BarkparkAuthError', async () => {
    vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(new Response('', { status: 401 }))
      .mockResolvedValueOnce(new Response('', { status: 401 }))

    await expect(barkparkFetch(makeCfg(), { type: 'post' })).rejects.toBeInstanceOf(BarkparkAuthError)
  })

  it('without reissuePreviewToken hook, retries with same serverToken', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(new Response('', { status: 401 }))
      .mockResolvedValueOnce(jsonResponse(envelope({ documents: [] })))

    await barkparkFetch(makeCfg(), { type: 'post' })
    expect(fetchSpy).toHaveBeenCalledTimes(2)
    const secondInit = fetchSpy.mock.calls[1]![1] as RequestInit
    expect((secondInit.headers as Record<string, string>).Authorization).toBe('Bearer s-tok-123')
  })
})

describe('createBarkparkServer + defineLive', () => {
  it('createBarkparkServer returns barkparkFetch + defineLive (no Live components — those live on the client entry)', () => {
    const out = createBarkparkServer(makeCfg())
    expect(typeof out.barkparkFetch).toBe('function')
    expect(typeof out.defineLive).toBe('function')
    // BarkparkLive / BarkparkLiveProvider deliberately absent — import from
    // '@barkpark/nextjs/client' to stay outside the react-server graph.
    expect((out as Record<string, unknown>).BarkparkLive).toBeUndefined()
    expect((out as Record<string, unknown>).BarkparkLiveProvider).toBeUndefined()
  })

  it('barkparkFetch from createBarkparkServer behaves the same as defineLive(cfg).barkparkFetch', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async () =>
      jsonResponse(envelope({ documents: [] })),
    )
    const cfg = makeCfg()
    const top = createBarkparkServer(cfg)
    const inner = defineLive(cfg)
    await expect(top.barkparkFetch({ type: 'post' })).resolves.toEqual({ documents: [] })
    await expect(inner.barkparkFetch({ type: 'post' })).resolves.toEqual({ documents: [] })
  })
})
