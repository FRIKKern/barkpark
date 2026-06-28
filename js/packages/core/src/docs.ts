// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Read-side operation: fluent filter/order/limit/offset query over a type.
// GET /v1/data/query/:dataset/:type?filter[...]=...&order=...&limit=...&offset=...
// Returns a DocsBuilder<T> wired to transport — each .find() / .findOne() hits the wire.
//
// Envelope shape — tolerant: Phoenix wraps reads in
//   { result: { perspective, documents: T[], count, limit, offset }, syncTags, ms, etag, schemaHash }
// when barkpark_filterresponse=true (the default). When the wrapper is disabled
// the body is flat: { perspective, documents: T[], count, limit, offset }.
// We accept both.

import { scopePrefix } from './scope'
import { buildQueryString, createDocsBuilder, type BuilderState } from './filter-builder'
import { request } from './transport'
import type { BarkparkClientConfig, BarkparkDocument, DocsBuilder, Perspective } from './types'

export interface DocsOperationOptions {
  perspective?: Perspective
  signal?: AbortSignal
}

interface QueryResultBody<T> {
  perspective: Perspective
  documents: T[]
  count: number
  limit: number
  offset: number
}

/**
 * Build a fluent filter/order/limit/offset query against a document type.
 *
 * Returns a {@link DocsBuilder} whose `.find()` / `.findOne()` hit the wire.
 * `.where(field, op, value)` chains; see {@link FilterOp} for supported ops
 * (Phase 1A: `eq` | `in` | `contains` | `gt` | `gte` | `lt` | `lte`).
 * Prefer `client.docs(type)` — this factory is for config-only callers.
 */
export function createDocsOperation<T = BarkparkDocument>(
  config: BarkparkClientConfig,
  type: string,
  opts?: DocsOperationOptions,
): DocsBuilder<T> {
  const buildPath = (state: BuilderState, extra: string[]): string => {
    const perspective = opts?.perspective ?? config.perspective
    const qs = buildQueryString(state)
    const parts: string[] = []
    if (qs.length > 0) parts.push(qs)
    if (perspective !== undefined) parts.push(`perspective=${encodeURIComponent(perspective)}`)
    for (const p of extra) parts.push(p)
    const query = parts.length > 0 ? `?${parts.join('&')}` : ''
    return `${scopePrefix(config)}/v1/data/query/${encodeURIComponent(config.dataset)}/${encodeURIComponent(type)}${query}`
  }

  const reqOpts = (): { kind: 'read'; signal?: AbortSignal } => {
    const o: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
    if (opts?.signal !== undefined) o.signal = opts.signal
    return o
  }

  return createDocsBuilder<T>(
    async (state: BuilderState) => {
      const { data } = await request<QueryResultBody<T> & { result?: QueryResultBody<T> }>(
        config,
        buildPath(state, []),
        reqOpts(),
      )
      return data.result?.documents ?? data.documents ?? []
    },
    // count executor: same filters, but `?count=true` and a minimal page (the
    // total is independent of limit/offset; we only read result.total).
    async (state: BuilderState) => {
      const path = buildPath({ ...state, limit: 1 }, ['count=true'])
      const { data } = await request<{ total?: number; result?: { total?: number } }>(
        config,
        path,
        reqOpts(),
      )
      return data.result?.total ?? data.total ?? 0
    },
  )
}
