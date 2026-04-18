'use client'
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { useOptimistic, useState, useTransition } from 'react'
import { BarkparkConflictError } from '@barkpark/core'

export interface OptimisticDocumentConflict {
  serverEtag?: string
  serverDoc?: unknown
}

export interface UseOptimisticDocumentResult<T> {
  data: T
  pending: boolean
  conflict?: OptimisticDocumentConflict
  mutate: (patch: Partial<T>) => void
  clearConflict: () => void
}

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
