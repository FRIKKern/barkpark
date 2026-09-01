// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { BarkparkClient, MutateEnvelope, MutateResult } from '@barkpark/core'
import { BarkparkAPIError, BarkparkValidationError } from '@barkpark/core'
import { revalidateTag } from 'next/cache'
import { formatTagPrefix } from '../tag-prefix'

/**
 * Structural schema — any object with `.parse(input)` that throws on invalid
 * input. Zod schemas satisfy this shape, so codegen-emitted `z.object(...)`
 * definitions drop in without adapter code. zod is an *optional* peer dep, so we
 * avoid a hard type import from 'zod' here.
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
  /**
   * Workspace slug used when formatting SCOPED revalidate tags. Defaults to the
   * client's `config.workspace`. When BOTH workspace + project resolve, fanned-out
   * tags use the scoped `bp:ws:<ws>:p:<project>:ds:<dataset>:…` shape; otherwise
   * the legacy flat `bp:ds:<dataset>:…` shape (back-compat).
   */
  workspace?: string
  /** Project slug used when formatting SCOPED revalidate tags. Defaults to the client's `config.project`. See {@link workspace}. */
  project?: string
}

/**
 * Payload for {@link BarkparkActions.patchDoc} — the full Phase-1B patch surface,
 * mirroring the core `client.patch()` builder. Combine any of the ops in one call.
 */
export interface PatchInput {
  /** Fields to set on the target document. */
  set?: Record<string, unknown>
  /** Fields to set only if currently absent (no overwrite). */
  setIfMissing?: Record<string, unknown>
  /** Content keys to remove. */
  unset?: string[]
  /** Numeric fields to increment by the given amount. */
  inc?: Record<string, number>
  /** Numeric fields to decrement by the given amount. */
  dec?: Record<string, number>
  /** Items to append to array fields, keyed by field name (e.g. `{ tags: ['new'] }`). */
  append?: Record<string, unknown[]>
  /** Items to prepend to array fields, keyed by field name. */
  prepend?: Record<string, unknown[]>
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
  /** Patches a document (set/setIfMissing/unset/inc/dec/append/prepend) and fans out revalidate tags.
   *  `type` is the document's `_type`, required by the server on every patch op. Honors `ifMatch`. */
  patchDoc(id: string, type: string, patch: PatchInput): Promise<MutateResult>
  /** Publishes the draft for `id` and fans out tags. */
  publish(id: string, type: string): Promise<MutateResult>
  /** Unpublishes `id` back to draft and fans out tags. */
  unpublish(id: string, type: string): Promise<MutateResult>
  /** Discards `id`'s draft edits (keeps the published doc) and fans out tags. */
  discardDraft(id: string, type: string): Promise<MutateResult>
  /** Deletes the document `id` (of `type`) and fans out revalidate tags. */
  deleteDoc(id: string, type: string): Promise<MutateResult>
}

// Phoenix does not (yet) surface syncTags in the mutate envelope (api/lib/barkpark_web/
// controllers/mutate_controller.ex returns only `{transactionId, results}`). We format
// the canonical `<prefix>:doc:<id>` / `:type:<type>` tags client-side — when the
// server starts emitting syncTags on the envelope, swap this to read them verbatim.
//
// `prefix` is SCOPED `bp:ws:<ws>:p:<project>:ds:<dataset>` when workspace+project
// are configured (matches the s15 revalidate ingest grammar), else LEGACY flat
// `bp:ds:<dataset>` (back-compat).
function fanOutTags(prefix: string, id: string, type: string): void {
  revalidateTag(`${prefix}:doc:${id}`)
  revalidateTag(`${prefix}:type:${type}`)
}

/**
 * Build the cache-tag namespace prefix — delegates to the shared
 * {@link formatTagPrefix} (the single source of truth the read side and webhook
 * revalidate also use, so write/read/revalidate tags always agree).
 */
function buildTagPrefix(dataset: string, workspace?: string, project?: string): string {
  return formatTagPrefix(dataset, workspace, project)
}

/**
 * Look up the schema REGISTERED under `type` — own keys only.
 *
 * This was `schemas?.[type]`, a prototype-chain read on a plain codegen object
 * literal. `_type` is reachable from untyped form/JSON input (the comment at its
 * caller says so), and `'toString'` / `'constructor'` / `'valueOf'` /
 * `'__proto__'` all resolved to an INHERITED value whose `.parse` is not a
 * function, so `schema.parse(input)` threw a raw `TypeError` out of a Server
 * Action — escaping the Barkpark error taxonomy, the same defect class this
 * package names elsewhere in its own comments. It was a CRASH, not a validation
 * bypass: no inherited value carries a callable `.parse`, so nothing was ever
 * validated-then-waved-through.
 *
 * `Object.hasOwn` makes an inherited name behave exactly like any other
 * unregistered type — validation is skipped, as it already was for an unknown
 * `_type`. An own key whose value is not a usable schema is a different story
 * and REFUSED loudly: silently skipping validation there would turn a codegen or
 * hand-written-map bug into a real bypass. `Record<string, ActionSchema>` closes
 * neither case — this package ships CJS/ESM to plain JS consumers with no types.
 */
function lookupSchema(
  schemas: Record<string, ActionSchema> | undefined,
  type: string,
): ActionSchema | undefined {
  if (schemas === undefined || schemas === null || !Object.hasOwn(schemas, type)) return undefined
  const schema: unknown = schemas[type]
  if (schema === null || typeof schema !== 'object' || typeof (schema as ActionSchema).parse !== 'function') {
    throw new BarkparkValidationError(
      `createDoc: the schema registered for _type ${JSON.stringify(type)} has no callable .parse()`,
      { field: '_type' },
    )
  }
  return schema as ActionSchema
}

/**
 * [publish-warnings-dropped] `createDoc` / `deleteDoc` go through a transaction
 * and then narrow the envelope to `results[0]` — which silently discarded the
 * publish wall's non-blocking `warnings`. The four actions that call a core
 * single-mutation helper (`patchDoc` / `publish` / `unpublish` / `discardDraft`)
 * now get them carried for free by `onlyResult` in @barkpark/core; these two
 * narrow the envelope themselves, so they must carry them themselves. Same
 * omit-when-empty shape, so `'warnings' in result` stays a real test.
 */
function withWarnings(result: MutateResult, envelope: MutateEnvelope): MutateResult {
  return envelope.warnings?.length ? { ...result, warnings: envelope.warnings } : result
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
  const workspace = config.workspace ?? client.config.workspace
  const project = config.project ?? client.config.project
  const prefix = buildTagPrefix(dataset, workspace, project)

  return {
    async createDoc(input) {
      // Fail closed on a missing/empty `_type`: an empty string both skips schema
      // validation (`schemas['']` is undefined) AND fires a garbage `:type:` tag that
      // matches no read tag, silently losing the intended invalidation. Reachable from
      // untyped form/JSON input, so guard before the schema lookup or tag fan-out.
      if (typeof input._type !== 'string' || input._type.length === 0) {
        throw new BarkparkValidationError('createDoc requires a non-empty _type', { field: '_type' })
      }
      const schema = lookupSchema(schemas, input._type)
      let body = input
      if (schema !== undefined) {
        // Persist the PARSED value — Zod .parse() returns the validated+transformed
        // input (trims, .default() fills, .coerce/.transform conversions), so we use its
        // result, not the raw input. Re-pin `_type`: Zod strips unknown keys by default,
        // which would drop the discriminant and trip the create-time _type guard.
        const validated = schema.parse(input)
        // Guard the parse result: a schema whose top-level `.parse()` returns a
        // primitive/array (via `.transform()` / `z.string()`) would make the spread
        // corrupt the create body (spreading 'hi' yields `{0:'h',1:'i'}`).
        if (typeof validated !== 'object' || validated === null || Array.isArray(validated)) {
          throw new BarkparkValidationError('createDoc: schema.parse must return a plain object', {
            field: '_type',
          })
        }
        body = { ...(validated as Record<string, unknown>), _type: input._type } as typeof input
      }
      const envelope = await client.transaction().create(body).commit()
      const result = envelope.results[0]
      if (result === undefined) {
        throw new BarkparkAPIError('createDoc: mutate envelope contained no results', {
          status: 200,
        })
      }
      fanOutTags(prefix, result.id, input._type)
      return withWarnings(result, envelope)
    },

    async patchDoc(id, type, patch) {
      let builder = client.patch(id, type)
      if (patch.set !== undefined && Object.keys(patch.set).length > 0) {
        builder = builder.set(patch.set)
      }
      if (patch.setIfMissing !== undefined && Object.keys(patch.setIfMissing).length > 0) {
        builder = builder.setIfMissing(patch.setIfMissing)
      }
      if (patch.unset !== undefined && patch.unset.length > 0) {
        builder = builder.unset(patch.unset)
      }
      if (patch.inc !== undefined && Object.keys(patch.inc).length > 0) {
        builder = builder.inc(patch.inc)
      }
      if (patch.dec !== undefined && Object.keys(patch.dec).length > 0) {
        builder = builder.dec(patch.dec)
      }
      if (patch.append !== undefined) {
        for (const [field, items] of Object.entries(patch.append)) {
          builder = builder.append(field, items)
        }
      }
      if (patch.prepend !== undefined) {
        for (const [field, items] of Object.entries(patch.prepend)) {
          builder = builder.prepend(field, items)
        }
      }
      const commitOpts = patch.ifMatch !== undefined ? { ifMatch: patch.ifMatch } : undefined
      const result = await builder.commit(commitOpts)
      fanOutTags(prefix, result.id, result.document._type)
      return result
    },

    async publish(id, type) {
      const result = await client.publish(id, type)
      fanOutTags(prefix, result.id, type)
      return result
    },

    async unpublish(id, type) {
      const result = await client.unpublish(id, type)
      fanOutTags(prefix, result.id, type)
      return result
    },

    async discardDraft(id, type) {
      const result = await client.discardDraft(id, type)
      fanOutTags(prefix, result.id, type)
      return result
    },

    async deleteDoc(id, type) {
      // delete returns a mutate envelope (like create), so pull results[0].
      const envelope = await client.transaction().delete(id, type).commit()
      const result = envelope.results[0]
      if (result === undefined) {
        throw new BarkparkAPIError('deleteDoc: mutate envelope contained no results', {
          status: 200,
        })
      }
      fanOutTags(prefix, result.id, type)
      return withWarnings(result, envelope)
    },
  }
}
