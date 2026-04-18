// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Root export — intentionally minimal. Most API lives on ./server, ./client, ./actions, ./webhook, ./draft-mode
export type { BarkparkClientConfig, BarkparkDocument, Perspective } from '@barkpark/core'

export function revalidateBarkpark(_tag: string): void {
  throw new Error('revalidateBarkpark not implemented in scaffold (Phase 3)')
}
