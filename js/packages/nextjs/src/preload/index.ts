// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { cache } from 'react'

import type { BarkparkFetchOptions } from '../server/types'

/**
 * Minimal server shape the preloader needs. Matches the `barkparkFetch` factory
 * returned by {@link createBarkparkServer} / `defineLive` in `src/server/core.ts`.
 *
 * Any object exposing a compatible `barkparkFetch` satisfies this contract.
 */
export interface PreloadableServer {
  barkparkFetch: <T = unknown>(opts?: BarkparkFetchOptions) => Promise<T>
}

/**
 * Per-request preloader returned by {@link createPreloader}.
 *
 * Lets a layout start a document request eagerly (`preloadDocument`) while the
 * downstream Server Component awaits it (`loadDocument`) without issuing a
 * second round-trip — duplicate `(id, opts)` tuples dedupe to a single
 * in-flight request.
 */
export interface Preloader {
  /** Fire-and-forget. Kicks off the request; the later loadDocument call reuses it. */
  preloadDocument(id: string, opts?: BarkparkFetchOptions): void
  /** Await in the Server Component. Shares the in-flight request started by preloadDocument. */
  loadDocument<T = unknown>(id: string, opts?: BarkparkFetchOptions): Promise<T>
}

function stableKey(id: string, opts?: BarkparkFetchOptions): string {
  return JSON.stringify([id, opts ?? null])
}

/**
 * Factory. Wraps a server's `barkparkFetch` so repeat `(id, opts)` pairs within
 * the same preloader instance dedupe to a single in-flight request, and the
 * settled result is reused by a later `loadDocument` in the same request.
 *
 * ⚠️ Instantiate PER REQUEST — the instance holds a dedup `Map` that lives as
 * long as the instance does. Do NOT hoist a bare `createPreloader(server)` to
 * module scope: on a long-lived server that Map then persists across requests
 * and replays one request's document (and one user's data) to the next — stale
 * content, a cross-request bleed, and unbounded growth. `revalidateTag` can't
 * clear it (the Map sits in front of `barkparkFetch`, holding resolved
 * promises). Bind the instance to the request with React's `cache()` — one
 * shared instance within a request, a fresh one for the next (the example
 * below). `cache()` also gives the fetch itself per-render isolation.
 *
 * @param server — Object exposing `barkparkFetch`; typically the result of
 *                 {@link createBarkparkServer}.
 * @returns A {@link Preloader} with `preloadDocument` + `loadDocument`.
 *
 * @example
 * // app/lib/loader.ts — one request-scoped preloader, shared across components.
 * import { cache } from 'react'
 * import { createPreloader } from '@barkpark/nextjs/preload'
 * import { server } from '@/lib/barkpark'
 *
 * // cache() memoizes per request: getLoader() returns the SAME instance within
 * // one request and a FRESH one for the next — so the dedup Map never outlives
 * // the request. (A module-scoped `const loader = createPreloader(server)` would
 * // leak stale documents across requests — see the warning above.)
 * export const getLoader = cache(() => createPreloader(server))
 *
 * // app/posts/[id]/page.tsx
 * import { getLoader } from '@/lib/loader'
 *
 * export default async function Page({ params }: { params: Promise<{ id: string }> }) {
 *   const { id } = await params
 *   getLoader().preloadDocument(id, { type: 'post' })
 *   return <PostView id={id} />
 * }
 *
 * async function PostView({ id }: { id: string }) {
 *   const post = await getLoader().loadDocument<{ title: string }>(id, { type: 'post' })
 *   return <h1>{post.title}</h1>
 * }
 */
export function createPreloader(server: PreloadableServer): Preloader {
  // Request-scoped when the instance is (see the factory's ⚠️ warning): this Map
  // dedupes preload→load within one request and holds each settled result for
  // the later load. It intentionally lives for the instance's lifetime, so the
  // instance MUST be request-scoped (cache()-bound) — a module-scoped instance
  // turns this into a cross-request cache that serves stale documents.
  const inflight = new Map<string, Promise<unknown>>()

  const fetchOnce = (id: string, opts?: BarkparkFetchOptions): Promise<unknown> => {
    const key = stableKey(id, opts)
    const existing = inflight.get(key)
    if (existing !== undefined) return existing
    const p = server.barkparkFetch({ ...opts, id })
    inflight.set(key, p)
    return p
  }

  const cachedFetch = cache(fetchOnce)

  return {
    preloadDocument(id: string, opts?: BarkparkFetchOptions): void {
      // Fire-and-forget, so the promise MUST get a rejection handler here: a
      // server that is down at preload time would otherwise surface as an
      // unhandledrejection — which crashes a default-configured Node process,
      // turning a warm-up optimization into an outage. `.catch` on this derived
      // consumer marks the SHARED stored promise handled without swallowing
      // anything for a later loadDocument awaiting the same key (it gets the
      // original rejection from the Map).
      cachedFetch(id, opts).catch(() => undefined)
    },
    loadDocument<T = unknown>(id: string, opts?: BarkparkFetchOptions): Promise<T> {
      return cachedFetch(id, opts) as Promise<T>
    },
  }
}

/**
 * One-shot convenience. Kicks off a preload without establishing a reusable
 * preloader. For dedupe with a later `loadDocument` call, prefer
 * {@link createPreloader}.
 *
 * @param server — Object exposing `barkparkFetch`.
 * @param id     — Document id to preload.
 * @param opts   — Optional fetch options; merged with `{ id }`.
 *
 * @example
 * import { preloadDocument } from '@barkpark/nextjs/preload'
 * preloadDocument(server, 'p1', { type: 'post' })
 */
export function preloadDocument(
  server: PreloadableServer,
  id: string,
  opts?: BarkparkFetchOptions,
): void {
  // Same rejection-safety contract as Preloader.preloadDocument above: this is
  // fire-and-forget, so a rejecting fetch must be marked handled or it raises
  // an unhandledrejection (process-fatal in default Node).
  cache((i: string, o?: BarkparkFetchOptions) => server.barkparkFetch({ ...o, id: i }))(
    id,
    opts,
  ).catch(() => undefined)
}
