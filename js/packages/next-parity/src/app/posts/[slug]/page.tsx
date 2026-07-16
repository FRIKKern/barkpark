// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Wave-3 composed post route (charter D28 Option C + D31 SEO).
//
// A dynamic route under `output:'export'` REQUIRES `generateStaticParams` — it
// enumerates the slugs so `next build` bakes one `out/posts/<slug>.html` per post.
// Each post is a multi-block composed `PortableDocument` rendered with a single
// `<PortableDoc value={post.blocks} />` — the document-level consumption proof.
//
// `generateMetadata → barkparkMetadata` wires per-route SEO into each exported
// head: a DATED post yields `og:type=article` + `article:published_time`; an
// UNDATED (draft) post yields `og:type=website` with the timestamp ABSENT (D31).
// No `og:image` / preview manifest — that is out of W3 scope by design.
import type { Metadata } from 'next'
import { notFound } from 'next/navigation'
import { PortableDoc } from '@barkpark/react'
import { barkparkMetadata } from '@barkpark/nextjs'
import { POSTS, getPost } from '../../../posts/data'

export const dynamicParams = false

export function generateStaticParams(): Array<{ slug: string }> {
  return POSTS.map((p) => ({ slug: p.slug }))
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>
}): Promise<Metadata> {
  const { slug } = await params
  const post = getPost(slug)
  if (!post) return {}
  // barkparkMetadata reads title/excerpt/publishedAt and emits the og:* boilerplate.
  return barkparkMetadata(post)
}

export default async function PostPage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params
  const post = getPost(slug)
  if (!post) notFound()
  return (
    <article className="bp-post">
      <PortableDoc value={post.blocks} />
    </article>
  )
}
