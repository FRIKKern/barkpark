// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Read-side operation: single-document fetch.
// GET /v1/data/doc/:dataset/:type/:id → 200 {document fields at top level} | 404 not_found.
// On 404, transport throws BarkparkNotFoundError; getDoc catches and returns { data: null }
// so callers (client.doc) can treat missing as null per ADR-009 / w6.2-impl-spec §Status → class.

import { BarkparkNotFoundError } from './errors'
import { request } from './transport'
import type {
  BarkparkClientConfig,
  BarkparkDocument,
  Perspective,
} from './types'

export interface DocResult<T> {
  data: T | null
  /** Unquoted ETag ( = document _rev). Pass back as ifMatch on writes. */
  etag?: string
}

export interface GetDocOptions {
  perspective?: Perspective
  signal?: AbortSignal
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
 * re-throws every other error per ADR-009. The response's `etag` (= `_rev`,
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
  const perspective = opts?.perspective ?? config.perspective
  const query = perspective !== undefined ? `?perspective=${encodeURIComponent(perspective)}` : ''
  const path = `/v1/data/doc/${encodeURIComponent(config.dataset)}/${encodeURIComponent(type)}/${encodeURIComponent(id)}${query}`

  try {
    const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
    if (opts?.signal !== undefined) reqOpts.signal = opts.signal
    const { data, response } = await request<T>(config, path, reqOpts)
    const etag = stripEtagQuotes(response.headers.get('ETag'))
    const result: DocResult<T> = { data }
    if (etag !== undefined) result.etag = etag
    return result
  } catch (err) {
    if (err instanceof BarkparkNotFoundError) return { data: null }
    throw err
  }
}
