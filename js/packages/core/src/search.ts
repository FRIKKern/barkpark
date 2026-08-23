// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Full-text search over a dataset:
//   GET /v1/data/search/:dataset?q=...&limit=...&engine=...
// The response is flat (not the `result`-enveloped query shape):
//   { documents, count, query, highlights, correctedTo, ... }
// We read it tolerantly (accepting an enveloped shape too).

import { scopePrefix } from './scope'
import { request } from './transport'
import { assertPaging, assertNoCommaEntries } from './filter-builder'
import { BarkparkValidationError } from './errors'
import type {
  BarkparkClientConfig,
  BarkparkDocument,
  SearchOptions,
  SearchResult,
  SearchSuggestions,
  SearchSuggestionsOptions,
} from './types'

export async function searchDocuments<T = BarkparkDocument>(
  config: BarkparkClientConfig,
  q: string,
  opts?: SearchOptions,
): Promise<SearchResult<T>> {
  assertPaging(opts?.limit, opts?.offset)
  // Document search has no filter-only mode — an empty q is a caller bug, so
  // fail closed (parity with getBacklinks/getGraph/restoreRevision/assertAssetId).
  if (typeof q !== 'string' || q.trim().length === 0) {
    throw new BarkparkValidationError('search requires a non-empty query string', { field: 'q' })
  }
  // `type` and `types` are mutually exclusive — the server ANDs them
  // (`d.type == ^type` AND `d.type in ^types`), so disjoint values silently
  // return zero hits. Fail closed instead of shipping an empty-by-construction filter.
  if (opts?.type !== undefined && opts?.types !== undefined && opts.types.length > 0) {
    throw new BarkparkValidationError(
      'search accepts type OR types, not both — together they combine into an empty (type == x AND type IN [...]) filter',
      { field: 'types' },
    )
  }
  const params = new URLSearchParams({ q })
  if (opts?.limit !== undefined) params.set('limit', String(opts.limit))
  if (opts?.offset !== undefined) params.set('offset', String(opts.offset))
  if (opts?.engine !== undefined) params.set('engine', opts.engine)
  if (opts?.type !== undefined) params.set('type', opts.type)
  // Multi-type allowlist → `types=a,b`. The API's parse_types splits the CSV;
  // an empty array sends nothing (equivalent to no restriction).
  if (opts?.types !== undefined && opts.types.length > 0) {
    // A comma inside a type name would silently split into extra types (an
    // over-broad allowlist) — fail closed like the filter-builder comma guards.
    assertNoCommaEntries(opts.types, 'types')
    params.set('types', opts.types.join(','))
  }
  // Respect the client's perspective (like doc/docs reads do), with a per-call
  // override — so `withConfig({ perspective: 'drafts' }).search(…)` searches drafts.
  const perspective = opts?.perspective ?? config.perspective
  if (perspective !== undefined) params.set('perspective', perspective)

  const path = `${scopePrefix(config)}/v1/data/search/${encodeURIComponent(config.dataset)}?${params.toString()}`

  const reqOpts: { kind: 'read'; signal?: AbortSignal; headers?: Record<string, string> } = {
    kind: 'read',
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  // Tokenless per-session identity (mirrors the browser UI's session UUID).
  if (opts?.sessionKey !== undefined) reqOpts.headers = { 'x-bp-search-client': opts.sessionKey }

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
    // Top-level on the response (not nested under `result`) — required by the
    // paired /search/interaction routes to report click/quality signals.
    searchEventId: data.searchEventId ?? null,
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

/**
 * Typeahead suggestions for a document search box
 * (`GET /v1/data/search/:dataset/suggestions`): the caller's `recent` queries,
 * the dataset's `popular` ones, and recent `nohits`. `prefix` filters each bucket
 * as the user types (omit for the unfiltered top lists). Prefer
 * `client.getSearchSuggestions()`. The document counterpart of
 * `client.getAssetSearchSuggestions()`.
 */
export async function getSearchSuggestions(
  config: BarkparkClientConfig,
  prefix?: string,
  opts?: SearchSuggestionsOptions,
): Promise<SearchSuggestions> {
  assertPaging(opts?.limit)
  const params = new URLSearchParams()
  if (prefix) params.set('q', prefix)
  if (opts?.limit !== undefined) params.set('limit', String(opts.limit))
  const qs = params.toString()
  const path = `${scopePrefix(config)}/v1/data/search/${encodeURIComponent(config.dataset)}/suggestions${qs ? `?${qs}` : ''}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal; headers?: Record<string, string> } = {
    kind: 'read',
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  // Tokenless per-session identity (mirrors the browser UI's session UUID).
  if (opts?.sessionKey !== undefined) reqOpts.headers = { 'x-bp-search-client': opts.sessionKey }

  const { data } = await request<
    { result?: Partial<SearchSuggestions> } & Partial<SearchSuggestions>
  >(config, path, reqOpts)
  const inner = (data.result ?? data) as Partial<SearchSuggestions>
  return {
    recent: inner.recent ?? [],
    popular: inner.popular ?? [],
    nohits: inner.nohits ?? [],
  }
}
