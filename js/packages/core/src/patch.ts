// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type {
  BarkparkClientConfig,
  CommitOptions,
  MutateEnvelope,
  MutateResult,
  PatchBuilder,
} from './types'
import { request, type TransportRequestOptions } from './transport'
import { BarkparkAPIError, BarkparkValidationError } from './errors'

interface PatchState {
  id: string
  set: Record<string, unknown>
  ifMatch?: string
}

// System fields Phoenix will not allow in patch.set (content.ex rejects via
// Ecto changesets; we catch at the client boundary for a faster + clearer error).
const FORBIDDEN_SET_KEYS = new Set([
  '_id',
  '_type',
  '_rev',
  '_createdAt',
  '_updatedAt',
  '_draft',
  '_publishedId',
])

/**
 * Low-level single-document patch builder.
 *
 * Prefer `client.patch(id)` in application code. Use this factory when you need
 * to compose a patch without a full client — e.g. inside a helper that only
 * has a config.
 *
 * `.set(fields)` validates + merges into an internal state. `.inc()` throws
 * synchronously: Phoenix Phase 1A does not implement `patch.inc`. `.commit()`
 * POSTs a single-mutation request and returns the resulting {@link MutateResult}.
 *
 * @throws BarkparkValidationError on missing id / forbidden set keys / empty commit.
 */
export function createPatch(config: BarkparkClientConfig, id: string): PatchBuilder {
  if (typeof id !== 'string' || id.length === 0) {
    throw new BarkparkValidationError('patch requires a non-empty document id', { field: 'id' })
  }

  const state: PatchState = { id, set: {} }

  const b: PatchBuilder = {
    set(fields) {
      if (fields === null || typeof fields !== 'object' || Array.isArray(fields)) {
        throw new BarkparkValidationError('patch.set requires a plain object', { field: 'set' })
      }
      for (const k of Object.keys(fields)) {
        if (FORBIDDEN_SET_KEYS.has(k)) {
          throw new BarkparkValidationError(
            `patch.set cannot modify system field: ${k}`,
            { field: k },
          )
        }
      }
      Object.assign(state.set, fields)
      return b
    },

    // Phoenix Phase 1A does NOT implement patch.inc (see w6.3-phoenix-contract.md §mutate).
    // Throw eagerly at chain-time so callers discover the limitation immediately rather
    // than via a confusing 422 at commit time.
    inc(_fields) {
      throw new BarkparkValidationError(
        "patch.inc is not implemented in Barkpark Phase 1A. " +
          "Use patch.set with a pre-computed value, or roll a transaction with createOrReplace.",
        { field: 'inc' },
      )
    },

    async commit(opts?: CommitOptions): Promise<MutateResult> {
      if (opts?.ifMatch !== undefined) state.ifMatch = opts.ifMatch

      if (Object.keys(state.set).length === 0) {
        throw new BarkparkValidationError(
          'patch.commit requires at least one set() call before commit',
          { field: 'set' },
        )
      }

      const patchBody: { id: string; set: Record<string, unknown>; ifMatch?: string } = {
        id: state.id,
        set: state.set,
      }
      if (state.ifMatch !== undefined) patchBody.ifMatch = state.ifMatch

      const body = { mutations: [{ patch: patchBody }] }

      const reqOpts: TransportRequestOptions = {
        method: 'POST',
        body,
        kind: 'write',
      }
      if (opts?.idempotencyKey !== undefined && opts.idempotencyKey.length > 0) {
        reqOpts.headers = { 'Idempotency-Key': opts.idempotencyKey }
      }
      if (opts?.retry === true) {
        reqOpts.retryPolicy = 'on-idempotency-key'
      }

      const { data } = await request<MutateEnvelope>(
        config,
        `/v1/data/mutate/${config.dataset}`,
        reqOpts,
      )

      const first = data.results[0]
      if (first === undefined) {
        throw new BarkparkAPIError('mutate response missing results[0]', {
          status: 200,
          body: data,
        })
      }
      return first
    },
  }

  return b
}

/** @deprecated alias preserved for the index.ts barrel; prefer createPatch */
export const patch = (config: BarkparkClientConfig, id: string): PatchBuilder =>
  createPatch(config, id)
