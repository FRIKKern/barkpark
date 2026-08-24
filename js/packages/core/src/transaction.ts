// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type {
  BarkparkClientConfig,
  TransactionBuilder,
  CommitOptions,
  MutateEnvelope,
  PatchBuilder,
  BarkparkDocument,
} from './types'
import { request } from './transport'
import { scopePrefix } from './scope'
import { FORBIDDEN_SET_KEYS, requireItems, selectorField } from './patch'
import { BarkparkValidationError } from './errors'

type Mutation =
  | { create: Partial<BarkparkDocument> & { _type: string } }
  | { createOrReplace: Partial<BarkparkDocument> & { _id: string; _type: string } }
  | { createIfNotExists: Partial<BarkparkDocument> & { _id: string; _type: string } }
  | {
      patch: {
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
      }
    }
  | { publish: { id: string; type: string } }
  | { unpublish: { id: string; type: string } }
  | { discardDraft: { id: string; type: string } }
  | { delete: { id: string; type: string; ifMatch?: string } }

/**
 * Build a multi-mutation transaction.
 *
 * All ops commit atomically via Phoenix's `Repo.transaction` — any failure rolls
 * the entire batch back, so partial state is never persisted. Prefer
 * `client.transaction()`; this factory is for callers that only have a config.
 *
 * The inner `patch()` takes a builder callback: call `.set()` on the mini-builder
 * to accumulate field changes. Do NOT call the inner `.commit()` — use `tx.commit()`.
 *
 * @example
 *   await createTransaction(config)
 *     .patch('p1', 'post', (p) => p.set({ title: 'Hi' }), { ifMatch: rev })
 *     .publish('p1', 'post')
 *     .commit()
 */
export function createTransaction(config: BarkparkClientConfig): TransactionBuilder {
  const mutations: Mutation[] = []

  const tx: TransactionBuilder = {
    create(doc) {
      if (
        !doc ||
        typeof doc !== 'object' ||
        !('_type' in doc) ||
        typeof (doc as { _type?: unknown })._type !== 'string'
      ) {
        throw new BarkparkValidationError('transaction.create requires a doc with _type', {
          field: '_type',
        })
      }
      mutations.push({ create: doc })
      return tx
    },
    createOrReplace(doc) {
      if (!doc || !doc._id || !doc._type) {
        throw new BarkparkValidationError('transaction.createOrReplace requires _id and _type', {
          field: '_id',
        })
      }
      mutations.push({ createOrReplace: doc })
      return tx
    },
    createIfNotExists(doc) {
      if (!doc || !doc._id || !doc._type) {
        throw new BarkparkValidationError('transaction.createIfNotExists requires _id and _type', {
          field: '_id',
        })
      }
      mutations.push({ createIfNotExists: doc })
      return tx
    },
    patch(id, type, build, opts) {
      // `type` is required by the server (api-v1.md §6) and enforced in the signature,
      // mirroring publish/unpublish/delete, which have always taken (id, type).
      if (typeof id !== 'string' || id.length === 0) {
        throw new BarkparkValidationError('transaction.patch requires a non-empty document id', {
          field: 'id',
        })
      }
      const set: Record<string, unknown> = {}
      const setIfMissing: Record<string, unknown> = {}
      const unset: string[] = []
      const inc: Record<string, number> = {}
      const dec: Record<string, number> = {}
      const append: Record<string, unknown[]> = {}
      const prepend: Record<string, unknown[]> = {}

      // Local validators — mirror the standalone createPatch builder so a patch
      // means the same thing inside or outside a transaction.
      const assertObject = (op: string, fields: unknown): void => {
        if (fields == null || typeof fields !== 'object' || Array.isArray(fields)) {
          throw new BarkparkValidationError(`patch.${op} requires an object`, { field: op })
        }
      }
      const assertNotForbidden = (op: string, keys: string[]): void => {
        for (const k of keys) {
          if (FORBIDDEN_SET_KEYS.has(k)) {
            throw new BarkparkValidationError(`patch.${op} cannot modify ${k}`, { field: k })
          }
        }
      }
      const accumulateDelta = (
        op: string,
        target: Record<string, number>,
        fields: Record<string, number>,
      ): void => {
        assertObject(op, fields)
        assertNotForbidden(op, Object.keys(fields))
        for (const [k, v] of Object.entries(fields)) {
          if (typeof v !== 'number' || !Number.isFinite(v)) {
            throw new BarkparkValidationError(`patch.${op} requires finite number deltas (${k})`, {
              field: k,
            })
          }
        }
        Object.assign(target, fields)
      }

      const miniBuilder: PatchBuilder = {
        set(fields) {
          assertObject('set', fields)
          assertNotForbidden('set', Object.keys(fields))
          Object.assign(set, fields)
          return miniBuilder
        },
        inc(fields) {
          accumulateDelta('inc', inc, fields)
          return miniBuilder
        },
        dec(fields) {
          accumulateDelta('dec', dec, fields)
          return miniBuilder
        },
        setIfMissing(fields) {
          assertObject('setIfMissing', fields)
          assertNotForbidden('setIfMissing', Object.keys(fields))
          Object.assign(setIfMissing, fields)
          return miniBuilder
        },
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
          }
          assertNotForbidden('unset', keys)
          for (const k of keys) if (!unset.includes(k)) unset.push(k)
          return miniBuilder
        },
        insert(_at, _selector, _items) {
          throw new BarkparkValidationError('patch.insert not implemented in Phase 1A', {
            field: 'insert',
          })
        },
        append(selector, items) {
          requireItems('append', items)
          const field = selectorField('append', selector)
          append[field] = (append[field] ?? []).concat(items)
          return miniBuilder
        },
        prepend(selector, items) {
          requireItems('prepend', items)
          const field = selectorField('prepend', selector)
          prepend[field] = (prepend[field] ?? []).concat(items)
          return miniBuilder
        },
        diffMatchPatch(_fields) {
          throw new BarkparkValidationError('patch.diffMatchPatch not implemented in Phase 1A', {
            field: 'diffMatchPatch',
          })
        },
        async commit() {
          throw new BarkparkValidationError(
            'inner patch.commit() is not valid inside transaction — use tx.commit()',
            { field: 'commit' },
          )
        },
      }
      build(miniBuilder)
      if (
        Object.keys(set).length === 0 &&
        Object.keys(setIfMissing).length === 0 &&
        unset.length === 0 &&
        Object.keys(inc).length === 0 &&
        Object.keys(dec).length === 0 &&
        Object.keys(append).length === 0 &&
        Object.keys(prepend).length === 0
      ) {
        throw new BarkparkValidationError(`patch on ${id} inside transaction had no operations`, {
          field: 'set',
        })
      }
      const patchOp: {
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
      } = { id, type, set }
      if (Object.keys(setIfMissing).length > 0) patchOp.setIfMissing = setIfMissing
      if (unset.length > 0) patchOp.unset = unset
      if (Object.keys(inc).length > 0) patchOp.inc = inc
      if (Object.keys(dec).length > 0) patchOp.dec = dec
      if (Object.keys(append).length > 0) patchOp.append = append
      if (Object.keys(prepend).length > 0) patchOp.prepend = prepend
      if (opts?.ifMatch !== undefined) patchOp.ifMatch = opts.ifMatch
      mutations.push({ patch: patchOp })
      return tx
    },
    publish(id, type) {
      if (!id || !type) {
        throw new BarkparkValidationError('publish requires id and type', {
          field: !id ? 'id' : 'type',
        })
      }
      mutations.push({ publish: { id, type } })
      return tx
    },
    unpublish(id, type) {
      if (!id || !type) {
        throw new BarkparkValidationError('unpublish requires id and type', {
          field: !id ? 'id' : 'type',
        })
      }
      mutations.push({ unpublish: { id, type } })
      return tx
    },
    discardDraft(id, type) {
      if (!id || !type) {
        throw new BarkparkValidationError('discardDraft requires id and type', {
          field: !id ? 'id' : 'type',
        })
      }
      mutations.push({ discardDraft: { id, type } })
      return tx
    },
    delete(id, type, opts) {
      if (!id || !type) {
        throw new BarkparkValidationError('delete requires id and type', {
          field: !id ? 'id' : 'type',
        })
      }
      const op: { id: string; type: string; ifMatch?: string } = { id, type }
      if (opts?.ifMatch !== undefined) op.ifMatch = opts.ifMatch
      mutations.push({ delete: op })
      return tx
    },
    async commit(opts?: CommitOptions): Promise<MutateEnvelope> {
      if (mutations.length === 0) {
        throw new BarkparkValidationError('transaction.commit called with no mutations', {
          field: 'mutations',
        })
      }
      const headers: Record<string, string> = {}
      if (opts?.idempotencyKey !== undefined && opts.idempotencyKey.length > 0) {
        headers['Idempotency-Key'] = opts.idempotencyKey
      }
      const { data } = await request<MutateEnvelope>(
        config,
        `${scopePrefix(config)}/v1/data/mutate/${encodeURIComponent(config.dataset)}`,
        {
          method: 'POST',
          body: { mutations },
          headers,
          kind: 'write',
          retryPolicy: opts?.retry === true ? 'on-idempotency-key' : 'none',
          // Forward the documented per-call timeout override (CommitOptions.timeoutMs).
          ...(opts?.timeoutMs !== undefined ? { timeoutMs: opts.timeoutMs } : {}),
        },
      )
      return data
    },
  }

  return tx
}
