// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { BarkparkClient, Perspective } from '@barkpark/core'
import type { BuilderState } from '@barkpark/core'

/** Config passed to createBarkparkServer / defineLive. */
export interface BarkparkServerConfig<C extends BarkparkClient = BarkparkClient> {
  /** Configured @barkpark/core client. The server reads `client.config` for projectUrl/dataset/apiVersion. */
  client: C
  /** Server-only Bearer token used on the draft branch. MUST never reach the browser bundle. */
  serverToken: string
  /** Browser-exposed preview token (used by createDraftModeRoutes / SSE). Optional in v0.1. */
  browserToken?: string
  /** Per-call defaults applied by barkparkFetch. */
  fetchOptions?: {
    timeout?: number
    headers?: Record<string, string>
    signal?: AbortSignal
  }
  /**
   * Optional hook used by the 401-auto-reissue path on the draft branch. If provided,
   * called after a 401 to obtain a fresh preview token; the retry uses the returned value.
   * If absent, the retry re-uses `serverToken` (sufficient for rotation-window 401s).
   */
  reissuePreviewToken?: () => Promise<string>
}

/** Per-call options for barkparkFetch. */
export interface BarkparkFetchOptions {
  /** Document type to query (Phoenix endpoint is type-keyed). Required unless `path` is provided. */
  type?: string
  /** Single-document fetch shortcut. When set, uses /v1/data/doc/{ds}/{type}/{id}. */
  id?: string
  // TODO(Wave 3): replace BuilderState with the unified BarkparkFilterBuilder type once core exposes it.
  /** Optional filter / order / limit / offset state. */
  query?: BuilderState
  /** Override the resolved perspective. Draft branch always wins this with 'drafts'. */
  perspective?: Perspective
  /** Additional Next.js cache tags merged with the dataset-wide tag. */
  tags?: readonly string[]
  /** Forwarded to Next's fetch `next.revalidate`. Ignored on the draft branch. */
  revalidate?: number | false
  /** AbortSignal forwarded to fetch. */
  signal?: AbortSignal
  /**
   * Pre-known syncTags from a prior cache()-memoized fetch (e.g. preloadDocument).
   * Wave 4 I3 wires this. v0.1: accepted but optional. See barkparkFetch JSDoc.
   */
  syncTags?: readonly string[]
}
