import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { exportDataset } from '../src/export'
import { createListenHandle } from '../src/listen'
import { BarkparkAPIError, BarkparkAuthError, BarkparkNetworkError } from '../src/errors'
import type { BarkparkClientConfig } from '../src/types'

// [export-ignores-config-fetch] `BarkparkClientConfig.fetch` is documented as
// the "user override (MSW, tracing)". transport.ts honours it for every JSON
// call and listen.ts honours it for the SSE stream — exportDataset, the other
// stream, reached straight for the global `fetch`.
//
// Nothing errored. The request simply went out through a different door than
// the caller wired up: a test suite's mock was bypassed, a tracing wrapper saw
// no export traffic, an auth-injecting wrapper's header never went on. A
// backup that quietly ignores your transport is the shape this lane hunts.

const baseConfig: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
}

const NDJSON = `${JSON.stringify({ _id: 'a', _type: 'post' })}\n`

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

async function collect<T>(it: AsyncIterable<T>): Promise<T[]> {
  const out: T[] = []
  for await (const x of it) out.push(x)
  return out
}

describe('exportDataset honours config.fetch like every other path', () => {
  it('calls the configured fetch, not the global one', async () => {
    const seen: string[] = []
    const fetchImpl: typeof globalThis.fetch = async (input) => {
      seen.push(typeof input === 'string' ? input : (input as Request).url)
      return new Response(NDJSON, { headers: { 'content-type': 'application/x-ndjson' } })
    }

    // No MSW handler is registered for this route, and the suite runs with
    // onUnhandledRequest: 'error' — so if export reached the global fetch at
    // all, this call would fail rather than pass. The spy is the only route.
    const docs = await collect(exportDataset({ ...baseConfig, fetch: fetchImpl }))

    expect(seen).toHaveLength(1)
    expect(seen[0]).toContain('/v1/data/export/')
    expect(docs).toEqual([{ _id: 'a', _type: 'post' }])
  })

  it('threads the caller’s query params and headers through the configured fetch', async () => {
    let capturedUrl = ''
    let capturedInit: RequestInit | undefined
    const fetchImpl: typeof globalThis.fetch = async (input, init) => {
      capturedUrl = typeof input === 'string' ? input : (input as Request).url
      capturedInit = init
      return new Response(NDJSON, { headers: { 'content-type': 'application/x-ndjson' } })
    }

    await collect(
      exportDataset({ ...baseConfig, fetch: fetchImpl, token: 'tok' }, {
        type: 'post',
        perspective: 'raw',
      }),
    )

    expect(capturedUrl).toContain('type=post')
    expect(capturedUrl).toContain('perspective=raw')
    const headers = capturedInit?.headers as Record<string, string>
    expect(headers.Authorization).toBe('Bearer tok')
    expect(headers.Accept).toBe('application/x-ndjson')
  })

  // REGRESSION PIN, not a proof of this change: a missing global fetch already
  // produced a typed error before it, because the call sits inside the try
  // whose catch re-wraps. It is pinned because the wrapper is what makes that
  // true — hoist the call out of the try and a raw TypeError escapes to the
  // caller instead. The `cause` assertion is the part with teeth: the typed
  // error must not swallow what actually went wrong.
  it('a runtime with no fetch surfaces a typed error that still carries the real cause', async () => {
    const config = { ...baseConfig, fetch: undefined as unknown as typeof globalThis.fetch }
    const orig = globalThis.fetch
    ;(globalThis as unknown as { fetch?: unknown }).fetch = undefined
    try {
      const err = await collect(exportDataset(config)).catch((e: unknown) => e)
      expect(err).toBeInstanceOf(BarkparkNetworkError)
      expect((err as BarkparkNetworkError).cause).toBeInstanceOf(TypeError)
    } finally {
      ;(globalThis as unknown as { fetch?: unknown }).fetch = orig
    }
  })
})

// export and listen are the two streaming paths; each carried its own copy of
// the same auth/ok/body ladder. Folding them must not have moved a message, an
// error class, or the ORDER in which two failing checks report.
describe('the shared stream-response guard keeps both callers’ exact contract', () => {
  const streamFetch =
    (status: number, headers: Record<string, string> = {}, body: string | null = NDJSON) =>
    (async () =>
      new Response(status === 204 ? null : body, {
        status,
        headers,
      })) as unknown as typeof globalThis.fetch

  it('export: 401 and 403 are BarkparkAuthError with the export label', async () => {
    for (const status of [401, 403]) {
      const p = collect(exportDataset({ ...baseConfig, fetch: streamFetch(status) }))
      await expect(p).rejects.toBeInstanceOf(BarkparkAuthError)
      await expect(p).rejects.toThrow(`export: ${status} auth failed`)
    }
  })

  it('export: a non-ok status is BarkparkAPIError naming the code', async () => {
    const p = collect(exportDataset({ ...baseConfig, fetch: streamFetch(500) }))
    await expect(p).rejects.toBeInstanceOf(BarkparkAPIError)
    await expect(p).rejects.toThrow('export: HTTP 500')
  })

  it('export: a 2xx with no body is BarkparkAPIError, not a silent empty export', async () => {
    // The quiet one — an empty stream would otherwise look like an empty dataset.
    const p = collect(exportDataset({ ...baseConfig, fetch: streamFetch(204, {}, null) }))
    await expect(p).rejects.toThrow('export: response has no body')
  })

  it('listen: keeps its own label, its content-type check, and the check ORDER', async () => {
    const listenCfg = { ...baseConfig, fetch: streamFetch(200, { 'content-type': 'application/json' }) }
    await expect(
      (async () => {
        for await (const _evt of createListenHandle(listenCfg, 'post')) { void _evt; break }
      })(),
    ).rejects.toThrow('listen: expected text/event-stream, got application/json')

    // Auth is checked BEFORE content-type: a 401 that ALSO has the wrong
    // content-type must still report auth, exactly as it did before the fold.
    const authCfg = { ...baseConfig, fetch: streamFetch(401, { 'content-type': 'application/json' }) }
    await expect(
      (async () => {
        for await (const _evt of createListenHandle(authCfg, 'post')) { void _evt; break }
      })(),
    ).rejects.toThrow('listen: 401 auth failed')
  })
})
