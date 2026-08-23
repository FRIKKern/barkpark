import type { Metadata } from 'next'
import { notFound } from 'next/navigation'
import type { Block } from '@barkpark/react'
import { barkparkMetadata } from '@barkpark/nextjs'
// The canonical PortableDoc skin — ONE stylesheet for the `bp-*` classes the
// renderer emits (the same one Phoenix's `/papers` reader compiles in).
import '@barkpark/react/paper-surface.css'
import { getDocBySlug } from '../../../lib/barkpark'
import { formatDate } from '../../../lib/format-date'
import { PortableDocSurface } from '../../portable-doc-surface'

interface Post {
  _id: string
  title: string
  excerpt?: string
  publishedAt?: string
  slug?: { current: string }
  // The canonical, type-keyed PortableDocument block array (Barkpark's own
  // block grammar) — rendered by `@barkpark/react`'s PortableDoc, NOT Sanity
  // PortableText.
  content?: Block[]
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>
}): Promise<Metadata> {
  const { slug } = await params
  // Reuses the request-memoized fetch, so this doesn't double-fetch the post.
  const post = await getDocBySlug<Post>('post', slug)
  if (!post) return {}
  return barkparkMetadata(post)
}

export default async function PostPage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params
  const post = await getDocBySlug<Post>('post', slug)
  if (!post) notFound()

  return (
    <article>
      <h1 className="text-4xl font-bold">{post.title}</h1>
      {formatDate(post.publishedAt) ? (
        <p className="text-sm text-slate-500">
          {formatDate(post.publishedAt)}
        </p>
      ) : null}
      {post.excerpt ? <p className="text-lg">{post.excerpt}</p> : null}
      {/*
        renderPortableDocument runs inside PortableDocSurface (SSR-rendered); only
        the mermaid diagram + asciicast mount points hydrate on the client.
      */}
      {post.content ? <PortableDocSurface blocks={post.content} /> : null}
    </article>
  )
}
