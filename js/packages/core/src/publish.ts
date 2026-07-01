// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { BarkparkClientConfig, CommitOptions, MutateEnvelope, MutateResult } from './types'
import { request } from './transport'
import { scopePrefix } from './scope'
import { BarkparkValidationError } from './errors'

/**
 * Thread {@link CommitOptions} onto a single-mutation write request the same way
 * `createTransaction().commit` does: idempotency key → header, `retry` → retry
 * policy, `timeoutMs` → per-call override. Keeps the three publish-lifecycle
 * conveniences symmetric with `create` / `delete`.
 */
function commitOptions(opts?: CommitOptions): {
  headers: Record<string, string>
  retryPolicy: 'none' | 'on-idempotency-key'
  timeoutMs?: number
} {
  const headers: Record<string, string> = {}
  if (opts?.idempotencyKey !== undefined && opts.idempotencyKey.length > 0) {
    headers['Idempotency-Key'] = opts.idempotencyKey
  }
  return {
    headers,
    retryPolicy: opts?.retry === true ? 'on-idempotency-key' : 'none',
    ...(opts?.timeoutMs !== undefined ? { timeoutMs: opts.timeoutMs } : {}),
  }
}

/**
 * Publish a draft document.
 *
 * Copies `drafts.{id}` → `{id}` and deletes the draft in one Phoenix transaction.
 * Returns the resulting {@link MutateResult} with `operation: 'publish'`.
 * Prefer `client.publish(id, type)`. `opts` forwards retry / idempotencyKey /
 * timeoutMs to the write request, just like the transaction commit path.
 */
export async function publishDoc(
  config: BarkparkClientConfig,
  id: string,
  type: string,
  opts?: CommitOptions,
): Promise<MutateResult> {
  if (!id || !type) {
    throw new BarkparkValidationError('publishDoc requires id and type', {
      field: !id ? 'id' : 'type',
    })
  }
  const { data } = await request<MutateEnvelope>(
    config,
    `${scopePrefix(config)}/v1/data/mutate/${config.dataset}`,
    {
      method: 'POST',
      body: { mutations: [{ publish: { id, type } }] },
      kind: 'write',
      ...commitOptions(opts),
    },
  )
  const first = data.results[0]
  if (!first) {
    throw new BarkparkValidationError('publish: server returned empty results', {
      field: 'results',
    })
  }
  return first
}

/**
 * Unpublish (move back to draft) a published document.
 *
 * Moves `{id}` → `drafts.{id}`. Returns the resulting {@link MutateResult}
 * with `operation: 'unpublish'`. Prefer `client.unpublish(id, type)`. `opts`
 * forwards retry / idempotencyKey / timeoutMs to the write request.
 */
export async function unpublishDoc(
  config: BarkparkClientConfig,
  id: string,
  type: string,
  opts?: CommitOptions,
): Promise<MutateResult> {
  if (!id || !type) {
    throw new BarkparkValidationError('unpublishDoc requires id and type', {
      field: !id ? 'id' : 'type',
    })
  }
  const { data } = await request<MutateEnvelope>(
    config,
    `${scopePrefix(config)}/v1/data/mutate/${config.dataset}`,
    {
      method: 'POST',
      body: { mutations: [{ unpublish: { id, type } }] },
      kind: 'write',
      ...commitOptions(opts),
    },
  )
  const first = data.results[0]
  if (!first) {
    throw new BarkparkValidationError('unpublish: server returned empty results', {
      field: 'results',
    })
  }
  return first
}

/**
 * Discard a draft's unsaved edits.
 *
 * Drops `drafts.{id}` (reverting to the published `{id}`, which is left
 * unchanged) — Sanity's "discard changes". Returns the resulting
 * {@link MutateResult} with `operation: 'discardDraft'`.
 * Prefer `client.discardDraft(id, type)`. `opts` forwards retry /
 * idempotencyKey / timeoutMs to the write request.
 */
export async function discardDraftDoc(
  config: BarkparkClientConfig,
  id: string,
  type: string,
  opts?: CommitOptions,
): Promise<MutateResult> {
  if (!id || !type) {
    throw new BarkparkValidationError('discardDraftDoc requires id and type', {
      field: !id ? 'id' : 'type',
    })
  }
  const { data } = await request<MutateEnvelope>(
    config,
    `${scopePrefix(config)}/v1/data/mutate/${config.dataset}`,
    {
      method: 'POST',
      body: { mutations: [{ discardDraft: { id, type } }] },
      kind: 'write',
      ...commitOptions(opts),
    },
  )
  const first = data.results[0]
  if (!first) {
    throw new BarkparkValidationError('discardDraft: server returned empty results', {
      field: 'results',
    })
  }
  return first
}
