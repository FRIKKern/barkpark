import { draftMode } from 'next/headers'
import { notFound } from 'next/navigation'
import Link from 'next/link'
import { PortableText } from '@barkpark/react'
import { getDocBySlug, getDocById } from '../../../lib/barkpark'
import { DraftModePreview } from './draft-preview'

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
  content?: Parameters<typeof PortableText>[0]['value']
  author?: { _ref: string }
  tags?: Array<{ _ref: string }>
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
    <article className="prose max-w-none dark:prose-invert">
      <h1 className="text-4xl font-bold">{post.title}</h1>
      {post.publishedAt ? (
        <p className="text-sm text-slate-500">
          {new Date(post.publishedAt).toLocaleDateString()}
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
      {post.content ? <PortableText value={post.content} /> : null}
    </article>
  )
}
