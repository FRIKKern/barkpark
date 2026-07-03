// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Root export — intentionally minimal. Most API lives on ./server, ./client, ./actions, ./webhook, ./draft-mode
export type {
  BarkparkClientConfig,
  BarkparkDocument,
  Perspective,
  BarkparkClient,
} from '@barkpark/core'

export { barkparkMetadata } from './metadata'
export type { BarkparkMetadataDoc, BarkparkMetadataOverrides } from './metadata'

/**
 * Guard stub. The real implementation lives at `@barkpark/nextjs/revalidate` —
 * it calls Next.js's server-only `revalidateTag`, so re-exporting it from the
 * package root would pull server cache APIs into client bundles. This stub fails
 * loudly with the fix rather than silently mis-bundling.
 *
 * @throws always — import from `@barkpark/nextjs/revalidate` instead.
 */
export function revalidateBarkpark(_payload?: unknown): never {
  throw new Error(
    "revalidateBarkpark is server-only — import it from '@barkpark/nextjs/revalidate', " +
      "not '@barkpark/nextjs'. The package root is a guard so Next.js server cache APIs " +
      'never land in a client bundle.',
  )
}
