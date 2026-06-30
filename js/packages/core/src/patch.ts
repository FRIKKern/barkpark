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
import { scopePrefix } from './scope'
import { BarkparkAPIError, BarkparkValidationError } from './errors'

interface PatchState {
  id: string
  set: Record<string, unknown>
  unset: string[]
  ifMatch?: string
}

// Shared migration hint for the array-mutation ops (insert/append/prepend).
const ARRAY_OP_HINT =
  'Array mutations are not implemented in Barkpark Phase 1A. Read the array, modify it, ' +
  'and patch.set the whole field — or roll a transaction with createOrReplace.'

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

  const state: PatchState = { id, set: {}, unset: [] }

  // Phoenix Phase 1A implements only `patch.set`. The other Sanity-style patch
  // ops are declared so migrants reaching for them get a clear, actionable error
  // at chain-time (not a cryptic "x is not a function" or a confusing 422).
  const notInPhase1A = (op: string, hint: string): never => {
    throw new BarkparkValidationError(
      `patch.${op} is not implemented in Barkpark Phase 1A. ${hint}`,
      { field: op },
    )
  }

  const b: PatchBuilder = {
    set(fields) {
      if (fields === null || typeof fields !== 'object' || Array.isArray(fields)) {
        throw new BarkparkValidationError('patch.set requires a plain object', { field: 'set' })
      }
      for (const k of Object.keys(fields)) {
        if (FORBIDDEN_SET_KEYS.has(k)) {
          throw new BarkparkValidationError(`patch.set cannot modify system field: ${k}`, {
            field: k,
          })
        }
      }
      Object.assign(state.set, fields)
      return b
    },

    // Phase 1A unimplemented ops — see w6.3-phoenix-contract.md §mutate. Throw
    // eagerly at chain-time so callers discover the limitation immediately.
    inc(_fields) {
      return notInPhase1A(
        'inc',
        'Use patch.set with a pre-computed value, or roll a transaction with createOrReplace.',
      )
    },

    dec(_fields) {
      return notInPhase1A(
        'dec',
        'Use patch.set with a pre-computed value, or roll a transaction with createOrReplace.',
      )
    },

    setIfMissing(_fields) {
      return notInPhase1A(
        'setIfMissing',
        'Use patch.set (read the document first for set-if-missing semantics), or createIfNotExists for the whole document.',
      )
    },

    // Phase-1B: remove content keys. Validated like set() — an array of strings,
    // none of them a system field — then sent as patch.unset (Phoenix's unset
    // clause also protects the promoted/system fields server-side).
    unset(keys) {
      if (!Array.isArray(keys)) {
        throw new BarkparkValidationError('patch.unset requires an array of field names', {
          field: 'unset',
        })
      }
      for (const k of keys) {
        if (typeof k !== 'string') {
          throw new BarkparkValidationError('patch.unset field names must be strings', {
            field: 'unset',
          })
        }
        if (FORBIDDEN_SET_KEYS.has(k)) {
          throw new BarkparkValidationError(`patch.unset cannot remove system field: ${k}`, {
            field: k,
          })
        }
      }
      for (const k of keys) {
        if (!state.unset.includes(k)) state.unset.push(k)
      }
      return b
    },

    insert(_at, _selector, _items) {
      return notInPhase1A('insert', ARRAY_OP_HINT)
    },

    append(_selector, _items) {
      return notInPhase1A('append', ARRAY_OP_HINT)
    },

    prepend(_selector, _items) {
      return notInPhase1A('prepend', ARRAY_OP_HINT)
    },

    diffMatchPatch(_fields) {
      return notInPhase1A('diffMatchPatch', 'Use patch.set with the full new string value.')
    },

    async commit(opts?: CommitOptions): Promise<MutateResult> {
      if (opts?.ifMatch !== undefined) state.ifMatch = opts.ifMatch

      if (Object.keys(state.set).length === 0 && state.unset.length === 0) {
        throw new BarkparkValidationError(
          'patch.commit requires at least one set() or unset() call before commit',
          { field: 'set' },
        )
      }

      const patchBody: {
        id: string
        set: Record<string, unknown>
        unset?: string[]
        ifMatch?: string
      } = {
        id: state.id,
        set: state.set,
      }
      if (state.unset.length > 0) patchBody.unset = state.unset
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
      // Forward the documented per-call timeout override (CommitOptions.timeoutMs).
      if (opts?.timeoutMs !== undefined) {
        reqOpts.timeoutMs = opts.timeoutMs
      }

      const { data } = await request<MutateEnvelope>(
        config,
        `${scopePrefix(config)}/v1/data/mutate/${config.dataset}`,
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
