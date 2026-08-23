// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { BarkparkClient, Perspective } from '@barkpark/core'
import type { BuilderState } from '@barkpark/core'

/** Config passed to createBarkparkServer / defineLive. */
export interface BarkparkServerConfig<C extends BarkparkClient = BarkparkClient> {
  /** Configured @barkpark/core client. The server reads `client.config` for projectUrl/dataset/apiVersion (and workspace/project, unless overridden below). */
  client: C
  /** Server-only Bearer token used on the draft branch. MUST never reach the browser bundle. */
  serverToken: string
  /**
   * Optional workspace slug. Mirrors / overrides `client.config.workspace`. When BOTH `workspace`
   * and `project` resolve (server-config value taking precedence over the client's), the server
   * prepends the `/w/<ws>/p/<project>` scope to every `/v1/...` URL it builds; otherwise the flat
   * `/v1/...` routes are used (back-compat).
   */
  workspace?: string
  /** Optional project slug. Mirrors / overrides `client.config.project`. See {@link workspace}. */
  project?: string
  /**
   * Browser-exposed preview token (used by createDraftModeRoutes / SSE).
   * Optional in v0.1 — and today a DECLARED-ONLY field: nothing in
   * js/packages/nextjs reads, attaches, or forwards it, so it has NO leak
   * surface (ruled SAFE, arpss-js-browsertoken-dead-field). WIRING-UP
   * OBLIGATION: the change that first READS this field must pass the
   * four-vector token review — attached as a header, never in a URL;
   * redacted in JSON.stringify / util.inspect / error serializations; and a
   * deliberate ruling on whether a browser-exposed-by-design token still
   * needs sink redaction (see the V3 doctrine in core's client.ts).
   */
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
  /**
   * Inline reference fields on the single-document fetch — a field name or list,
   * e.g. `'author'` or `['author', 'tags']`. Applies to the `id` fetch (mirrors
   * `bp.doc(id, { expand })`); for list queries use `query.expand`.
   */
  expand?: string | string[]
  /**
   * Project the single-document fetch to only these content fields (system fields
   * always included) — a field name or list. Applies to the `id` fetch (mirrors
   * `bp.doc(id, { fields })`); for list queries use `query.select`.
   */
  fields?: string | string[]
  /**
   * Optional filter / order / limit / offset / expand state. Build the `filters`
   * with `@barkpark/core`'s `makeFilterExpression`, e.g.
   * `{ filters: [makeFilterExpression('status', 'eq', 'published')], order: '_createdAt:desc', limit: 10 }`.
   */
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
