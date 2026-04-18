// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { BarkparkClient, MutateResult } from '@barkpark/core'
import { revalidateTag } from 'next/cache'

// Structural schema type — any object exposing `.parse(input)` that throws on
// invalid input. Zod schemas satisfy this shape, so codegen-emitted `z.object(...)`
// definitions drop in without adapter code. Per ADR-008 zod is an *optional*
// peer dep, so we avoid a hard type import from 'zod' here.
export interface ActionSchema {
  parse(input: unknown): unknown
}

export interface DefineActionsConfig {
  client: BarkparkClient
  /** Per-`_type` input schemas (e.g. codegen-emitted Zod schemas). */
  schemas?: Record<string, ActionSchema>
  /** Dataset used when formatting revalidate tags. Defaults to the client's dataset. */
  dataset?: string
}

export interface PatchInput {
  set?: Record<string, unknown>
  ifMatch?: string
}

export interface CreateDocInput {
  _type: string
  [field: string]: unknown
}

export interface BarkparkActions {
  createDoc(input: CreateDocInput): Promise<MutateResult>
  patchDoc(id: string, patch: PatchInput): Promise<MutateResult>
  publish(id: string, type: string): Promise<MutateResult>
  unpublish(id: string, type: string): Promise<MutateResult>
}

// Phoenix does not (yet) surface syncTags in the mutate envelope (api/lib/barkpark_web/
// controllers/mutate_controller.ex returns only `{transactionId, results}`). We format
// the canonical `bp:ds:<dataset>:doc:<id>` / `:type:<type>` tags client-side — when the
// server starts emitting syncTags on the envelope, swap this to read them verbatim.
function fanOutTags(dataset: string, id: string, type: string): void {
  revalidateTag(`bp:ds:${dataset}:doc:${id}`)
  revalidateTag(`bp:ds:${dataset}:type:${type}`)
}

export function defineActions(config: DefineActionsConfig): BarkparkActions {
  const { client, schemas } = config
  const dataset = config.dataset ?? client.config.dataset

  return {
    async createDoc(input) {
      const schema = schemas?.[input._type]
      if (schema !== undefined) {
        schema.parse(input)
      }
      const envelope = await client.transaction().create(input).commit()
      const result = envelope.results[0]
      if (result === undefined) {
        throw new Error('createDoc: mutate envelope contained no results')
      }
      fanOutTags(dataset, result.id, input._type)
      return result
    },

    async patchDoc(id, patch) {
      let builder = client.patch(id)
      if (patch.set !== undefined && Object.keys(patch.set).length > 0) {
        builder = builder.set(patch.set)
      }
      const commitOpts = patch.ifMatch !== undefined ? { ifMatch: patch.ifMatch } : undefined
      const result = await builder.commit(commitOpts)
      fanOutTags(dataset, result.id, result.document._type)
      return result
    },

    async publish(id, type) {
      const result = await client.publish(id, type)
      fanOutTags(dataset, result.id, type)
      return result
    },

    async unpublish(id, type) {
      const result = await client.unpublish(id, type)
      fanOutTags(dataset, result.id, type)
      return result
    },
  }
}
