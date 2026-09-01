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

describe('preload rejection safety', () => {
  // preloadDocument is fire-and-forget: nothing awaits its promise. A rejecting
  // barkparkFetch (server down at preload time) must NOT surface as an
  // unhandledrejection — in Node's default configuration that CRASHES the
  // process, turning a warm-up optimization into an outage. The rejection must
  // still reach a caller who awaits loadDocument for the same key.
  it('a rejecting preloadDocument does not raise an unhandled rejection', async () => {
    const boom = new Error('preload-boom')
    // Plain functions, NOT vi.fn(): vitest mock instrumentation attaches its own
    // handlers to every returned promise (settled-result tracking), which
    // silently defuses the unhandledRejection detector this test exists to arm.
    let calls = 0
    const server: PreloadableServer = {
      barkparkFetch: (async () => {
        calls += 1
        throw boom
      }) as unknown as PreloadableServer['barkparkFetch'],
    }
    const p = createPreloader(server)

    const seen: unknown[] = []
    const onUR = (reason: unknown): void => {
      seen.push(reason)
    }
    process.on('unhandledRejection', onUR)
    try {
      p.preloadDocument('p1', { type: 'post' })
      // unhandledRejection fires on a later macrotask tick — give it two.
      await new Promise((r) => setImmediate(r))
      await new Promise((r) => setImmediate(r))
      expect(seen).toEqual([])
    } finally {
      process.off('unhandledRejection', onUR)
    }
    // The stored promise still carries the rejection for an awaiting caller.
    await expect(p.loadDocument('p1', { type: 'post' })).rejects.toBe(boom)
    expect(calls).toBe(1)
  })

  it('the one-shot preloadDocument export is also rejection-safe', async () => {
    // Plain function, not vi.fn() — see the detector note above.
    const server: PreloadableServer = {
      barkparkFetch: (async () => {
        throw new Error('one-shot-boom')
      }) as unknown as PreloadableServer['barkparkFetch'],
    }
    const seen: unknown[] = []
    const onUR = (reason: unknown): void => {
      seen.push(reason)
    }
    process.on('unhandledRejection', onUR)
    try {
      preloadDocument(server, 'p1', { type: 'post' })
      await new Promise((r) => setImmediate(r))
      await new Promise((r) => setImmediate(r))
      expect(seen).toEqual([])
    } finally {
      process.off('unhandledRejection', onUR)
    }
  })
})

describe('preload dedup key stability', () => {
  // The dedup key used to be `JSON.stringify([id, opts])`, which inherits two
  // faults from JSON.stringify:
  //   1. key ORDER — `{a,b}` and `{b,a}` are the same options bag but stringify
  //      differently, so an identical preload was NOT deduped (extra fetch);
  //   2. non-serializable values — an AbortSignal stringifies to `{}`, so two
  //      DIFFERENT signals produced the SAME key and were WRONGLY collapsed
  //      into one in-flight request.
  // Neither fault could return a wrong document BODY (the key is only ever
  // consulted for the tuple that produced it), but (2) hands a caller a promise
  // for a request governed by somebody else's signal.

  it('dedupes the same options bag written in a different key order', async () => {
    const { server, fetchSpy } = makeServer()
    const p = createPreloader(server)

    p.preloadDocument('p1', { type: 'post', perspective: 'drafts' })
    const doc = await p.loadDocument('p1', { perspective: 'drafts', type: 'post' })

    // Assert the subject is present: the fetch really happened with both fields,
    // so this cannot pass by the options going missing.
    expect(fetchSpy).toHaveBeenCalledWith({ type: 'post', perspective: 'drafts', id: 'p1' })
    expect(doc).toEqual({ _id: 'p1', _type: 'post' })
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('dedupes a NESTED options object written in a different key order', async () => {
    const { server, fetchSpy } = makeServer()
    const p = createPreloader(server)

    p.preloadDocument('p1', { type: 'post', query: { filters: [], limit: 10, order: 'a:asc' } })
    await p.loadDocument('p1', { type: 'post', query: { order: 'a:asc', limit: 10, filters: [] } })

    expect(fetchSpy).toHaveBeenCalledTimes(1)
    expect(fetchSpy.mock.calls[0]?.[0]).toMatchObject({ id: 'p1', query: { limit: 10 } })
  })

  it('does NOT collapse two distinct AbortSignals into one request', async () => {
    const { server, fetchSpy } = makeServer()
    const p = createPreloader(server)
    const a = new AbortController()
    const b = new AbortController()

    await p.loadDocument('p1', { type: 'post', signal: a.signal })
    await p.loadDocument('p1', { type: 'post', signal: b.signal })

    expect(fetchSpy).toHaveBeenCalledTimes(2)
    // Assert the signals are actually present and are the ones we passed — a
    // pass must not be obtainable by `signal` being dropped on the way through.
    expect(fetchSpy.mock.calls[0]?.[0]?.signal).toBe(a.signal)
    expect(fetchSpy.mock.calls[1]?.[0]?.signal).toBe(b.signal)
  })

  it('still dedupes when the SAME AbortSignal instance is reused', async () => {
    const { server, fetchSpy } = makeServer()
    const p = createPreloader(server)
    const c = new AbortController()

    p.preloadDocument('p1', { type: 'post', signal: c.signal })
    await p.loadDocument('p1', { type: 'post', signal: c.signal })

    expect(fetchSpy).toHaveBeenCalledTimes(1)
    expect(fetchSpy.mock.calls[0]?.[0]?.signal).toBe(c.signal)
  })

  it('keeps a bare string option distinct from the one-element array form', async () => {
    // `expand`/`fields` are `string | string[]`. A key builder that branches on
    // "is this iterable?" walks '/blog' character by character, and one that
    // stringifies loosely makes `'author'` and `['author']` the same key.
    const { server, fetchSpy } = makeServer()
    const p = createPreloader(server)

    await p.loadDocument('p1', { type: 'post', expand: 'author' })
    await p.loadDocument('p1', { type: 'post', expand: ['author'] })

    expect(fetchSpy).toHaveBeenCalledTimes(2)
    expect(fetchSpy.mock.calls[0]?.[0]?.expand).toBe('author')
    expect(fetchSpy.mock.calls[1]?.[0]?.expand).toEqual(['author'])
  })

  it('keeps array ORDER significant while object key order is not', async () => {
    const { server, fetchSpy } = makeServer()
    const p = createPreloader(server)

    await p.loadDocument('p1', { type: 'post', tags: ['a', 'b'] })
    await p.loadDocument('p1', { type: 'post', tags: ['b', 'a'] })

    expect(fetchSpy).toHaveBeenCalledTimes(2)
  })
})
