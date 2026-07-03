import type { Metadata } from 'next'
import { notFound } from 'next/navigation'
import { PortableText } from '@barkpark/react'
import { barkparkMetadata } from '@barkpark/nextjs'
import { getDocBySlug } from '../../../lib/barkpark'

interface Post {
  _id: string
  title: string
  excerpt?: string
  publishedAt?: string
  slug?: { current: string }
  content?: Parameters<typeof PortableText>[0]['value']
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
    <article className="prose max-w-none dark:prose-invert">
      <h1 className="text-4xl font-bold">{post.title}</h1>
      {post.publishedAt ? (
        <p className="text-sm text-slate-500">
          {new Date(post.publishedAt).toLocaleDateString()}
        </p>
      ) : null}
      {post.excerpt ? <p className="text-lg">{post.excerpt}</p> : null}
      {post.content ? <PortableText value={post.content} /> : null}
    </article>
  )
}
