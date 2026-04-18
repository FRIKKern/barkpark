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
import { BarkparkValidationError } from './errors'

type Mutation =
  | { create: Partial<BarkparkDocument> & { _type: string } }
  | { createOrReplace: BarkparkDocument }
  | { patch: { id: string; set: Record<string, unknown>; ifMatch?: string } }
  | { publish: { id: string; type: string } }
  | { unpublish: { id: string; type: string } }
  | { delete: { id: string; type: string; ifMatch?: string } }

const FORBIDDEN_PATCH_FIELDS: ReadonlySet<string> = new Set([
  '_id',
  '_type',
  '_rev',
  '_createdAt',
  '_updatedAt',
  '_draft',
  '_publishedId',
])

/**
 * @deprecated Alias preserved for the `index.ts` barrel during Phase 1A;
 * prefer `createTransaction(config)`. Callers who only have a config
 * (e.g. `client.ts`) should use the explicit name.
 */
export const transaction = (config: BarkparkClientConfig): TransactionBuilder =>
  createTransaction(config)

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
 *     .patch('p1', (p) => p.set({ title: 'Hi' }), { ifMatch: rev })
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
        throw new BarkparkValidationError(
          'transaction.createOrReplace requires _id and _type',
          { field: '_id' },
        )
      }
      mutations.push({ createOrReplace: doc })
      return tx
    },
    patch(id, build, opts) {
      const set: Record<string, unknown> = {}
      const miniBuilder: PatchBuilder = {
        set(fields) {
          if (fields == null || typeof fields !== 'object' || Array.isArray(fields)) {
            throw new BarkparkValidationError('patch.set requires an object', { field: 'set' })
          }
          for (const k of Object.keys(fields)) {
            if (FORBIDDEN_PATCH_FIELDS.has(k)) {
              throw new BarkparkValidationError(`patch.set cannot modify ${k}`, { field: k })
            }
          }
          Object.assign(set, fields)
          return miniBuilder
        },
        inc(_fields) {
          throw new BarkparkValidationError('patch.inc not implemented in Phase 1A', {
            field: 'inc',
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
      if (Object.keys(set).length === 0) {
        throw new BarkparkValidationError(
          `patch on ${id} inside transaction had no set()`,
          { field: 'set' },
        )
      }
      const patchOp: { id: string; set: Record<string, unknown>; ifMatch?: string } = { id, set }
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
        `/v1/data/mutate/${config.dataset}`,
        {
          method: 'POST',
          body: { mutations },
          headers,
          kind: 'write',
          retryPolicy: opts?.retry === true ? 'on-idempotency-key' : 'none',
        },
      )
      return data
    },
  }

  return tx
}
