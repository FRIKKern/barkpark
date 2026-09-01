// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Content graph — traverse the reference graph from a root document, and find
// orphans (no edges) / dangling references (target missing). These are GLOBAL
// routes (`/v1/graph/*`, no workspace/project scope prefix); the dataset rides a
// `?dataset=` query param (server defaults to "production"). Token-gated (read).

import { request } from './transport'
import { assertSegment } from './util/guards'
import { assertNoCommaEntries } from './filter-builder'
import { BarkparkValidationError } from './errors'
import type { BarkparkClientConfig, GraphResult, GraphNode, GraphEdge, GraphOptions } from './types'

/**
 * Traverse the content graph from a root document
 * (`GET /v1/graph/:id`). Returns the reachable `nodes`/`edges`, the inbound
 * `dependents`, and truncation info. `depth` clamps 1..5 server-side. Prefer
 * `client.getGraph()`.
 */
export async function getGraph(
  config: BarkparkClientConfig,
  id: string,
  opts?: GraphOptions,
): Promise<GraphResult> {
  assertSegment(id, 'id')
  if (
    opts?.depth !== undefined &&
    (!Number.isInteger(opts.depth) || opts.depth < 1 || opts.depth > 5)
  ) {
    throw new BarkparkValidationError('depth must be an integer 1..5', { field: 'depth' })
  }
  const qp = new URLSearchParams()
  qp.set('dataset', config.dataset)
  if (opts?.depth !== undefined) qp.set('depth', String(opts.depth))
  if (opts?.direction !== undefined) qp.set('direction', opts.direction)
  // kinds/sources join with ',' (the server splits on it), so a comma inside an
  // entry would silently split into extra values — fail closed like the peer guards.
  if (opts?.kinds !== undefined && opts.kinds.length > 0) {
    assertNoCommaEntries(opts.kinds, 'kinds')
    qp.set('kinds', opts.kinds.join(','))
  }
  if (opts?.sources !== undefined && opts.sources.length > 0) {
    assertNoCommaEntries(opts.sources, 'sources')
    qp.set('sources', opts.sources.join(','))
  }
  // Respect the client's perspective (like doc/docs/search reads do), with a
  // per-call override. GraphOptions.perspective is only 'published'|'drafts' and
  // 'published' is the server default — so we forward a 'drafts' config fallback
  // but never the client's 'raw' perspective (unsupported here). A client-wide
  // 'raw' with no per-call override is fail-loud (not a silent downgrade to
  // published): the caller must pick a supported lens explicitly.
  if (opts?.perspective === undefined && config.perspective === 'raw') {
    throw new BarkparkValidationError(
      "getGraph does not support perspective 'raw'; pass { perspective: 'published' | 'drafts' }",
      { field: 'perspective' },
    )
  }
  const perspective = opts?.perspective ?? (config.perspective === 'drafts' ? 'drafts' : undefined)
  if (perspective !== undefined) qp.set('perspective', perspective)
  const path = `/v1/graph/${encodeURIComponent(id)}?${qp.toString()}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<GraphResult>(config, path, reqOpts)
  return data
}

/**
 * List documents with zero inbound and zero outbound edges
 * (`GET /v1/graph/orphans`). Prefer `client.getOrphans()`.
 */
export async function getOrphans(
  config: BarkparkClientConfig,
  opts?: { signal?: AbortSignal },
): Promise<GraphNode[]> {
  const path = `/v1/graph/orphans?dataset=${encodeURIComponent(config.dataset)}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<{ orphans?: GraphNode[] }>(config, path, reqOpts)
  return data.orphans ?? []
}

/**
 * List broken references — edges whose target is unresolvable under the
 * published lens (`GET /v1/graph/dangling`). Prefer `client.getDangling()`.
 */
export async function getDangling(
  config: BarkparkClientConfig,
  opts?: { signal?: AbortSignal },
): Promise<GraphEdge[]> {
  const path = `/v1/graph/dangling?dataset=${encodeURIComponent(config.dataset)}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<{ dangling?: GraphEdge[] }>(config, path, reqOpts)
  return data.dangling ?? []
}
