// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Read-side operation: fluent filter/order/limit/offset query over a type.
// GET /v1/data/query/:dataset/:type?filter[...]=...&order=...&limit=...&offset=...
// Returns a DocsBuilder<T> wired to transport — each .find() / .findOne() hits the wire.
//
// Envelope shape (Phoenix query_controller — flat, top-level):
//   { perspective, documents: T[], count, limit, offset }

import { buildQueryString, createDocsBuilder, type BuilderState } from './filter-builder'
import { request } from './transport'
import type {
  BarkparkClientConfig,
  BarkparkDocument,
  DocsBuilder,
  Perspective,
} from './types'

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
  return createDocsBuilder<T>(async (state: BuilderState) => {
    const perspective = opts?.perspective ?? config.perspective
    const qs = buildQueryString(state)
    const parts: string[] = []
    if (qs.length > 0) parts.push(qs)
    if (perspective !== undefined) parts.push(`perspective=${encodeURIComponent(perspective)}`)
    const query = parts.length > 0 ? `?${parts.join('&')}` : ''
    const path = `/v1/data/query/${encodeURIComponent(config.dataset)}/${encodeURIComponent(type)}${query}`

    const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
    if (opts?.signal !== undefined) reqOpts.signal = opts.signal
    const { data } = await request<QueryResultBody<T>>(config, path, reqOpts)
    return data.documents ?? []
  })
}
