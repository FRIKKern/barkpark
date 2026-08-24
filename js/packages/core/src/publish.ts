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
 * Narrow a single-mutation envelope to its one result — and CARRY the batch's
 * advisories onto it.
 *
 * [publish-warnings-dropped] The publish wall queues non-blocking advisories
 * while `publish` / `unpublish` / `discardDraft` apply (the label-spine norm,
 * the E4 dedup wall's advise band), and `MutateController` drains them onto the
 * 200 body as `warnings` (mutate_controller.ex). All three of these functions
 * then narrowed the envelope to `results[0]` and let `data.warnings` fall on the
 * floor — so the calls the advisory channel exists FOR were the only calls that
 * could not see it. `MutateEnvelope.warnings` had been declared in types.ts
 * since the channel shipped and no runtime path in this package read it once.
 * `client.create/replace/delete` never had the bug: they return the whole
 * envelope.
 *
 * The request carries exactly one mutation, so the batch's advisories ARE this
 * result's advisories. Omitted (never `[]`) when the server sent none, mirroring
 * the server's own omit-when-empty shape — so `'warnings' in result` is a
 * truthful test rather than one that is always true.
 */
export function onlyResult(data: MutateEnvelope, op: string): MutateResult {
  const first = data.results?.[0]
  if (!first) {
    throw new BarkparkValidationError(`${op}: server returned empty results`, { field: 'results' })
  }
  return data.warnings?.length ? { ...first, warnings: data.warnings } : first
}

/**
 * The one request the three publish-lifecycle helpers below share.
 *
 * They were three byte-identical copies differing only in the mutation key and
 * two strings; folding them pays for the advisory carry-through above (core is
 * on a hard gzipped budget — see js/CLAUDE.md "Bundle budget"). Both messages
 * are reproduced verbatim from the copies: `${op}Doc requires id and type` and,
 * in `onlyResult`, `${op}: server returned empty results`.
 */
async function lifecycleMutation(
  config: BarkparkClientConfig,
  op: 'publish' | 'unpublish' | 'discardDraft',
  id: string,
  type: string,
  opts?: CommitOptions,
): Promise<MutateResult> {
  if (!id || !type) {
    throw new BarkparkValidationError(`${op}Doc requires id and type`, {
      field: !id ? 'id' : 'type',
    })
  }
  const { data } = await request<MutateEnvelope>(
    config,
    `${scopePrefix(config)}/v1/data/mutate/${encodeURIComponent(config.dataset)}`,
    {
      method: 'POST',
      body: { mutations: [{ [op]: { id, type } }] },
      kind: 'write',
      ...commitOptions(opts),
    },
  )
  return onlyResult(data, op)
}

/**
 * Publish a draft document.
 *
 * Copies `drafts.{id}` → `{id}` and deletes the draft in one Phoenix transaction.
 * Returns the resulting {@link MutateResult} with `operation: 'publish'`, plus
 * any publish-wall `warnings` the write raised (see {@link onlyResult}).
 * Prefer `client.publish(id, type)`. `opts` forwards retry / idempotencyKey /
 * timeoutMs to the write request, just like the transaction commit path.
 */
export async function publishDoc(
  config: BarkparkClientConfig,
  id: string,
  type: string,
  opts?: CommitOptions,
): Promise<MutateResult> {
  return lifecycleMutation(config, 'publish', id, type, opts)
}

/**
 * Unpublish (move back to draft) a published document.
 *
 * Moves `{id}` → `drafts.{id}`. Returns the resulting {@link MutateResult}
 * with `operation: 'unpublish'` plus any publish-wall `warnings` (see
 * {@link onlyResult}). Prefer `client.unpublish(id, type)`. `opts`
 * forwards retry / idempotencyKey / timeoutMs to the write request.
 */
export async function unpublishDoc(
  config: BarkparkClientConfig,
  id: string,
  type: string,
  opts?: CommitOptions,
): Promise<MutateResult> {
  return lifecycleMutation(config, 'unpublish', id, type, opts)
}

/**
 * Discard a draft's unsaved edits.
 *
 * Drops `drafts.{id}` (reverting to the published `{id}`, which is left
 * unchanged) — Sanity's "discard changes". Returns the resulting
 * {@link MutateResult} with `operation: 'discardDraft'` plus any publish-wall
 * `warnings` (see {@link onlyResult}).
 * Prefer `client.discardDraft(id, type)`. `opts` forwards retry /
 * idempotencyKey / timeoutMs to the write request.
 */
export async function discardDraftDoc(
  config: BarkparkClientConfig,
  id: string,
  type: string,
  opts?: CommitOptions,
): Promise<MutateResult> {
  return lifecycleMutation(config, 'discardDraft', id, type, opts)
}
