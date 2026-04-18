// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

'use client'

import {
  createContext,
  use,
  useContext,
  useMemo,
  Suspense,
  Fragment,
  createElement,
} from 'react'
import type { ReactElement, ReactNode } from 'react'

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
  doc?: <T = ResolvedDoc>(type: string, id: DocId) => Promise<T | null>
  fetchRaw?: <T = ResolvedDoc>(path: string, init?: unknown) => Promise<T>
}

/** Props for {@link BarkparkReference}. */
export interface BarkparkReferenceProps {
  /** Reference or already-resolved document; plain string = id only. */
  ref: RefInput | ResolvedDoc | string
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

function extractId(
  ref: BarkparkReferenceProps['ref'],
): { id: DocId | null; resolved: ResolvedDoc | null } {
  if (typeof ref === 'string') return { id: ref, resolved: null }
  if (ref && typeof ref === 'object') {
    const r = ref as Record<string, unknown>
    if (typeof r._id === 'string' && typeof r._type === 'string') {
      return { id: r._id, resolved: ref as ResolvedDoc }
    }
    if (typeof r._ref === 'string') {
      return { id: r._ref, resolved: null }
    }
  }
  return { id: null, resolved: null }
}

function resolveFetcher(
  props: BarkparkReferenceProps,
): (id: DocId) => Promise<ResolvedDoc | null> {
  if (props.fetcher) return props.fetcher
  const client = props.client
  if (client?.fetchRaw) {
    // Best-effort: dataset defaults to "production". Users who need a
    // different dataset or access token behavior should pass `fetcher`.
    const fetchRaw = client.fetchRaw
    return async (id) => {
      try {
        return await fetchRaw<ResolvedDoc>(`/v1/data/doc/production/${id}`)
      } catch {
        return null
      }
    }
  }
  throw new Error(
    '<BarkparkReference /> requires a `fetcher` prop or a `client` with `fetchRaw`',
  )
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
  return createElement(
    BarkparkReferenceContext.Provider,
    { value: nextCtx },
    render(doc),
  )
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
 * @throws When neither `fetcher` nor a `client` with `fetchRaw` is provided for an unresolved reference.
 *
 * @example
 * import { BarkparkReference } from '@barkpark/react'
 *
 * <BarkparkReference ref={post.author} fetcher={loadAuthor} fallback={<Skeleton />}>
 *   {(author) => <AuthorCard author={author} />}
 * </BarkparkReference>
 */
export function BarkparkReference(
  props: BarkparkReferenceProps,
): ReactElement | null {
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
  const depth = parent ? parent.depth : 0
  // Root establishes maxDepth; nested instances inherit the root's cap so
  // callers can't widen it mid-tree.
  const effectiveMaxDepth = parent ? parent.maxDepth : maxDepth

  const { id, resolved } = extractId(ref)
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
    return createElement(
      BarkparkReferenceContext.Provider,
      { value: nextCtx },
      children(resolved),
    )
  }

  const fetcher = resolveFetcher(props)
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
