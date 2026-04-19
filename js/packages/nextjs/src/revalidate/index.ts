// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { revalidateTag, revalidatePath } from 'next/cache'

/**
 * Payload accepted by {@link revalidateBarkpark}.
 *
 * Canonical shape (emitted by the Phoenix webhook dispatcher):
 *   `{ event, type, doc_id, document, dataset, sync_tags }`
 *
 * `sync_tags` — already canonical `bp:ds:<dataset>:doc:<id>` /
 * `bp:ds:<dataset>:type:<type>` entries — is preferred when present.
 * Falls back to constructing canonical tags from `dataset` + `doc_id` + `type`.
 *
 * Legacy shape fields (`_id`, `_type`, `ids`, `types`) are still accepted for
 * back-compat; they only produce canonical tags when `dataset` is also set.
 *
 * Path-based revalidation (`path`, `paths`) remains gated behind
 * `BARKPARK_ALLOW_ALL_REVALIDATE=1`.
 */
export interface RevalidatePayload {
  /** Phoenix canonical fields */
  event?: string
  type?: string
  doc_id?: string
  document?: { _id?: string; _type?: string }
  dataset?: string
  sync_tags?: readonly string[]

  /** Path-based revalidation (opt-in via env). */
  path?: string
  paths?: readonly string[]

  /** Legacy shape (pre-canonical). Produces canonical tags only when `dataset` is also set. */
  _id?: string
  _type?: string
  ids?: readonly string[]
  types?: readonly string[]
}

/** Back-compat alias. */
export type WebhookPayload = RevalidatePayload

function allowAllRevalidate(): boolean {
  const v = process.env.BARKPARK_ALLOW_ALL_REVALIDATE
  return v === '1' || v === 'true'
}

/**
 * Fan out cache invalidations for one or more Barkpark documents.
 *
 * Preferred input is the Phoenix webhook payload
 * `{ event, type, doc_id, document, dataset, sync_tags }`. When `sync_tags`
 * is present, each entry is passed verbatim to `revalidateTag`. Otherwise
 * canonical `bp:ds:<dataset>:doc:<id>` / `:type:<type>` / `:_all` tags are
 * constructed from `dataset`, `doc_id`, and `type` (or their legacy
 * `_id`/`_type`/`ids`/`types` equivalents).
 *
 * Tags are deduped before `revalidateTag` fires so double-invalidation is
 * avoided when both `sync_tags` and derived tags overlap.
 *
 * Path-based revalidation (`path`, `paths`) is opt-in via the environment
 * variable `BARKPARK_ALLOW_ALL_REVALIDATE=1` and throws otherwise.
 *
 * @param payload — A {@link RevalidatePayload}, a document-id string, or undefined (no-op).
 * @throws When `path`/`paths` is set but `BARKPARK_ALLOW_ALL_REVALIDATE` is not `1`/`true`.
 *
 * @example
 * import { revalidateBarkpark } from '@barkpark/nextjs/revalidate'
 *
 * // Directly forward a Phoenix webhook body:
 * revalidateBarkpark(await req.json())
 *
 * // Construct from fields:
 * revalidateBarkpark({ dataset: 'production', type: 'post', doc_id: 'p1' })
 */
export function revalidateBarkpark(payload?: RevalidatePayload | string): void {
  if (payload === undefined || payload === null) return

  const tags = new Set<string>()

  if (typeof payload === 'string') {
    // Back-compat: a bare string has no dataset context, so no canonical tag
    // can be constructed. Silently no-op.
    return
  }

  // Preferred: sync_tags from the Phoenix dispatcher (already canonical).
  if (payload.sync_tags) {
    for (const t of payload.sync_tags) {
      if (typeof t === 'string' && t.length > 0) tags.add(t)
    }
  }

  // Fall back to / augment with tags constructed from Phoenix or legacy fields.
  const ds = payload.dataset
  if (typeof ds === 'string' && ds.length > 0) {
    tags.add(`bp:ds:${ds}:_all`)

    const docId = payload.doc_id ?? payload._id ?? payload.document?._id
    const type = payload.type ?? payload._type ?? payload.document?._type
    if (typeof docId === 'string' && docId.length > 0) {
      tags.add(`bp:ds:${ds}:doc:${docId}`)
    }
    if (typeof type === 'string' && type.length > 0) {
      tags.add(`bp:ds:${ds}:type:${type}`)
    }

    if (payload.ids) {
      for (const id of payload.ids) {
        if (typeof id === 'string' && id.length > 0) tags.add(`bp:ds:${ds}:doc:${id}`)
      }
    }
    if (payload.types) {
      for (const t of payload.types) {
        if (typeof t === 'string' && t.length > 0) tags.add(`bp:ds:${ds}:type:${t}`)
      }
    }
  }

  for (const tag of tags) revalidateTag(tag)

  if (payload.path !== undefined || payload.paths !== undefined) {
    if (!allowAllRevalidate()) {
      throw new Error('Path-based revalidation requires BARKPARK_ALLOW_ALL_REVALIDATE=1')
    }
    if (payload.path !== undefined) revalidatePath(payload.path)
    if (payload.paths) {
      for (const p of payload.paths) revalidatePath(p)
    }
  }
}
