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
  total?: number // present only with ?count=true
  // TRUNCATION SIGNAL — the server answers this exactly, for free, on every
  // query (query_controller.ex reads one row past the page). Optional here only
  // because a server older than that field omits it; it is not optional on the
  // wire today. See the QueryPage docs for why deriving it from `count` is wrong.
  hasMore?: boolean
  // The offset that reads the next page. Present only when one exists, and
  // withheld past the server's 100_000 offset ceiling where a further read would
  // re-serve the same page rather than advance.
  nextOffset?: number
}

/**
 * Build a fluent filter/order/limit/offset query against a document type.
 *
 * Returns a {@link DocsBuilder} whose `.find()` / `.findOne()` hit the wire.
 * `.where(field, op, value)` chains; see {@link FilterOp} for supported ops.
 * Prefer `client.docs(type)` — this factory is for config-only callers.
 *
 * ERROR SEMANTICS — DECIDED, deliberately asymmetric to `getDoc`
 * (site-spawner-backlog-core-list-404-swallow, wave-7 D72):
 *
 * - A PUBLIC type with zero matching documents is a 200 with an empty page:
 *   `.find()` resolves `[]`, `.findOne()` resolves `null`. Absence of DATA is
 *   a normal state, not an error.
 * - A missing or private TYPE is a 404: `.find()` / `.findOne()` REJECT with
 *   the typed `BarkparkNotFoundError` (status + serverCode intact). This is a
 *   misconfiguration signal the caller must see — a schema-name typo, or a
 *   doc_type that is private for this token. Swallowing it to `[]` would make
 *   a misconfigured site indistinguishable from an empty one at build time.
 * - `getDoc` maps its 404 to `{ data: null }` because the absence of ONE
 *   document of a valid type IS a normal data state — the asymmetry is the
 *   point, not an oversight. Consumers that prefer an empty page can guard
 *   in-page (the D72 next-starter precedent).
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
    parts.push(...extra)
    const query = parts.length > 0 ? `?${parts.join('&')}` : ''
    return `${scopePrefix(config)}/v1/data/query/${encodeURIComponent(config.dataset)}/${encodeURIComponent(type)}${query}`
  }

  const reqOpts = (): { kind: 'read'; signal?: AbortSignal } => {
    const o: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
    if (opts?.signal !== undefined) o.signal = opts.signal
    return o
  }

  // The one request all three executors share. They were three copies of the
  // same `request(config, buildPath(...), reqOpts())` call differing only in the
  // extra query params; folding it pays for the two fields findPage now carries
  // (core is on a hard gzipped budget — js/CLAUDE.md "Bundle budget"). The
  // envelope is returned UNWRAPPED-BY-THE-CALLER on purpose: `find` and `count`
  // keep their own `data.result?.x ?? data.x` fallback chains verbatim, which
  // differ from `page`'s `data.result ?? data`, and quietly unifying them here
  // would be a behaviour change smuggled in as a refactor.
  const read = async (state: BuilderState, extra: string[]) => {
    const { data } = await request<QueryResultBody<T> & { result?: QueryResultBody<T> }>(
      config,
      buildPath(state, extra),
      reqOpts(),
    )
    return data
  }

  return createDocsBuilder<T>(
    async (state: BuilderState) => {
      const data = await read(state, [])
      return data.result?.documents ?? data.documents ?? []
    },
    // count executor: same filters, but `?count=true` and a minimal page (the
    // total is independent of limit/offset; we only read result.total).
    async (state: BuilderState) => {
      const data = await read({ ...state, limit: 1 }, ['count=true'])
      return data.result?.total ?? data.total ?? 0
    },
    // page executor: the page AND the total in one `?count=true` request,
    // keeping the caller's limit/offset.
    async (state: BuilderState) => {
      const data = await read(state, ['count=true'])
      const body = data.result ?? data
      return {
        documents: body.documents ?? [],
        total: body.total ?? 0,
        count: body.count ?? body.documents?.length ?? 0,
        limit: body.limit ?? 0,
        offset: body.offset ?? 0,
        // [page-truncation-derived] The server's own exact answer, which this
        // executor used to read off the wire and throw away. Callers were left
        // deriving truncation from `count`/`total` — and `count === limit` is
        // the classic wrong derivation: a type holding exactly `limit` rows and
        // one holding a million are byte-identical under it. `?? false` covers
        // only a server too old to send the field; today's always does.
        hasMore: body.hasMore ?? false,
        // Omitted, not zero, when there is no next page — so `nextOffset` is
        // never a valid-looking offset that re-serves the page you just read.
        ...(body.nextOffset !== undefined ? { nextOffset: body.nextOffset } : {}),
      }
    },
  )
}
