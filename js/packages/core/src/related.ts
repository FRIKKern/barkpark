// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Tag-weighted related documents fused with backlinks — the weighted-tag READ
// payoff (authoring-excellence D68-D71). Wraps
// `GET /v1/data/related/:dataset/:id`, which fuses a tag-name-overlap leg
// (LEAST(src,cand) strength credit + a main-tag bonus) with an inbound-reference
// leg (reverse_referencers, saturating). Fail-closed server-side: a candidate
// the caller can't see is dropped, never leaked. Each entry carries `score`,
// `sources` (['tags'] / ['references'] / both) and `shared_tags` so a surface
// can render WHY two docs relate.

import { scopePrefix } from './scope'
import { assertSegment } from './util/guards'
import { request } from './transport'
import { BarkparkValidationError } from './errors'
import type { BarkparkClientConfig, RelatedResult, RelatedOptions } from './types'

/**
 * Fetch the documents related to `id` — tag-overlap fused with backlinks
 * (`GET /v1/data/related/:dataset/:id`). Requires a token (the server 404s an
 * anonymous caller, existence-hiding). `limit` caps the fan-out (server default
 * 10, clamped to 50). Prefer `client.getRelated()`.
 */
export async function getRelated(
  config: BarkparkClientConfig,
  id: string,
  opts?: RelatedOptions,
): Promise<RelatedResult> {
  assertSegment(id, 'id')
  if (
    opts?.limit !== undefined &&
    (!Number.isInteger(opts.limit) || opts.limit < 1)
  ) {
    throw new BarkparkValidationError('limit must be a positive integer', { field: 'limit' })
  }
  const qs = opts?.limit !== undefined ? `?limit=${opts.limit}` : ''
  const path =
    `${scopePrefix(config)}/v1/data/related/${encodeURIComponent(config.dataset)}/${encodeURIComponent(id)}${qs}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<RelatedResult & { result?: RelatedResult }>(
    config,
    path,
    reqOpts,
  )
  return (data.result ?? data) as RelatedResult
}
