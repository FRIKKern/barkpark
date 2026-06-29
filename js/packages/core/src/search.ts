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
  if (opts?.engine !== undefined) params.set('engine', opts.engine)

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
  // Only set the optional field when present (exactOptionalPropertyTypes).
  if (body.highlights !== undefined) result.highlights = body.highlights
  return result
}
