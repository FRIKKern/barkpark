// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Wave-3 composed post corpus (charter D28 Option C). These are hand-authored,
// MULTI-block `PortableDocument`s — the document-level consumption proof: each is
// rendered with a single `<PortableDoc value={post.blocks} />` (many blocks, one
// surface), proving Next consumes the canonical renderer at document scale, not
// just the single-block parity grid on the index route.
//
// Posts are NOT parity-asserted against the goldens (they are composed docs, not
// single-block fixtures — D28). What they DO prove is per-route SEO: a DATED post
// (`publishedAt` set) drives `og:type=article` + `article:published_time`; an
// UNDATED post drives `og:type=website` with the timestamp ABSENT (D31).
import type { Block } from '@barkpark/react'

export interface Post {
  slug: string
  title: string
  excerpt: string
  /** ISO-8601 timestamp; omitted for drafts (drives og:type=website vs article). */
  publishedAt?: string
  blocks: Block[]
}

export const POSTS: Post[] = [
  {
    slug: 'one-renderer-every-surface',
    title: 'One Renderer, Every Surface',
    excerpt:
      'The canonical @barkpark/react PortableDoc renders the same block grammar on Phoenix, Astro, and now Next.',
    publishedAt: '2026-07-16T09:00:00.000Z',
    blocks: [
      { type: 'heading', level: 1, content: [{ type: 'text', value: 'One Renderer, Every Surface' }] },
      {
        type: 'paragraph',
        content: [
          { type: 'text', value: 'The same ' },
          { type: 'text', value: 'type-keyed', marks: [{ type: 'bold' }] },
          {
            type: 'text',
            value: ' PortableDoc renderer now consumes cleanly in a Next.js static export.',
          },
        ],
      },
      {
        type: 'callout',
        content: [{ type: 'text', value: 'Sub-path hosting works: basePath /blog bakes into every asset URL.' }],
      },
    ],
  },
  {
    slug: 'proving-dom-shape-parity',
    title: 'Proving DOM-Shape Parity',
    excerpt: 'How the golden harness proves the JS output matches the Elixir source of truth, node for node.',
    publishedAt: '2026-07-16T11:30:00.000Z',
    blocks: [
      { type: 'heading', level: 1, content: [{ type: 'text', value: 'Proving DOM-Shape Parity' }] },
      {
        type: 'paragraph',
        content: [
          {
            type: 'text',
            value: 'The comparator asserts tag + class-set + data-* + text, node for node — never bytes.',
          },
        ],
      },
      {
        type: 'list',
        style: 'bullet',
        items: [
          { content: [{ type: 'text', value: 'Elixir compose.ex is the read-only source of truth.' }] },
          { content: [{ type: 'text', value: 'The frozen pd-golden fixtures are canonical.' }] },
          { content: [{ type: 'text', value: 'The JS must match 1:1.' }] },
        ],
      },
    ],
  },
  {
    slug: 'draft-notes-on-hydration',
    title: 'Draft Notes on Hydration',
    excerpt: 'An unpublished working note — no publish date, so it is an og:type=website page.',
    // No publishedAt: this is a DRAFT — drives og:type=website + NO article:published_time.
    blocks: [
      { type: 'heading', level: 1, content: [{ type: 'text', value: 'Draft Notes on Hydration' }] },
      {
        type: 'paragraph',
        content: [
          {
            type: 'text',
            value: 'Media + live-block hydration is a later wave; this draft carries no publish date.',
          },
        ],
      },
    ],
  },
]

export function getPost(slug: string): Post | undefined {
  return POSTS.find((p) => p.slug === slug)
}
