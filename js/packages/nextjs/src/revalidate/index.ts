// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { revalidateTag, revalidatePath } from 'next/cache'
import { formatTagPrefix } from '../tag-prefix'

/**
 * Payload accepted by {@link revalidateBarkpark}.
 *
 * Canonical shape (emitted by the Phoenix webhook dispatcher):
 *   `{ event, type, doc_id, document, dataset, workspace, project, sync_tags }`
 *
 * `sync_tags` — emitted by the dispatcher in either the NEW workspace/project
 * scoped shape `bp:ws:<ws>:p:<project>:ds:<dataset>:doc:<id>` /
 * `:type:<type>` or the LEGACY flat shape `bp:ds:<dataset>:doc:<id>` /
 * `:type:<type>` — is preferred when present. Each entry is forwarded verbatim
 * to `revalidateTag`, so both shapes pass through unchanged.
 *
 * When `sync_tags` is absent, tags are constructed from the payload fields.
 * If `workspace` + `project` resolve (s7 scoped payloads), SCOPED `bp:ws:*`
 * tags are constructed; otherwise the LEGACY flat `bp:ds:*` tags are
 * constructed (back-compat).
 *
 * Legacy shape fields (`_id`, `_type`, `ids`, `types`) are still accepted for
 * back-compat; they only produce tags when `dataset` is also set.
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

  /**
   * Workspace/project scope (s7 scoped payloads). When BOTH resolve, constructed
   * fallback tags use the scoped `bp:ws:<ws>:p:<project>:ds:<dataset>:…` shape.
   * Both the canonical (`workspace`/`project`) and the dispatcher `_slug`
   * spellings (`workspace_slug`/`project_slug`) are accepted.
   */
  workspace?: string
  project?: string
  workspace_slug?: string
  project_slug?: string

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

function nonEmpty(v: unknown): v is string {
  return typeof v === 'string' && v.length > 0
}

/**
 * Build the tag namespace prefix for field-derived tags.
 *
 * Returns the SCOPED `bp:ws:<ws>:p:<project>:ds:<dataset>` prefix when both a
 * workspace and a project slug resolve (s7 scoped payloads); otherwise the
 * LEGACY flat `bp:ds:<dataset>` prefix (back-compat). Returns `null` when no
 * dataset is present — no tag can be constructed.
 */
function tagPrefix(payload: RevalidatePayload): string | null {
  const ds = payload.dataset
  if (!nonEmpty(ds)) return null

  // Format via the shared source of truth — keeps webhook-derived tags identical
  // to the write (defineActions) and read (server) sides.
  const ws = payload.workspace ?? payload.workspace_slug
  const project = payload.project ?? payload.project_slug
  return formatTagPrefix(ds, ws, project)
}

/**
 * Fan out cache invalidations for one or more Barkpark documents.
 *
 * Preferred input is the Phoenix webhook payload
 * `{ event, type, doc_id, document, dataset, workspace, project, sync_tags }`.
 * When `sync_tags` is present, each entry is passed verbatim to `revalidateTag`
 * — so both the NEW scoped `bp:ws:<ws>:p:<project>:ds:<dataset>:…` shape and
 * the LEGACY flat `bp:ds:<dataset>:…` shape flow through unchanged. Otherwise
 * tags are constructed from fields: SCOPED `bp:ws:<ws>:p:<project>:ds:<dataset>`
 * when `workspace` + `project` resolve (s7), else LEGACY flat `bp:ds:<dataset>`
 * (back-compat), each with `:doc:<id>` / `:type:<type>` / `:_all` suffixes from
 * `doc_id`/`type` (or their legacy `_id`/`_type`/`ids`/`types` equivalents).
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

  // Fail fast on the path-gate BEFORE any side effects. This is a static
  // precondition independent of tag work, so throwing here keeps the error
  // path atomic — no partial tag invalidation happens before the throw.
  if ((payload.path !== undefined || payload.paths !== undefined) && !allowAllRevalidate()) {
    throw new Error('Path-based revalidation requires BARKPARK_ALLOW_ALL_REVALIDATE=1')
  }

  // Preferred: sync_tags from the Phoenix dispatcher (already canonical).
  // Array.isArray, not a truthy check: revalidateBarkpark is a public export
  // documented to take a raw `await req.json()` body, so a hand-built/legacy
  // payload may carry a non-array sync_tags. A number/object would throw
  // `TypeError: not iterable`; a bare STRING is truthy and iterable, so a
  // truthy-guarded for...of would walk it CHARACTER by character — adding
  // single-char garbage tags and never invalidating the intended one (silent
  // stale content). A non-array is simply ignored.
  if (Array.isArray(payload.sync_tags)) {
    for (const t of payload.sync_tags) {
      if (typeof t === 'string' && t.length > 0) tags.add(t)
    }
  }

  // Fall back to / augment with tags constructed from Phoenix or legacy fields.
  // The prefix is SCOPED (bp:ws:<ws>:p:<project>:ds:<dataset>) when the payload
  // carries workspace+project (s7), else the LEGACY flat bp:ds:<dataset>.
  const prefix = tagPrefix(payload)
  if (prefix !== null) {
    tags.add(`${prefix}:_all`)

    const docId = payload.doc_id ?? payload._id ?? payload.document?._id
    const type = payload.type ?? payload._type ?? payload.document?._type
    if (nonEmpty(docId)) {
      tags.add(`${prefix}:doc:${docId}`)
    }
    if (nonEmpty(type)) {
      tags.add(`${prefix}:type:${type}`)
    }

    if (Array.isArray(payload.ids)) {
      for (const id of payload.ids) {
        if (nonEmpty(id)) tags.add(`${prefix}:doc:${id}`)
      }
    }
    if (Array.isArray(payload.types)) {
      for (const t of payload.types) {
        if (nonEmpty(t)) tags.add(`${prefix}:type:${t}`)
      }
    }
  }

  for (const tag of tags) revalidateTag(tag)

  // Path-based revalidation. The env-gate was already enforced at the top of
  // the function, so these calls can fire unconditionally here.
  //
  // Both arms are TYPE-guarded for the same reason the sync_tags comment above
  // gives, and this is where that hazard bites hardest. `paths` used to be a
  // bare truthy check, and a bare STRING is truthy AND iterable: a webhook body
  // carrying `paths: '/blog'` made this for...of walk it CHARACTER by character
  // — revalidatePath('/'), ('b'), ('l'), ('o'), ('g') — five garbage
  // invalidations, and the intended path never revalidated. Worse than the
  // sync_tags case it was derived from: these are revalidatePath calls, not tag
  // adds, and a single character is not a valid Next route path, so depending
  // on the Next version this either mis-invalidates silently or THROWS out of
  // the consumer's webhook handler — after the tag fan-out above already fired,
  // which is exactly the partial, non-atomic invalidation the path-gate at the
  // top of this function is placed early to prevent.
  //
  // `path` gets the same treatment: a number or object from a raw `req.json()`
  // body reached revalidatePath untouched.
  if (nonEmpty(payload.path)) revalidatePath(payload.path)
  if (Array.isArray(payload.paths)) {
    for (const p of payload.paths) {
      if (nonEmpty(p)) revalidatePath(p)
    }
  }
}
