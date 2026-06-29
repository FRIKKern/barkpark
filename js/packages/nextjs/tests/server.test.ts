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
  config: {
    projectUrl: string
    dataset: string
    apiVersion: string
    workspace?: string
    project?: string
  }
}

function makeClient(scope?: { workspace?: string; project?: string }): FakeClient {
  return {
    config: {
      projectUrl: 'http://localhost:4000',
      dataset: 'production',
      apiVersion: '2026-01-01',
      ...(scope ?? {}),
    },
  }
}

function makeCfg(
  extra?: Partial<BarkparkServerConfig>,
  clientScope?: { workspace?: string; project?: string },
): BarkparkServerConfig {
  // unsafe cast — test fake client supplies only what server core reads
  return {
    client: makeClient(clientScope) as unknown as BarkparkServerConfig['client'],
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
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(jsonResponse(envelope({ documents: [{ _id: 'p1' }] })))

    const cfg = makeCfg()
    await barkparkFetch(cfg, { type: 'post', tags: ['custom-tag'] })

    expect(fetchSpy).toHaveBeenCalledOnce()
    const [url, init] = fetchSpy.mock.calls[0]!
    expect(typeof url).toBe('string')
    expect(url as string).toContain('/v1/data/query/production/post')
    expect(url as string).not.toContain('perspective=')

    const i = init as RequestInit & {
      cache?: RequestCache
      next?: { tags?: string[]; revalidate?: number | false }
    }
    expect(i.cache).toBe('force-cache')
    expect(i.next?.tags).toEqual([
      'bp:ds:production:_all',
      'bp:ds:production:type:post',
      'custom-tag',
    ])

    const headers = i.headers as Record<string, string>
    expect(headers.Authorization).toBeUndefined()
    expect(headers.Accept).toBe('application/vnd.barkpark+json')
  })

  it('omits perspective when caller did not supply one', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(jsonResponse(envelope({ documents: [] })))
    await barkparkFetch(makeCfg(), { type: 'post' })
    const [url] = fetchSpy.mock.calls[0]!
    expect(url as string).not.toMatch(/perspective=/)
  })

  it('appends caller-provided perspective on the published branch', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(jsonResponse(envelope({ documents: [] })))
    await barkparkFetch(makeCfg(), { type: 'post', perspective: 'raw' })
    const [url] = fetchSpy.mock.calls[0]!
    expect(url as string).toContain('perspective=raw')
  })

  it('single-doc fetch (id) supports expand + fields on the /doc URL', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(jsonResponse({ _id: 'p1', _type: 'post' }))
    await barkparkFetch(makeCfg(), {
      type: 'post',
      id: 'p1',
      expand: 'author',
      fields: ['title', 'slug'],
    })
    const [url] = fetchSpy.mock.calls[0]!
    const u = url as string
    expect(u).toContain('/v1/data/doc/production/post/p1')
    expect(u).toContain('expand=author')
    expect(decodeURIComponent(u)).toContain('fields=title,slug')
  })
})

describe('barkparkFetch — draft branch', () => {
  beforeEach(() => {
    draftModeMock.mockResolvedValue({ isEnabled: true })
  })

  it('uses cache:no-store, sends Bearer serverToken, omits next.tags entirely', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(jsonResponse(envelope({ documents: [{ _id: 'drafts.p1' }] })))
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
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(jsonResponse(envelope({ documents: [] })))
    await barkparkFetch(makeCfg(), { type: 'post', perspective: 'raw' })
    const [url] = fetchSpy.mock.calls[0]!
    expect(url as string).toContain('perspective=drafts')
    expect(url as string).not.toContain('perspective=raw')
  })

  it('on 401, retries once with reissuePreviewToken and succeeds', async () => {
    const reissue = vi.fn(async () => 'fresh-tok')
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(new Response('', { status: 401 }))
      .mockResolvedValueOnce(jsonResponse(envelope({ documents: [{ _id: 'p1' }] })))

    const cfg = makeCfg({ reissuePreviewToken: reissue })
    const out = await barkparkFetch<{ result: { documents: Array<{ _id: string }> } }>(cfg, {
      type: 'post',
    })

    expect(reissue).toHaveBeenCalledOnce()
    expect(fetchSpy).toHaveBeenCalledTimes(2)
    const secondInit = fetchSpy.mock.calls[1]![1] as RequestInit
    expect((secondInit.headers as Record<string, string>).Authorization).toBe('Bearer fresh-tok')
    // barkparkFetch returns the full Phoenix envelope; documents live under .result.
    expect(out.result.documents[0]!._id).toBe('p1')
  })

  it('on second 401 throws BarkparkAuthError', async () => {
    vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(new Response('', { status: 401 }))
      .mockResolvedValueOnce(new Response('', { status: 401 }))

    await expect(barkparkFetch(makeCfg(), { type: 'post' })).rejects.toBeInstanceOf(
      BarkparkAuthError,
    )
  })

  it('without reissuePreviewToken hook, retries with same serverToken', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(new Response('', { status: 401 }))
      .mockResolvedValueOnce(jsonResponse(envelope({ documents: [] })))

    await barkparkFetch(makeCfg(), { type: 'post' })
    expect(fetchSpy).toHaveBeenCalledTimes(2)
    const secondInit = fetchSpy.mock.calls[1]![1] as RequestInit
    expect((secondInit.headers as Record<string, string>).Authorization).toBe('Bearer s-tok-123')
  })
})

describe('barkparkFetch — workspace/project scoping', () => {
  it('flat /v1 routes when neither workspace nor project is configured (back-compat)', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(jsonResponse(envelope({ documents: [] })))
    await barkparkFetch(makeCfg(), { type: 'post' })
    const [url] = fetchSpy.mock.calls[0]!
    expect(url as string).toBe('http://localhost:4000/v1/data/query/production/post')
    expect(url as string).not.toContain('/w/')
  })

  it('flat /v1 routes when only workspace is set (both required)', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(jsonResponse(envelope({ documents: [] })))
    await barkparkFetch(makeCfg({ workspace: 'acme' }), { type: 'post' })
    const [url] = fetchSpy.mock.calls[0]!
    expect(url as string).not.toContain('/w/')
    expect(url as string).toContain('/v1/data/query/production/post')
  })

  it('scopes the query URL when workspace + project set on the server config', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(jsonResponse(envelope({ documents: [] })))
    await barkparkFetch(makeCfg({ workspace: 'acme', project: 'blog' }), { type: 'post' })
    const [url] = fetchSpy.mock.calls[0]!
    expect(url as string).toBe('http://localhost:4000/w/acme/p/blog/v1/data/query/production/post')
  })

  it('scopes the single-doc URL (id branch) and preserves perspective', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(jsonResponse(envelope({ documents: [{ _id: 'p1' }] })))
    await barkparkFetch(makeCfg({ workspace: 'acme', project: 'blog' }), {
      type: 'post',
      id: 'p1',
      perspective: 'raw',
    })
    const [url] = fetchSpy.mock.calls[0]!
    expect(url as string).toBe(
      'http://localhost:4000/w/acme/p/blog/v1/data/doc/production/post/p1?perspective=raw',
    )
  })

  it('inherits workspace/project from client.config when server config omits them', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(jsonResponse(envelope({ documents: [] })))
    await barkparkFetch(makeCfg(undefined, { workspace: 'acme', project: 'blog' }), {
      type: 'post',
    })
    const [url] = fetchSpy.mock.calls[0]!
    expect(url as string).toBe('http://localhost:4000/w/acme/p/blog/v1/data/query/production/post')
  })

  it('server config workspace/project override the client config values', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(jsonResponse(envelope({ documents: [] })))
    await barkparkFetch(
      makeCfg(
        { workspace: 'override-ws', project: 'override-pr' },
        { workspace: 'acme', project: 'blog' },
      ),
      { type: 'post' },
    )
    const [url] = fetchSpy.mock.calls[0]!
    expect(url as string).toBe(
      'http://localhost:4000/w/override-ws/p/override-pr/v1/data/query/production/post',
    )
  })
})

describe('barkparkFetch — cache-tag namespace (scoped vs flat)', () => {
  function nextTags(init: unknown): string[] {
    const i = init as RequestInit & { next?: { tags?: string[] } }
    return i.next?.tags ?? []
  }

  it('flat bp:ds:* tags when workspace+project NOT configured (back-compat)', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(jsonResponse(envelope({ documents: [{ _id: 'p1' }] })))
    await barkparkFetch(makeCfg(), { type: 'post', id: 'p1' })
    const tags = nextTags(fetchSpy.mock.calls[0]![1])
    expect(tags).toContain('bp:ds:production:_all')
    expect(tags).toContain('bp:ds:production:type:post')
    expect(tags).toContain('bp:ds:production:doc:p1')
    for (const t of tags) expect(t).not.toContain('bp:ws:')
  })

  it('scoped bp:ws:<ws>:p:<project>:ds:* tags when workspace+project set on server config', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(jsonResponse(envelope({ documents: [{ _id: 'p1' }] })))
    await barkparkFetch(makeCfg({ workspace: 'acme', project: 'blog' }), { type: 'post', id: 'p1' })
    const tags = nextTags(fetchSpy.mock.calls[0]![1])
    expect(tags).toContain('bp:ws:acme:p:blog:ds:production:_all')
    expect(tags).toContain('bp:ws:acme:p:blog:ds:production:type:post')
    expect(tags).toContain('bp:ws:acme:p:blog:ds:production:doc:p1')
    // The generated grammar MUST match what the s15 revalidate ingest parses.
    for (const t of tags) {
      if (t.startsWith('bp:'))
        expect(t).toMatch(/^bp:ws:acme:p:blog:ds:production:(?:_all|type:.+|doc:.+)$/)
    }
  })

  it('scoped tags inherited from client.config when server config omits scope', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(jsonResponse(envelope({ documents: [] })))
    await barkparkFetch(makeCfg(undefined, { workspace: 'acme', project: 'blog' }), {
      type: 'post',
    })
    const tags = nextTags(fetchSpy.mock.calls[0]![1])
    expect(tags).toContain('bp:ws:acme:p:blog:ds:production:_all')
    expect(tags).toContain('bp:ws:acme:p:blog:ds:production:type:post')
  })

  it('flat tags when only workspace is set (both required, mirrors scopePrefix)', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(jsonResponse(envelope({ documents: [] })))
    await barkparkFetch(makeCfg({ workspace: 'acme' }), { type: 'post' })
    const tags = nextTags(fetchSpy.mock.calls[0]![1])
    expect(tags).toContain('bp:ds:production:_all')
    for (const t of tags) expect(t).not.toContain('bp:ws:')
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
    // barkparkFetch returns the full Phoenix envelope, not the unwrapped result.
    const expected = envelope({ documents: [] })
    await expect(top.barkparkFetch({ type: 'post' })).resolves.toEqual(expected)
    await expect(inner.barkparkFetch({ type: 'post' })).resolves.toEqual(expected)
  })
})
