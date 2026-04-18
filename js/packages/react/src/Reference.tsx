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

export interface RefInput {
  _ref: string
  _type?: string
}

export interface ResolvedDoc {
  _id: string
  _type: string
  [key: string]: unknown
}

export interface BarkparkReferenceClient {
  doc?: <T = ResolvedDoc>(type: string, id: DocId) => Promise<T | null>
  fetchRaw?: <T = ResolvedDoc>(path: string, init?: unknown) => Promise<T>
}

export interface BarkparkReferenceProps {
  ref: RefInput | ResolvedDoc | string
  fetcher?: (id: DocId) => Promise<ResolvedDoc | null>
  client?: BarkparkReferenceClient
  maxDepth?: number
  children: (doc: ResolvedDoc) => ReactNode
  fallback?: ReactNode
  notFound?: ReactNode
  onCycle?: (id: DocId) => void
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
