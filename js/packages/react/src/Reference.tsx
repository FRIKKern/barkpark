// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

'use client'

import { createContext, use, useContext, useMemo, Suspense, Fragment, createElement } from 'react'
import type { ReactElement, ReactNode } from 'react'
import { scopePrefix } from '@barkpark/core'
import type { BarkparkClientConfig } from '@barkpark/core'

type DocId = string

/** Minimal unresolved reference — the shape stored in documents. */
export interface RefInput {
  _ref: string
  _type?: string
}

/** Expanded document returned by the fetcher. Extra fields pass through. */
export interface ResolvedDoc {
  _id: string
  _type: string
  [key: string]: unknown
}

/** Structural client shape {@link BarkparkReference} can auto-derive a fetcher from. */
export interface BarkparkReferenceClient {
  /**
   * Escape-hatch reader. Matches the real `@barkpark/core` client, which
   * returns the raw {@link Response} (`T = Response`) — the derived fetcher
   * unwraps it. A stub that returns an already-parsed doc also works.
   */
  fetchRaw?: <T = Response>(path: string, init?: unknown) => Promise<T>
  /**
   * Type-aware single-document getter. Matches the real `@barkpark/core`
   * client's `doc(type, id)`, which builds the canonical 3-segment
   * `/v1/data/doc/:dataset/:type/:id` path and returns the parsed doc (or
   * `null` on 404). Preferred over `fetchRaw` whenever a target `type` is known.
   */
  doc?: <T = ResolvedDoc>(type: string, id: string, opts?: unknown) => Promise<T | null>
  /**
   * The client's resolved config. When present, the derived `fetchRaw` fetcher
   * scopes the path to `scopePrefix(config)` and uses the configured `dataset`
   * instead of a hardcoded fallback. The real `@barkpark/core` client exposes
   * this; a structurally-compatible config (workspace/project/dataset) is enough.
   */
  config?: Pick<BarkparkClientConfig, 'workspace' | 'project' | 'dataset'>
}

/** Props for {@link BarkparkReference}. */
export interface BarkparkReferenceProps {
  /** Reference or already-resolved document; plain string = id only. */
  ref: RefInput | ResolvedDoc | string
  /**
   * Target document type. Optional. A reference value carries no type by itself,
   * so client-derived resolution needs one to build the canonical 3-segment
   * `/v1/data/doc/:dataset/:type/:id` path (or call `client.doc(type, id)`).
   * Resolution order: this prop → the reference's own `_type` → none (in which
   * case the client branch falls back to the legacy typeless path).
   */
  type?: string
  /** Custom loader. Takes precedence over `client`. */
  fetcher?: (id: DocId) => Promise<ResolvedDoc | null>
  /** Client to derive a default fetcher from (uses `fetchRaw`). */
  client?: BarkparkReferenceClient
  /** Cycle-depth cap, defaulting to 5. Captured at the root; nested instances cannot widen. */
  maxDepth?: number
  /** Render-prop receiving the resolved document. */
  children: (doc: ResolvedDoc) => ReactNode
  /** Rendered under `<Suspense>` while the fetcher resolves. */
  fallback?: ReactNode
  /** Rendered when the fetcher returns `null` or when depth is exceeded. */
  notFound?: ReactNode
  /** Invoked when an id is re-entered via a parent chain. */
  onCycle?: (id: DocId) => void
  /** Invoked when the depth cap is reached. */
  onMaxDepth?: (id: DocId, depth: number) => void
}

// Masterplan says WeakSet<DocId>, but DocId is a string → Set<string>.
// Equivalent cycle-detection semantics; WeakSet requires object keys.
interface RefContextValue {
  visited: Set<DocId>
  depth: number
  maxDepth: number
}

const BarkparkReferenceContext = createContext<RefContextValue | null>(null)

function extractId(ref: BarkparkReferenceProps['ref']): {
  id: DocId | null
  /** Target type carried by the reference value (`_type`), if any. */
  type: string | null
  resolved: ResolvedDoc | null
} {
  if (typeof ref === 'string') return { id: ref, type: null, resolved: null }
  if (ref && typeof ref === 'object') {
    const r = ref as Record<string, unknown>
    if (typeof r._id === 'string' && typeof r._type === 'string') {
      return { id: r._id, type: r._type, resolved: ref as ResolvedDoc }
    }
    if (typeof r._ref === 'string') {
      return { id: r._ref, type: typeof r._type === 'string' ? r._type : null, resolved: null }
    }
  }
  return { id: null, type: null, resolved: null }
}

/**
 * Build the doc-read path for an unresolved reference id.
 *
 * Scope-aware: when the client carries a `config` with both `workspace` and
 * `project`, the path is prefixed with `scopePrefix(config)` (→ `/w/:ws/p/:proj`)
 * and uses the configured `dataset`. The literal "production" dataset is only
 * used as a last resort when no config is present.
 *
 * The API's only doc route is the 3-segment `/v1/data/doc/:dataset/:type/:id`
 * (type required). When `type` is known the canonical 3-segment path is built;
 * when it is absent we fall back to the legacy 2-segment `…/:dataset/:id` form
 * — which the current API does NOT serve (it 404s), so an untyped reference
 * resolves to `notFound`. Pass a `type` prop (or a `_type` on the reference)
 * to get real resolution.
 */
function buildDocPath(
  config: BarkparkReferenceClient['config'],
  id: DocId,
  type?: string | null,
): string {
  const dataset = config?.dataset ?? 'production'
  const prefix = config ? scopePrefix(config as BarkparkClientConfig) : ''
  const tail = type
    ? `${encodeURIComponent(dataset)}/${encodeURIComponent(type)}/${encodeURIComponent(id)}`
    : `${encodeURIComponent(dataset)}/${encodeURIComponent(id)}`
  return `${prefix}/v1/data/doc/${tail}`
}

function resolveFetcher(
  props: Pick<BarkparkReferenceProps, 'fetcher' | 'client'>,
  type: string | null,
): (id: DocId) => Promise<ResolvedDoc | null> {
  if (props.fetcher) return props.fetcher
  const client = props.client
  // Prefer the client's type-aware `doc(type, id)` getter when a target type is
  // known — it builds the canonical 3-segment path and returns a parsed doc.
  if (type && typeof client?.doc === 'function') {
    const docFn = client.doc
    return async (id) => {
      try {
        return (await docFn<ResolvedDoc>(type, id)) ?? null
      } catch {
        return null
      }
    }
  }
  if (client?.fetchRaw) {
    // Derive a fetcher from the client. Scope + dataset come from the client's
    // config (workspace/project/dataset); see buildDocPath. Users who need
    // bespoke perspective/token behavior should pass `fetcher` instead.
    const fetchRaw = client.fetchRaw
    const config = client.config
    return async (id) => {
      try {
        const res = await fetchRaw<unknown>(buildDocPath(config, id, type))
        // The real core client's fetchRaw returns a raw Response; unwrap the
        // `/v1/data/doc` envelope ({ result: doc, ... }). A stub that returns
        // an already-parsed object is passed through untouched.
        if (res instanceof Response) {
          if (!res.ok) return null
          const body = (await res.json()) as {
            result?: ResolvedDoc
            data?: ResolvedDoc
          } | null
          return (body?.result ?? body?.data ?? body ?? null) as ResolvedDoc | null
        }
        return (res ?? null) as ResolvedDoc | null
      } catch {
        return null
      }
    }
  }
  throw new Error('<BarkparkReference /> requires a `fetcher` prop or a `client` with `fetchRaw` or `doc`')
}

function AsyncResolve(props: {
  id: DocId
  fetcher: (id: DocId) => Promise<ResolvedDoc | null>
  nextCtx: RefContextValue
  render: (doc: ResolvedDoc) => ReactNode
  notFound: ReactNode
}): ReactElement {
  const { id, fetcher, nextCtx, render, notFound } = props
  const promise = useMemo(() => fetcher(id), [id, fetcher])
  const doc = use(promise)
  if (doc == null) return createElement(Fragment, null, notFound)
  return createElement(BarkparkReferenceContext.Provider, { value: nextCtx }, render(doc))
}

/**
 * Resolves a Barkpark reference (by id or `{ _ref }`) to its target document
 * via `use()` under `<Suspense>`. Guards against cycles by tracking visited
 * ids through context and caps recursion at `maxDepth`.
 *
 * If `ref` is already an expanded document, no fetch is issued.
 *
 * @param props — {@link BarkparkReferenceProps}
 * @returns The rendered children or `null` when `ref` is unusable.
 * @throws When neither `fetcher` nor a `client` with `fetchRaw` or `doc` is provided for an unresolved reference.
 *
 * @example
 * import { BarkparkReference } from '@barkpark/react'
 *
 * <BarkparkReference ref={post.author} fetcher={loadAuthor} fallback={<Skeleton />}>
 *   {(author) => <AuthorCard author={author} />}
 * </BarkparkReference>
 */
export function BarkparkReference(props: BarkparkReferenceProps): ReactElement | null {
  const {
    ref,
    maxDepth = 5,
    children,
    fallback = null,
    notFound = null,
    onCycle,
    onMaxDepth,
  } = props

  const parent = useContext(BarkparkReferenceContext)

  // Derive the fetcher once per (fetcher, client) identity. For the client branch,
  // resolveFetcher builds a NEW async closure on every call — so without memoizing,
  // any unrelated parent re-render (e.g. BarkparkLive's router.refresh) hands
  // AsyncResolve a fresh `fetcher`, invalidating its useMemo([id, fetcher]) and
  // firing a redundant refetch + Suspense-fallback flash. Hoisted above the early
  // returns so the hook order stays stable (rules-of-hooks). Depends only on the
  // two props that actually determine the fetcher — never the whole props object.
  const explicitFetcher = props.fetcher
  const client = props.client
  // Target type resolution order: explicit `type` prop → the reference's own
  // `_type` → none. Captured before the memo so the derived fetcher can build
  // the canonical 3-segment path / call `client.doc(type, id)`. `extractId`
  // is pure (no hook), so calling it here keeps hook order stable.
  const { id, type: refType, resolved } = extractId(ref)
  const targetType = props.type ?? refType
  const fetcher = useMemo<((id: DocId) => Promise<ResolvedDoc | null>) | null>(() => {
    if (explicitFetcher) return explicitFetcher
    if (client?.fetchRaw || client?.doc) return resolveFetcher({ client }, targetType)
    return null
  }, [explicitFetcher, client, targetType])

  const depth = parent ? parent.depth : 0
  // Root establishes maxDepth; nested instances inherit the root's cap so
  // callers can't widen it mid-tree.
  const effectiveMaxDepth = parent ? parent.maxDepth : maxDepth

  if (id == null) return null

  if (depth >= effectiveMaxDepth) {
    if (onMaxDepth) onMaxDepth(id, depth)
    return createElement(Fragment, null, notFound)
  }

  if (parent && parent.visited.has(id)) {
    if (onCycle) onCycle(id)
    return null
  }

  // Clone visited so sibling branches don't pollute each other.
  const nextVisited = new Set(parent?.visited ?? [])
  nextVisited.add(id)
  const nextCtx: RefContextValue = {
    visited: nextVisited,
    depth: depth + 1,
    maxDepth: effectiveMaxDepth,
  }

  if (resolved) {
    return createElement(BarkparkReferenceContext.Provider, { value: nextCtx }, children(resolved))
  }

  if (!fetcher) {
    // Only an unresolved reference lacking BOTH a fetcher and a client is an error
    // (a resolved doc or unusable id returned earlier). Same contract as
    // resolveFetcher's own guard; thrown here so the memo above stays pure.
    throw new Error('<BarkparkReference /> requires a `fetcher` prop or a `client` with `fetchRaw` or `doc`')
  }
  return createElement(
    Suspense,
    { fallback },
    createElement(AsyncResolve, {
      id,
      fetcher,
      nextCtx,
      render: children,
      notFound,
    }),
  )
}
