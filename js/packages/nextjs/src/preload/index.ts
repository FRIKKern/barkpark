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

/**
 * Identity registry for values a structural encoding cannot represent — an
 * `AbortSignal`, a function, a `Map`, a class instance. A `WeakMap`, so the key
 * STRING (which carries only the integer id) never keeps the value itself
 * alive. Ids are handed out monotonically, so the same value always encodes to
 * the same token within a process.
 */
const objectIds = new WeakMap<object, number>()
/**
 * Same registry for symbols. Symbols are not valid `WeakMap` keys under this
 * package's ES2022 target, so this one holds strong references: it grows by one
 * entry per DISTINCT symbol ever passed as an option value or used as an
 * enumerable option key. None of `BarkparkFetchOptions`' declared fields is a
 * symbol, but the package ships CJS/ESM to plain JS callers with no types, so
 * the encoder handles the case rather than silently collapsing it.
 */
const symbolIds = new Map<symbol, number>()
let nextId = 0

function identityOf(value: object | symbol): number {
  if (typeof value === 'symbol') {
    const known = symbolIds.get(value)
    if (known !== undefined) return known
    const id = ++nextId
    symbolIds.set(value, id)
    return id
  }
  const known = objectIds.get(value)
  if (known !== undefined) return known
  const id = ++nextId
  objectIds.set(value, id)
  return id
}

function isPlainObject(value: object): boolean {
  const proto: unknown = Object.getPrototypeOf(value)
  return proto === Object.prototype || proto === null
}

/**
 * Self-delimiting, type-tagged encoding of an arbitrary value.
 *
 * Every branch dispatches on `typeof` FIRST, so a bare string is a scalar and
 * is never walked character by character — `expand: 'author'` and
 * `expand: ['author']` must not, and do not, encode alike. Plain objects have
 * their keys sorted RECURSIVELY (so `{a,b}` and `{b,a}` agree at every depth);
 * arrays keep their order, because array order is meaningful in `tags`,
 * `fields` and `expand`.
 */
function encode(value: unknown, seen: Set<object>): string {
  switch (typeof value) {
    case 'string':
      return `s${JSON.stringify(value)}`
    case 'number':
      // -0 and 0 both render as "0" via String(); keep them apart.
      return Object.is(value, -0) ? 'n-0' : `n${String(value)}`
    case 'boolean':
      return value ? 'bT' : 'bF'
    case 'undefined':
      return 'u'
    case 'bigint':
      return `g${String(value)}`
    case 'symbol':
      return `y${identityOf(value)}`
    case 'function':
      return `f${identityOf(value as unknown as object)}`
    default:
      break
  }

  if (value === null) return 'z'
  const obj = value as object

  // A cycle has no structural encoding (JSON.stringify throws on one). Fall
  // back to the identity token and stop descending.
  if (seen.has(obj)) return `r${identityOf(obj)}`

  if (Array.isArray(value)) {
    seen.add(obj)
    const parts = (value as unknown[]).map((entry) => encode(entry, seen))
    seen.delete(obj)
    return `[${parts.join(',')}]`
  }

  if (!isPlainObject(obj)) {
    // AbortSignal, Map, Set, URL, RegExp, Date, class instances — and a plain
    // object built in another realm. Structural encoding is unsafe for these:
    // an AbortSignal exposes no enumerable own state, so JSON.stringify renders
    // EVERY one of them as `{}` and two different signals collide. They
    // contribute IDENTITY instead — distinct instances get distinct keys, the
    // same instance reused still dedupes. A cross-realm plain object lands here
    // too and merely misses a dedup, which is the safe direction to err.
    return `o${identityOf(obj)}`
  }

  seen.add(obj)
  const record = obj as Record<PropertyKey, unknown>
  const parts = Object.keys(record)
    .sort()
    .map((k) => `${JSON.stringify(k)}:${encode(record[k], seen)}`)
  // Enumerable symbol-keyed properties, ordered by their identity token (stable
  // within a process). JSON.stringify drops these outright.
  const symbolParts = Object.getOwnPropertySymbols(record)
    .filter((s) => Object.prototype.propertyIsEnumerable.call(record, s))
    .map((s) => ({ id: identityOf(s), value: record[s] }))
    .sort((a, b) => a.id - b.id)
    .map((entry) => `@${entry.id}:${encode(entry.value, seen)}`)
  seen.delete(obj)
  return `{${[...parts, ...symbolParts].join(',')}}`
}

/**
 * Dedup key for one `(id, opts)` tuple.
 *
 * Replaces `JSON.stringify([id, opts])`, which had three faults: it is
 * key-ORDER sensitive (the same options bag written `{a,b}` vs `{b,a}` produced
 * two keys and so missed a dedup); it renders every non-serializable value as
 * `{}` (so two DIFFERENT `AbortSignal`s produced ONE key and were wrongly
 * collapsed onto a single in-flight request governed by whichever signal
 * arrived first); and it THROWS on a cyclic options bag. None of the three can
 * hand back a wrong document body — the key is only ever consulted for the
 * tuple that produced it.
 *
 * `undefined` and `{}` are normalised to the same key: `{ ...opts, id }` is
 * `{ id }` either way, so they describe the same request.
 */
function stableKey(id: string, opts?: BarkparkFetchOptions): string {
  const seen = new Set<object>()
  return `${encode(id, seen)}|${encode(opts ?? {}, seen)}`
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
  //
  // Nothing evicts from this Map, so the key's precision governs its size: it
  // holds one entry per DISTINCT (id, opts) tuple the request actually asked
  // for. stableKey no longer collapses two AbortSignals onto one entry, so a
  // request that preloads the same document under several signals now stores
  // several entries instead of one — bounded by the calls that request makes,
  // and the point of the fix. The keys stay plain strings carrying only an
  // integer identity token, so an entry never keeps a signal (or any other
  // non-serializable option value) alive.
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
