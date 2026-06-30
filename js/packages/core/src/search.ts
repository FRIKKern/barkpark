// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Full-text search over a dataset:
//   GET /v1/data/search/:dataset?q=...&limit=...&engine=...
// The response is flat (not the `result`-enveloped query shape):
//   { documents, count, query, highlights, correctedTo, ... }
// We read it tolerantly (accepting an enveloped shape too).

import { scopePrefix } from './scope'
import { request } from './transport'
import type { BarkparkClientConfig, BarkparkDocument, SearchOptions, SearchResult } from './types'

export async function searchDocuments<T = BarkparkDocument>(
  config: BarkparkClientConfig,
  q: string,
  opts?: SearchOptions,
): Promise<SearchResult<T>> {
  const params = new URLSearchParams({ q })
  if (opts?.limit !== undefined) params.set('limit', String(opts.limit))
  if (opts?.offset !== undefined) params.set('offset', String(opts.offset))
  if (opts?.engine !== undefined) params.set('engine', opts.engine)
  if (opts?.type !== undefined) params.set('type', opts.type)
  // Respect the client's perspective (like doc/docs reads do), with a per-call
  // override — so `withConfig({ perspective: 'drafts' }).search(…)` searches drafts.
  const perspective = opts?.perspective ?? config.perspective
  if (perspective !== undefined) params.set('perspective', perspective)

  const path = `${scopePrefix(config)}/v1/data/search/${encodeURIComponent(config.dataset)}?${params.toString()}`

  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal

  const { data } = await request<SearchResult<T> & { result?: SearchResult<T> }>(
    config,
    path,
    reqOpts,
  )
  const body = data.result ?? data
  const result: SearchResult<T> = {
    documents: body.documents ?? [],
    count: body.count ?? 0,
    query: body.query ?? q,
    correctedTo: body.correctedTo ?? null,
  }
  // Only set the optional fields when present (exactOptionalPropertyTypes).
  if (body.highlights !== undefined) result.highlights = body.highlights
  if (body.facets !== undefined) result.facets = body.facets
  if (body.parsedQuery !== undefined) result.parsedQuery = body.parsedQuery
  if (body.recovery !== undefined) result.recovery = body.recovery
  if (body.truncation !== undefined) result.truncation = body.truncation
  if (typeof body.ms === 'number') result.ms = body.ms
  return result
}
