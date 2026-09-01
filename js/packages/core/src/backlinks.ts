// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Inbound references — the documents that reference a given doc (Sanity's
// `*[references($id)]`, Notion-style backlinks). Wraps
// `GET /v1/data/backlinks/:dataset/:id`, which is fail-closed server-side:
// referencing sources the caller can't see are dropped, never leaked.

import { scopePrefix } from './scope'
import { assertSegment } from './util/guards'
import { request } from './transport'
import type { BarkparkClientConfig, BacklinksResult, BacklinksOptions } from './types'

/**
 * Fetch the documents that reference `id` (inbound references / backlinks).
 * `GET /v1/data/backlinks/:dataset/:id`. Requires a token (the server 404s an
 * anonymous caller, existence-hiding). Prefer `client.getBacklinks()`.
 */
export async function getBacklinks(
  config: BarkparkClientConfig,
  id: string,
  opts?: BacklinksOptions,
): Promise<BacklinksResult> {
  assertSegment(id, 'id')
  const path = `${scopePrefix(config)}/v1/data/backlinks/${encodeURIComponent(config.dataset)}/${encodeURIComponent(id)}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<BacklinksResult & { result?: BacklinksResult }>(
    config,
    path,
    reqOpts,
  )
  return (data.result ?? data) as BacklinksResult
}
