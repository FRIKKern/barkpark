// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { PortableTextBlock, PortableTextNode } from './PortableText'

/**
 * Extracts the plain text from a Portable Text value — the utility behind
 * excerpts, SEO meta descriptions, reading-time estimates, and search indexing.
 *
 * Each `block` node contributes the concatenation of its spans' `text`; blocks
 * are separated by a blank line (`\n\n`), the Portable Text ecosystem
 * convention. Non-`block` custom nodes (images, embeds, …) contribute nothing,
 * so they never inject stray separators. Malformed input — a missing/non-array
 * `children`, a non-string span `text`, or a nullish value — is skipped rather
 * than throwing, the same fail-soft posture as the renderer.
 *
 * Pure and dependency-free, so it runs in a Server Component (e.g. Next.js
 * `generateMetadata`) as happily as on the client.
 *
 * @example
 * import { toPlainText } from '@barkpark/react'
 *
 * export function generateMetadata({ post }) {
 *   return { description: toPlainText(post.body).slice(0, 160) }
 * }
 */
export function toPlainText(
  value: PortableTextNode | PortableTextNode[] | null | undefined,
): string {
  if (value == null) return ''
  const nodes = Array.isArray(value) ? value : [value]
  const parts: string[] = []
  for (const node of nodes) {
    if (!node || node._type !== 'block') continue
    const block = node as PortableTextBlock
    if (!Array.isArray(block.children)) continue
    let text = ''
    for (const child of block.children) {
      if (child && typeof child.text === 'string') text += child.text
    }
    parts.push(text)
  }
  return parts.join('\n\n')
}
