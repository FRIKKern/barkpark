import { describe, it, expect, vi } from 'vitest'

import { createPreloader, preloadDocument } from '../src/preload/index'
import type { PreloadableServer } from '../src/preload/index'

function makeServer(result: unknown = { _id: 'p1', _type: 'post' }): {
  server: PreloadableServer
  fetchSpy: ReturnType<typeof vi.fn>
} {
  const fetchSpy = vi.fn(async () => result)
  const server: PreloadableServer = { barkparkFetch: fetchSpy as PreloadableServer['barkparkFetch'] }
  return { server, fetchSpy }
}

describe('createPreloader', () => {
  it('dedupes two preloads + one load for the same id into one fetch', async () => {
    const { server, fetchSpy } = makeServer()
    const p = createPreloader(server)

    p.preloadDocument('p1', { type: 'post' })
    p.preloadDocument('p1', { type: 'post' })
    const doc = await p.loadDocument('p1', { type: 'post' })

    expect(fetchSpy).toHaveBeenCalledTimes(1)
    expect(doc).toEqual({ _id: 'p1', _type: 'post' })
  })

  it('fires separate fetches for different ids', async () => {
    const { server, fetchSpy } = makeServer()
    const p = createPreloader(server)

    p.preloadDocument('p1', { type: 'post' })
    p.preloadDocument('p2', { type: 'post' })
    await p.loadDocument('p1', { type: 'post' })
    await p.loadDocument('p2', { type: 'post' })

    expect(fetchSpy).toHaveBeenCalledTimes(2)
  })

  it('preloadDocument returns undefined (not a promise)', () => {
    const { server } = makeServer()
    const p = createPreloader(server)
    const out = p.preloadDocument('p1', { type: 'post' })
    expect(out).toBeUndefined()
  })

  it('loadDocument returns a promise resolving to the document', async () => {
    const { server } = makeServer({ _id: 'p9', title: 'Hello' })
    const p = createPreloader(server)
    const promise = p.loadDocument('p9', { type: 'post' })
    expect(promise).toBeInstanceOf(Promise)
    await expect(promise).resolves.toEqual({ _id: 'p9', title: 'Hello' })
  })

  it('different opts for the same id fire separate fetches', async () => {
    const { server, fetchSpy } = makeServer()
    const p = createPreloader(server)

    p.preloadDocument('p1', { type: 'post' })
    p.preloadDocument('p1', { type: 'post', perspective: 'drafts' })
    await p.loadDocument('p1', { type: 'post' })
    await p.loadDocument('p1', { type: 'post', perspective: 'drafts' })

    expect(fetchSpy).toHaveBeenCalledTimes(2)
  })

  it('forwards id into the barkparkFetch opts', async () => {
    const { server, fetchSpy } = makeServer()
    const p = createPreloader(server)
    await p.loadDocument('abc', { type: 'post' })
    expect(fetchSpy).toHaveBeenCalledWith({ type: 'post', id: 'abc' })
  })
})

describe('preloadDocument (top-level convenience)', () => {
  it('returns undefined and kicks off a fetch', () => {
    const { server, fetchSpy } = makeServer()
    const out = preloadDocument(server, 'p1', { type: 'post' })
    expect(out).toBeUndefined()
    expect(fetchSpy).toHaveBeenCalledTimes(1)
    expect(fetchSpy).toHaveBeenCalledWith({ type: 'post', id: 'p1' })
  })
})
