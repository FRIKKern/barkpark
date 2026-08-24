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
  type: string
  set: Record<string, unknown>
  setIfMissing: Record<string, unknown>
  unset: string[]
  inc: Record<string, number>
  dec: Record<string, number>
  append: Record<string, unknown[]>
  prepend: Record<string, unknown[]>
  ifMatch?: string
}

// Migration hint for the positional array `insert` op, which is not implemented.
// (Tail/head appends ARE — use patch.append / patch.prepend.)
const ARRAY_OP_HINT =
  'Positional array insert is not implemented in Barkpark Phase 1A. Use patch.append / ' +
  'patch.prepend for tail/head, or read the array, modify it, and patch.set the whole field.'

// System fields Phoenix will not allow in patch.set (content.ex rejects via
// Ecto changesets; we catch at the client boundary for a faster + clearer error).
export const FORBIDDEN_SET_KEYS: ReadonlySet<string> = new Set([
  '_id',
  '_type',
  '_rev',
  '_createdAt',
  '_updatedAt',
  '_draft',
  '_publishedId',
])

/**
 * Assert the append/prepend payload is a list. Shared by {@link createPatch} and the
 * transaction builder's inner patch — four call sites previously carried a verbatim
 * copy of this throw.
 * @internal
 */
export function requireItems(op: string, items: unknown): void {
  if (!Array.isArray(items)) {
    throw new BarkparkValidationError(`patch.${op} requires an array of items`, { field: op })
  }
}

/**
 * Translate a Sanity-style array selector to the top-level field the server's
 * field-based append/prepend operates on. Accepts `field` or `field[index]`
 * (the index is positional sugar — append is always the tail, prepend the head);
 * rejects nested/dotted paths the server can't address, and system fields.
 * Shared by {@link createPatch} and the transaction builder so a selector means
 * the same thing in either.
 * @internal
 */
export function selectorField(op: string, selector: string): string {
  if (typeof selector !== 'string' || selector.length === 0) {
    throw new BarkparkValidationError(`patch.${op} requires a field selector`, { field: op })
  }
  const field = selector.replace(/\[[^\]]*\]\s*$/, '')
  if (field.length === 0 || field.includes('.') || field.includes('[')) {
    throw new BarkparkValidationError(
      `patch.${op} supports a top-level array field (e.g. 'tags' or 'tags[-1]'), not '${selector}'`,
      { field: op },
    )
  }
  if (FORBIDDEN_SET_KEYS.has(field)) {
    throw new BarkparkValidationError(`patch.${op} cannot modify system field: ${field}`, {
      field,
    })
  }
  return field
}

/**
 * Low-level single-document patch builder.
 *
 * Prefer `client.patch(id, type)` in application code. Use this factory when you need
 * to compose a patch without a full client — e.g. inside a helper that only
 * has a config.
 *
 * `.set(fields)` validates + merges into an internal state; `.unset(keys)` removes
 * content keys; `.inc(fields)`/`.dec(fields)` apply numeric deltas (Phase-1B). `.commit()`
 * POSTs a single-mutation request and returns the resulting {@link MutateResult}.
 *
 * @throws BarkparkValidationError on missing id / forbidden set keys / empty commit.
 */
export function createPatch(
  config: BarkparkClientConfig,
  id: string,
  type: string,
): PatchBuilder {
  // `type` is required by the server: /v1/data/mutate dispatches on
  // `%{"patch" => %{"id" => id, "type" => type}}` and falls through to
  // `{:error, :malformed}` without it (api-v1.md §6), so a patch missing `type` never
  // reaches a document. It is enforced in the type signature rather than by a runtime
  // guard: @barkpark/core sits at its 17 KB gzip cap and the guard did not fit.
  if (typeof id !== 'string' || id.length === 0) {
    throw new BarkparkValidationError('patch requires a non-empty document id', { field: 'id' })
  }

  const state: PatchState = {
    id,
    type,
    set: {},
    setIfMissing: {},
    unset: [],
    inc: {},
    dec: {},
    append: {},
    prepend: {},
  }

  // Phoenix implements set/unset/inc/dec/setIfMissing and array append/prepend; only
  // positional array `insert` and `diffMatchPatch` are not yet implemented. They are
  // declared so migrants reaching for them get a clear, actionable error at
  // chain-time (not a cryptic "x is not a function" or a confusing 422).
  const notInPhase1A = (op: string, hint: string): never => {
    throw new BarkparkValidationError(
      `patch.${op} is not implemented in Barkpark Phase 1A. ${hint}`,
      { field: op },
    )
  }

  // Shared validation for inc/dec: a plain object of field→finite-number deltas,
  // no system fields (mirrors set()'s FORBIDDEN_SET_KEYS guard).
  const validateDelta = (op: string, fields: Record<string, number>): void => {
    if (fields === null || typeof fields !== 'object' || Array.isArray(fields)) {
      throw new BarkparkValidationError(`patch.${op} requires a plain object of field→number`, {
        field: op,
      })
    }
    for (const [k, v] of Object.entries(fields)) {
      if (FORBIDDEN_SET_KEYS.has(k)) {
        throw new BarkparkValidationError(`patch.${op} cannot modify system field: ${k}`, {
          field: k,
        })
      }
      if (typeof v !== 'number' || !Number.isFinite(v)) {
        throw new BarkparkValidationError(`patch.${op} requires finite number deltas (${k})`, {
          field: k,
        })
      }
    }
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

    // Phase-1B: increment/decrement numeric fields. A missing field is treated
    // as 0 server-side. inc/dec compose with set/unset in one commit.
    inc(fields) {
      validateDelta('inc', fields)
      Object.assign(state.inc, fields)
      return b
    },

    dec(fields) {
      validateDelta('dec', fields)
      Object.assign(state.dec, fields)
      return b
    },

    // Phase-1B: write fields only where absent (server uses Map.put_new). Same
    // validation as set() — a plain object, no system fields. set() overrides
    // setIfMissing on the same key when both are in one commit.
    setIfMissing(fields) {
      if (fields === null || typeof fields !== 'object' || Array.isArray(fields)) {
        throw new BarkparkValidationError('patch.setIfMissing requires a plain object', {
          field: 'setIfMissing',
        })
      }
      for (const k of Object.keys(fields)) {
        if (FORBIDDEN_SET_KEYS.has(k)) {
          throw new BarkparkValidationError(`patch.setIfMissing cannot modify system field: ${k}`, {
            field: k,
          })
        }
      }
      Object.assign(state.setIfMissing, fields)
      return b
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

    // Phase-1B: extend a top-level array field. The server creates the list if
    // the field is absent and leaves a non-array value untouched.
    append(selector, items) {
      requireItems('append', items)
      const field = selectorField('append', selector)
      state.append[field] = (state.append[field] ?? []).concat(items)
      return b
    },

    prepend(selector, items) {
      requireItems('prepend', items)
      const field = selectorField('prepend', selector)
      state.prepend[field] = (state.prepend[field] ?? []).concat(items)
      return b
    },

    diffMatchPatch(_fields) {
      return notInPhase1A('diffMatchPatch', 'Use patch.set with the full new string value.')
    },

    async commit(opts?: CommitOptions): Promise<MutateResult> {
      if (opts?.ifMatch !== undefined) state.ifMatch = opts.ifMatch

      if (
        Object.keys(state.set).length === 0 &&
        Object.keys(state.setIfMissing).length === 0 &&
        state.unset.length === 0 &&
        Object.keys(state.inc).length === 0 &&
        Object.keys(state.dec).length === 0 &&
        Object.keys(state.append).length === 0 &&
        Object.keys(state.prepend).length === 0
      ) {
        throw new BarkparkValidationError(
          'patch.commit requires at least one set() / setIfMissing() / unset() / inc() / dec() / append() / prepend() call before commit',
          { field: 'set' },
        )
      }

      const patchBody: {
        id: string
        type: string
        set: Record<string, unknown>
        setIfMissing?: Record<string, unknown>
        unset?: string[]
        inc?: Record<string, number>
        dec?: Record<string, number>
        append?: Record<string, unknown[]>
        prepend?: Record<string, unknown[]>
        ifMatch?: string
      } = {
        id: state.id,
        type: state.type,
        set: state.set,
      }
      if (Object.keys(state.setIfMissing).length > 0) patchBody.setIfMissing = state.setIfMissing
      if (state.unset.length > 0) patchBody.unset = state.unset
      if (Object.keys(state.inc).length > 0) patchBody.inc = state.inc
      if (Object.keys(state.dec).length > 0) patchBody.dec = state.dec
      if (Object.keys(state.append).length > 0) patchBody.append = state.append
      if (Object.keys(state.prepend).length > 0) patchBody.prepend = state.prepend
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
        `${scopePrefix(config)}/v1/data/mutate/${encodeURIComponent(config.dataset)}`,
        reqOpts,
      )

      // `?.[0]`: a malformed 2xx that omits `results` would make `results[0]`
      // throw a raw TypeError, bypassing the typed BarkparkAPIError below that
      // is meant to handle exactly a missing/empty results set.
      const first = data.results?.[0]
      if (first === undefined) {
        throw new BarkparkAPIError('mutate response missing results[0]', {
          status: 200,
          body: data,
        })
      }
      // [publish-warnings-dropped] Same carry-through as publish.ts's onlyResult
      // (kept inline rather than imported so this file's typed BarkparkAPIError
      // — status + body, which the validation-flavoured helper does not raise —
      // stays the empty-results signal). The batch is this one patch, so the
      // envelope's advisories are this result's. Omitted when there are none.
      return data.warnings?.length ? { ...first, warnings: data.warnings } : first
    },
  }

  return b
}
