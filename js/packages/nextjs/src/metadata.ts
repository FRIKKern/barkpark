// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { Metadata } from 'next'

/**
 * Minimal shape `barkparkMetadata` reads off a Barkpark document. Every field is
 * optional — a partial or `null` document degrades gracefully to an empty
 * `Metadata` object rather than throwing. Field names follow the conventions the
 * starter schemas use (`title`/`name` for the heading, `excerpt`/`description`
 * for the summary, `publishedAt` for article dates).
 */
export interface BarkparkMetadataDoc {
  title?: string
  name?: string
  excerpt?: string
  description?: string
  publishedAt?: string
  _type?: string
}

/** Per-call overrides that win over the document's own fields. */
export interface BarkparkMetadataOverrides {
  title?: string
  description?: string
}

/**
 * Build a Next.js {@link Metadata} object from a Barkpark document — the SEO /
 * Open Graph boilerplate (`{ title, description, openGraph }`) that pages
 * otherwise hand-roll in every `generateMetadata`. Pure and framework-safe (no
 * server-only imports), so it lives on the package root.
 *
 * - Title falls back `override.title → doc.title → doc.name`.
 * - Description falls back `override.description → doc.excerpt → doc.description`,
 *   trimmed; blank/whitespace collapses to `undefined` (omitted, never `""`).
 * - Open Graph `type` is `'article'` when the doc carries a `publishedAt` (then
 *   `publishedTime` is set too), otherwise `'website'`.
 * - A missing/`null` doc with no overrides yields `{ openGraph: { type: 'website' } }`.
 */
export function barkparkMetadata(
  doc: BarkparkMetadataDoc | null | undefined,
  overrides: BarkparkMetadataOverrides = {},
): Metadata {
  const title = overrides.title ?? doc?.title ?? doc?.name
  const description = (overrides.description ?? doc?.excerpt ?? doc?.description)?.trim() || undefined
  const publishedTime =
    typeof doc?.publishedAt === 'string' && doc.publishedAt.length > 0 ? doc.publishedAt : undefined

  const common = {
    ...(title !== undefined ? { title } : {}),
    ...(description !== undefined ? { description } : {}),
  }

  const openGraph: NonNullable<Metadata['openGraph']> =
    publishedTime !== undefined
      ? { ...common, type: 'article', publishedTime }
      : { ...common, type: 'website' }

  return { ...common, openGraph }
}
