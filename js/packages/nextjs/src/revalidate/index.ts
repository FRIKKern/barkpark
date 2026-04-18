// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { revalidateTag, revalidatePath } from 'next/cache'

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
