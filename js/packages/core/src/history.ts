// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Document history / revisions — list a document's past versions, fetch one
// (with its content), and restore one (Sanity-style version history). All three
// require a token; the server 404s an unknown revision and returns an empty list
// for an unknown document.

import { scopePrefix } from './scope'
import { assertSegment } from './util/guards'
import { request } from './transport'
import { assertPaging } from './filter-builder'
import { BarkparkNotFoundError, BarkparkValidationError } from './errors'
import type {
  BarkparkClientConfig,
  DocumentRevision,
  RestoreResult,
  HistoryOptions,
  RevisionOptions,
} from './types'

/**
 * List a document's revisions, newest first
 * (`GET /v1/data/history/:dataset/:type/:id`). An unknown document yields `[]`.
 * Prefer `client.getHistory()`.
 */
export async function getHistory(
  config: BarkparkClientConfig,
  type: string,
  id: string,
  opts?: HistoryOptions,
): Promise<DocumentRevision[]> {
  assertPaging(opts?.limit)
  assertSegment(type, 'type')
  assertSegment(id, 'id')
  const qp = new URLSearchParams()
  if (opts?.limit !== undefined) qp.set('limit', String(opts.limit))
  const query = qp.toString() ? `?${qp.toString()}` : ''
  const path = `${scopePrefix(config)}/v1/data/history/${encodeURIComponent(config.dataset)}/${encodeURIComponent(type)}/${encodeURIComponent(id)}${query}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<{ revisions?: DocumentRevision[] }>(config, path, reqOpts)
  return data.revisions ?? []
}

/**
 * Fetch one revision (with its `content`)
 * (`GET /v1/data/revision/:dataset/:revId`). Returns `null` on 404. Prefer
 * `client.getRevision()`.
 */
export async function getRevision(
  config: BarkparkClientConfig,
  revId: string,
  opts?: RevisionOptions,
): Promise<DocumentRevision | null> {
  assertSegment(revId, 'revId')
  const path = `${scopePrefix(config)}/v1/data/revision/${encodeURIComponent(config.dataset)}/${encodeURIComponent(revId)}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  try {
    const { data } = await request<{ revision?: DocumentRevision }>(config, path, reqOpts)
    return data.revision ?? null
  } catch (err) {
    if (err instanceof BarkparkNotFoundError) return null
    throw err
  }
}

/**
 * Restore a revision — writes its content back as a new draft
 * (`POST /v1/data/revision/:dataset/:revId/restore`). Returns
 * `{ restored, document }`. Prefer `client.restoreRevision()`.
 */
export async function restoreRevision(
  config: BarkparkClientConfig,
  revId: string,
  type: string,
  opts?: RevisionOptions,
): Promise<RestoreResult> {
  assertSegment(revId, 'revId')
  if (typeof type !== 'string' || type.length === 0)
    throw new BarkparkValidationError('restoreRevision requires a non-empty type', {
      field: 'type',
    })
  const path = `${scopePrefix(config)}/v1/data/revision/${encodeURIComponent(config.dataset)}/${encodeURIComponent(revId)}/restore`
  const reqOpts: {
    method: 'POST'
    body: { type: string }
    kind: 'write'
    signal?: AbortSignal
  } = { method: 'POST', body: { type }, kind: 'write' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<RestoreResult>(config, path, reqOpts)
  return data
}
