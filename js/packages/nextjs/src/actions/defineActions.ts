// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { BarkparkClient, MutateResult } from '@barkpark/core'
import { revalidateTag } from 'next/cache'

/**
 * Structural schema — any object with `.parse(input)` that throws on invalid
 * input. Zod schemas satisfy this shape, so codegen-emitted `z.object(...)`
 * definitions drop in without adapter code. Per ADR-008, zod is an *optional*
 * peer dep, so we avoid a hard type import from 'zod' here.
 */
export interface ActionSchema {
  parse(input: unknown): unknown
}

/** Configuration for {@link defineActions}. */
export interface DefineActionsConfig {
  /** The authoring client used to execute mutations. */
  client: BarkparkClient
  /** Per-`_type` input schemas (e.g. codegen-emitted Zod schemas). */
  schemas?: Record<string, ActionSchema>
  /** Dataset used when formatting revalidate tags. Defaults to the client's dataset. */
  dataset?: string
}

/** Payload for {@link BarkparkActions.patchDoc}. */
export interface PatchInput {
  /** Fields to set on the target document. */
  set?: Record<string, unknown>
  /** Optional ETag precondition — throws {@link BarkparkConflictError} on mismatch. */
  ifMatch?: string
}

/** Payload for {@link BarkparkActions.createDoc}. `_type` is required; any other fields are document data. */
export interface CreateDocInput {
  _type: string
  [field: string]: unknown
}

/** Server Actions bundle returned by {@link defineActions}. */
export interface BarkparkActions {
  /** Validates via schema (if registered), creates the document, and fans out revalidate tags. */
  createDoc(input: CreateDocInput): Promise<MutateResult>
  /** Patches (set-only) a document and fans out revalidate tags. Honors `ifMatch`. */
  patchDoc(id: string, patch: PatchInput): Promise<MutateResult>
  /** Publishes the draft for `id` and fans out tags. */
  publish(id: string, type: string): Promise<MutateResult>
  /** Unpublishes `id` back to draft and fans out tags. */
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

/**
 * Builds a {@link BarkparkActions} bundle suitable for use as Server Actions.
 *
 * Each mutation:
 *  1. Validates input against a registered schema (if any) via `.parse()`.
 *  2. Executes the mutation through the authoring client.
 *  3. Fans out canonical revalidate tags (`bp:ds:<dataset>:doc:<id>` and `:type:<type>`).
 *
 * @param config — {@link DefineActionsConfig}; at minimum `client`.
 * @returns A {@link BarkparkActions} bundle of server-executable mutations.
 *
 * @example
 * // app/actions.ts
 * 'use server'
 * import { defineActions } from '@barkpark/nextjs/actions'
 * import { client } from '@/lib/barkpark'
 * import { schemas } from '@/lib/generated'
 *
 * export const actions = defineActions({ client, schemas })
 *
 * // app/posts/new/page.tsx
 * import { actions } from '@/app/actions'
 *
 * <form action={async (fd) => {
 *   'use server'
 *   await actions.createDoc({ _type: 'post', title: String(fd.get('title')) })
 * }}>…</form>
 */
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
