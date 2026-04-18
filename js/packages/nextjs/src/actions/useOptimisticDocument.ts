'use client'
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { useOptimistic, useState, useTransition } from 'react'
import { BarkparkConflictError } from '@barkpark/core'

/** Server-side state surfaced to the caller when a mutation raises {@link BarkparkConflictError}. */
export interface OptimisticDocumentConflict {
  /** Current ETag returned by the server — pass into your next retry's `ifMatch`. */
  serverEtag?: string
  /** Current server-side document, when the server returned one alongside the conflict. */
  serverDoc?: unknown
}

/** Return shape for {@link useOptimisticDocument}. */
export interface UseOptimisticDocumentResult<T> {
  /** The optimistic document — reflects unacknowledged patches. */
  data: T
  /** True while a transition is in flight. */
  pending: boolean
  /** Present when the last mutation raised a conflict; call `clearConflict` to dismiss. */
  conflict?: OptimisticDocumentConflict
  /** Optimistically apply a partial patch and commit it via the server action. */
  mutate: (patch: Partial<T>) => void
  /** Clear the `conflict` field. Does not undo the optimistic state. */
  clearConflict: () => void
}

/**
 * Client hook that combines `useOptimistic`, `useTransition`, and
 * {@link BarkparkConflictError} handling into a single document editor.
 *
 * `mutate(patch)` merges `patch` into the optimistic view immediately, then
 * invokes `mutationAction(optimisticDoc)` inside a transition. On a conflict
 * error, the thrown error's `serverEtag` / `serverDoc` are surfaced on the
 * returned `conflict` field; any other error propagates.
 *
 * @typeParam T - Document shape with at least `_id` and `_type`.
 * @param initialDoc      - Initial committed document.
 * @param mutationAction  - Server action that persists the new optimistic doc and returns the committed result.
 * @returns {@link UseOptimisticDocumentResult}
 *
 * @example
 * 'use client'
 * import { useOptimisticDocument } from '@barkpark/nextjs/actions'
 * import { patchPost } from '@/app/actions'
 *
 * export function PostEditor({ post }: { post: Post }) {
 *   const { data, pending, conflict, mutate, clearConflict } =
 *     useOptimisticDocument(post, patchPost)
 *
 *   return (
 *     <form onSubmit={(e) => { e.preventDefault(); mutate({ title: newTitle }) }}>
 *       <input defaultValue={data.title} />
 *       {pending && <span>Saving…</span>}
 *       {conflict && <button onClick={clearConflict}>Dismiss conflict</button>}
 *     </form>
 *   )
 * }
 */
export function useOptimisticDocument<T extends { _id: string; _type: string }>(
  initialDoc: T,
  mutationAction: (optimisticDoc: T) => Promise<T>,
): UseOptimisticDocumentResult<T> {
  const [committed, setCommitted] = useState<T>(initialDoc)
  const [optimistic, addOptimistic] = useOptimistic<T, Partial<T>>(
    committed,
    (state, patch) => ({ ...state, ...patch }),
  )
  const [isPending, startTransition] = useTransition()
  const [conflict, setConflict] = useState<OptimisticDocumentConflict | undefined>(undefined)

  const mutate = (patch: Partial<T>): void => {
    startTransition(async () => {
      addOptimistic(patch)
      try {
        const next = await mutationAction({ ...committed, ...patch } as T)
        setCommitted(next)
      } catch (e: unknown) {
        // Match on instanceof AND `code` literal — pnpm hoist can produce
        // duplicate class copies across bundles, making instanceof unreliable
        // (ADR-009 §code taxonomy).
        const isConflict =
          e instanceof BarkparkConflictError ||
          (typeof e === 'object' &&
            e !== null &&
            'code' in e &&
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            (e as any).code === 'BarkparkConflictError')
        if (isConflict) {
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          const c = e as any
          const next: OptimisticDocumentConflict = {}
          if (c.serverEtag !== undefined) next.serverEtag = c.serverEtag
          if (c.serverDoc !== undefined) next.serverDoc = c.serverDoc
          setConflict(next)
          return
        }
        throw e
      }
    })
  }

  const clearConflict = (): void => setConflict(undefined)

  const result: UseOptimisticDocumentResult<T> = {
    data: optimistic,
    pending: isPending,
    mutate,
    clearConflict,
  }
  if (conflict !== undefined) result.conflict = conflict
  return result
}
