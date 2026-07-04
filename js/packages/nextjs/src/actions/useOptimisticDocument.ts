'use client'
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { useOptimistic, useRef, useState, useTransition } from 'react'
import { isBarkparkError, type BarkparkConflictError } from '@barkpark/core'

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
  const [optimistic, addOptimistic] = useOptimistic<T, Partial<T>>(committed, (state, patch) => ({
    ...state,
    ...patch,
  }))
  const [isPending, startTransition] = useTransition()
  const [conflict, setConflict] = useState<OptimisticDocumentConflict | undefined>(undefined)

  // `committed` only advances after a round-trip resolves, so the render-closure
  // copy is stale for back-to-back mutations. These refs carry the true payload
  // chain across renders: `latestRef` is the newest state we've asked the server
  // to hold (so successive patches accumulate instead of clobbering each other),
  // `committedRef` mirrors the last server-confirmed doc, and `inflightRef`
  // counts pending round-trips so we only re-sync/roll-back when we're the sole
  // in-flight call.
  const committedRef = useRef<T>(initialDoc)
  const latestRef = useRef<T>(initialDoc)
  const inflightRef = useRef(0)

  const mutate = (patch: Partial<T>): void => {
    startTransition(async () => {
      const payload = { ...latestRef.current, ...patch } as T
      latestRef.current = payload
      inflightRef.current += 1
      addOptimistic(patch)
      try {
        const next = await mutationAction(payload)
        setCommitted(next)
        committedRef.current = next
        // Only re-sync server-derived fields (_rev/_updatedAt/…) when this was
        // the sole in-flight call — a newer pending payload must not be clobbered.
        if (inflightRef.current === 1) latestRef.current = next
      } catch (e: unknown) {
        // A failed patch must not linger in the payload chain, but only roll back
        // when we're the sole in-flight call (mirrors useOptimistic reverting to
        // committed once the transition ends without a commit).
        if (inflightRef.current === 1) latestRef.current = committedRef.current
        // Match on the `code` literal so this holds even when pnpm hoist yields
        // duplicate class copies across bundles (the code-literal taxonomy).
        const isConflict = isBarkparkError(e, 'BarkparkConflictError')
        if (isConflict) {
          const c = e as BarkparkConflictError
          const next: OptimisticDocumentConflict = {}
          if (c.serverEtag !== undefined) next.serverEtag = c.serverEtag
          if (c.serverDoc !== undefined) next.serverDoc = c.serverDoc
          setConflict(next)
          return
        }
        throw e
      } finally {
        inflightRef.current -= 1
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
