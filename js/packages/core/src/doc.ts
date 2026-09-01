// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Read-side operation: single-document fetch.
// GET /v1/data/doc/:dataset/:type/:id → 200 {result: {document fields}, syncTags, ms, ...} | 404 not_found.
// Envelope is tolerant — when Phoenix's barkpark_filterresponse=true the body is
// { result: T, syncTags, ms, etag, schemaHash }; when disabled it is the flat doc T.
// On 404, transport throws BarkparkNotFoundError; getDoc catches and returns { data: null }
// so callers (client.doc) can treat missing as null (the 404 → null read convention).

import { scopePrefix } from './scope'
import { assertSegment } from './util/guards'
import { BarkparkNotFoundError } from './errors'
import { normalizeFieldList } from './filter-builder'
import { request } from './transport'
import type { BarkparkClientConfig, BarkparkDocument, Perspective } from './types'

export interface DocResult<T> {
  data: T | null
  /** Unquoted ETag ( = document _rev). Pass back as ifMatch on writes. */
  etag?: string
}

export interface GetDocOptions {
  perspective?: Perspective
  signal?: AbortSignal
  /** Inline reference fields — single or `arrayOf`-of-reference — depth 1. Each value
   *  may be a plain id string or a `{_ref}` object. A field name or list, e.g.
   *  `'author'` or `['author', 'tags']`. A missing ref stays a raw id string. */
  expand?: string | string[]
  /** Return only these content fields (projection); system fields (`_id`, …) always
   *  included. A field name or list, e.g. `'title'` or `['title', 'slug']`. */
  fields?: string | string[]
}

function stripEtagQuotes(raw: string | null): string | undefined {
  if (raw === null) return undefined
  const trimmed = raw.replace(/^W\//, '').replace(/^"|"$/g, '')
  return trimmed.length > 0 ? trimmed : undefined
}

/**
 * Fetch a single document by type + id.
 *
 * Returns `{ data: null }` on 404 (callers can treat missing as null) and
 * re-throws every other error. The response's `etag` (= `_rev`,
 * unquoted) is returned when the server included one — callers can pass it
 * back as `ifMatch` on subsequent writes to detect concurrent edits.
 *
 * Prefer `client.doc(type, id)` in app code.
 */
export async function getDoc<T = BarkparkDocument>(
  config: BarkparkClientConfig,
  type: string,
  id: string,
  opts?: GetDocOptions,
): Promise<DocResult<T>> {
  assertSegment(type, 'type')
  assertSegment(id, 'id')
  const perspective = opts?.perspective ?? config.perspective
  const qp = new URLSearchParams()
  if (perspective !== undefined) qp.set('perspective', perspective)
  // Trim/drop-empty + reject comma-in-name via the shared normalizer so a stray
  // '' (→ `fields=title,,slug`) or a comma-carrying name can't corrupt the
  // projection — matching DocsBuilder.expand()/select(). `{ fields: [] }` now
  // throws where it previously shipped a silent no-op.
  if (opts?.expand !== undefined) qp.set('expand', normalizeFieldList(opts.expand, 'expand'))
  if (opts?.fields !== undefined) qp.set('fields', normalizeFieldList(opts.fields, 'fields'))
  const query = qp.toString() ? `?${qp.toString()}` : ''
  const path = `${scopePrefix(config)}/v1/data/doc/${encodeURIComponent(config.dataset)}/${encodeURIComponent(type)}/${encodeURIComponent(id)}${query}`

  try {
    const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
    if (opts?.signal !== undefined) reqOpts.signal = opts.signal
    const { data, response } = await request<T | { result: T }>(config, path, reqOpts)
    const doc =
      data !== null && typeof data === 'object' && 'result' in data
        ? (data as { result: T }).result
        : (data as T)
    const etag = stripEtagQuotes(response.headers.get('ETag'))
    const result: DocResult<T> = { data: doc }
    if (etag !== undefined) result.etag = etag
    return result
  } catch (err) {
    // The absence of ONE document of a valid type is a normal data state, so a
    // 404 here collapses to { data: null }. The LIST executor (docs.ts) does
    // NOT mirror this: its 404 means a missing/private TYPE — a config error
    // the caller must see — and propagates typed. Recorded decision; see the
    // createDocsOperation docstring (D72).
    if (err instanceof BarkparkNotFoundError) return { data: null }
    throw err
  }
}
