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
 * the same preloader instance dedupe to a single in-flight request. Intended to
 * be instantiated per request in App Router pages/layouts. Wrapped additionally
 * in React's `cache()` for per-render isolation inside Server Components.
 *
 * @param server — Object exposing `barkparkFetch`; typically the result of
 *                 {@link createBarkparkServer}.
 * @returns A {@link Preloader} with `preloadDocument` + `loadDocument`.
 *
 * @example
 * // app/posts/[id]/page.tsx
 * import { createPreloader } from '@barkpark/nextjs/preload'
 * import { server } from '@/lib/barkpark'
 *
 * const loader = createPreloader(server)
 *
 * export default async function Page({ params }: { params: Promise<{ id: string }> }) {
 *   const { id } = await params
 *   loader.preloadDocument(id, { type: 'post' })
 *   return <PostView id={id} />
 * }
 *
 * async function PostView({ id }: { id: string }) {
 *   const post = await loader.loadDocument<{ title: string }>(id, { type: 'post' })
 *   return <h1>{post.title}</h1>
 * }
 */
export function createPreloader(server: PreloadableServer): Preloader {
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
      void cachedFetch(id, opts)
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
  void cache((i: string, o?: BarkparkFetchOptions) => server.barkparkFetch({ ...o, id: i }))(id, opts)
}
