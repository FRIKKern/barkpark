// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

export function defineActions<C>(client: C): C {
  return client
}

export function useOptimisticDocument<T>(_initial: T): [T, (patch: Partial<T>) => void] {
  throw new Error('useOptimisticDocument not implemented in scaffold (Phase 3)')
}
