// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Read-side operation: single-document fetch.
// GET /v1/data/doc/:dataset/:type/:id → 200 {result: {document fields}, syncTags, ms, ...} | 404 not_found.
// Envelope is tolerant — when Phoenix's barkpark_filterresponse=true the body is
// { result: T, syncTags, ms, etag, schemaHash }; when disabled it is the flat doc T.
// `DocResult.etag` comes out of THAT BODY (`etag` in the envelope shape, the
// document's `_rev` in the flat one) and never out of the HTTP `ETag` response
// header — the two are different tokens; see the `DocResult.etag` docstring.
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
  /**
   * The document's `_rev` — a WRITE PRECONDITION token. Pass it back as
   * `ifMatch` on a subsequent write to detect a concurrent edit
   * (`Barkpark.Content.Mutations.if_rev/1` compares `ifMatch` to the stored
   * rev).
   *
   * Read out of the RESPONSE BODY: the `etag` field in the filtered (default)
   * envelope, the document's own `_rev` in the flat shape. Deliberately NOT the
   * HTTP `ETag` response header — that header is a CACHE VALIDATOR ("is the
   * cached REPRESENTATION still valid?", RFC 9110 §8.8.1) and folds the dataset
   * schema hash on top of the document rev, because the rendered field set is a
   * function of the schema and a schema edit moves no `_rev`. Sending the
   * header value as `ifMatch` gets `rev_mismatch` (412).
   */
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

// The document rev, out of the response BODY.
//
// Filtered (default) envelope: the envelope's own `etag` field, which Phoenix
// sets to the bare `_rev` (api/lib/barkpark_web/controllers/query_controller.ex
// `doc_etag/1`). Flat shape (`barkpark_filterresponse=false`): the document's
// own `_rev`. The envelope path falls back to the document when a server omits
// the field, so a partial envelope degrades to the same token rather than to
// `undefined`.
function bodyRev(envelope: { etag?: unknown } | null, doc: unknown): string | undefined {
  if (envelope !== null) {
    const fromEnvelope = envelope.etag
    if (typeof fromEnvelope === 'string' && fromEnvelope.length > 0) return fromEnvelope
  }
  if (doc !== null && typeof doc === 'object') {
    const fromDoc = (doc as { _rev?: unknown })._rev
    if (typeof fromDoc === 'string' && fromDoc.length > 0) return fromDoc
  }
  return undefined
}

/**
 * Fetch a single document by type + id.
 *
 * Returns `{ data: null }` on 404 (callers can treat missing as null) and
 * re-throws every other error. `etag` is the document's `_rev`, lifted from the
 * response BODY (the envelope's `etag` field, or the document's `_rev` in the
 * flat shape) — callers pass it back as `ifMatch` on subsequent writes to
 * detect concurrent edits. It is NOT the HTTP `ETag` response header: that is a
 * cache validator over the whole representation and additionally folds the
 * dataset schema hash, so passing it as `ifMatch` 412s.
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
    const { data } = await request<T | { result: T }>(config, path, reqOpts)
    const envelope =
      data !== null && typeof data === 'object' && 'result' in data
        ? (data as { result: T; etag?: unknown })
        : null
    const doc = envelope !== null ? envelope.result : (data as T)
    const etag = bodyRev(envelope, doc)
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
