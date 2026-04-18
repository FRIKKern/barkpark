// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { revalidateTag, revalidatePath } from 'next/cache'

/**
 * Payload accepted by {@link revalidateBarkpark}. All fields are optional —
 * unknown/omitted fields are ignored. Document-id and type fanout map to
 * `barkpark:doc:<id>` / `barkpark:type:<type>` tags; path-based revalidation
 * is gated behind `BARKPARK_ALLOW_ALL_REVALIDATE=1`.
 */
export interface RevalidatePayload {
  _id?: string
  _type?: string
  ids?: string[]
  types?: string[]
  path?: string
  paths?: string[]
}

function allowAllRevalidate(): boolean {
  const v = process.env.BARKPARK_ALLOW_ALL_REVALIDATE
  return v === '1' || v === 'true'
}

/**
 * Fan out cache invalidations for one or more Barkpark documents.
 *
 * A plain string is treated as a document id. A {@link RevalidatePayload}
 * fans out every provided field: `_id`, `_type`, `ids[]`, `types[]`.
 * Path-based revalidation (`path`, `paths`) is opt-in via the environment
 * variable `BARKPARK_ALLOW_ALL_REVALIDATE=1` and throws otherwise.
 *
 * Safe to call from webhook handlers and Server Actions.
 *
 * @param payload — A document id, a {@link RevalidatePayload}, or undefined (no-op).
 * @throws When `path`/`paths` is set but `BARKPARK_ALLOW_ALL_REVALIDATE` is not `1`/`true`.
 *
 * @example
 * import { revalidateBarkpark } from '@barkpark/nextjs/revalidate'
 *
 * revalidateBarkpark('p1')
 * revalidateBarkpark({ _id: 'p1', _type: 'post' })
 * revalidateBarkpark({ ids: ['p1', 'p2'], types: ['post'] })
 */
export function revalidateBarkpark(payload?: RevalidatePayload | string): void {
  if (payload === undefined || payload === null) return

  if (typeof payload === 'string') {
    revalidateTag(`barkpark:doc:${payload}`)
    return
  }

  if (payload._id) revalidateTag(`barkpark:doc:${payload._id}`)
  if (payload._type) revalidateTag(`barkpark:type:${payload._type}`)

  if (payload.ids) {
    for (const id of payload.ids) revalidateTag(`barkpark:doc:${id}`)
  }

  if (payload.types) {
    for (const type of payload.types) revalidateTag(`barkpark:type:${type}`)
  }

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
