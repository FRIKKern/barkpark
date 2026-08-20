import type { Metadata } from 'next'
import { draftMode } from 'next/headers'
import { notFound } from 'next/navigation'
import Link from 'next/link'
import type { Block } from '@barkpark/react'
import { barkparkMetadata } from '@barkpark/nextjs'
// The canonical PortableDoc skin — ONE stylesheet for the `bp-*` classes the
// renderer emits (the same one Phoenix's `/papers` reader compiles in).
import '@barkpark/react/paper-surface.css'
import { getDocBySlug, getDocById } from '../../../lib/barkpark'
import { formatDate } from '../../../lib/format-date'
import { DraftModePreview } from './draft-preview'
import { PortableDocSurface } from './portable-doc-surface'

interface Author {
  _id: string
  name: string
  slug?: { current: string }
}

interface Tag {
  _id: string
  title: string
  slug?: { current: string }
}

interface Post {
  _id: string
  _type: string
  title: string
  excerpt?: string
  publishedAt?: string
  slug?: { current: string }
  // The canonical, type-keyed PortableDocument block array (Barkpark's own
  // block grammar) — rendered by `@barkpark/react`'s `PortableDoc`, NOT Sanity
  // PortableText.
  content?: Block[]
  author?: { _ref: string }
  tags?: Array<{ _ref: string }>
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>
}): Promise<Metadata> {
  const { slug } = await params
  // Metadata always describes the PUBLISHED post — crawlers see the public page,
  // never a draft. (getDocBySlug memoizes per request, so this doesn't double-fetch.)
  const post = await getDocBySlug<Post>('post', slug, false)
  if (!post) return {}
  // barkparkMetadata builds { title, description, openGraph } from the doc —
  // publishedAt makes it an OG `article` with `publishedTime`.
  return barkparkMetadata(post)
}

export default async function PostPage({
  params,
}: {
  params: Promise<{ slug: string }>
}) {
  const { slug } = await params
  const { isEnabled: isDraft } = await draftMode()

  const post = await getDocBySlug<Post>('post', slug, isDraft)
  if (!post) notFound()

  const [author, tags] = await Promise.all([
    post.author?._ref ? getDocById<Author>('author', post.author._ref, isDraft) : null,
    Promise.all(
      (post.tags ?? []).map((t) => getDocById<Tag>('tag', t._ref, isDraft)),
    ).then((arr) => arr.filter((t): t is Tag => t !== null)),
  ])

  if (isDraft) {
    return <DraftModePreview initialPost={post} author={author} tags={tags} />
  }

  return (
    <article>
      <h1 className="text-4xl font-bold">{post.title}</h1>
      {formatDate(post.publishedAt) ? (
        <p className="text-sm text-slate-500">
          {formatDate(post.publishedAt)}
          {author ? (
            <>
              {' · '}
              <Link href={`/authors/${author._id}`}>{author.name}</Link>
            </>
          ) : null}
        </p>
      ) : null}
      {tags.length > 0 ? (
        <p className="flex flex-wrap gap-2 text-xs">
          {tags.map((t) => (
            <Link
              key={t._id}
              href={`/tags/${t.slug?.current ?? t._id}`}
              className="rounded bg-slate-100 px-2 py-0.5 dark:bg-slate-800"
            >
              #{t.title}
            </Link>
          ))}
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
