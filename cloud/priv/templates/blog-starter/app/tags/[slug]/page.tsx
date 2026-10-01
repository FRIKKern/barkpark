import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { barkparkMetadata } from '@barkpark/nextjs'
import { getAllDocs, getDocBySlug } from '../../../lib/barkpark'
import { slugOf, type SlugValue } from '../../../lib/slug'

interface Tag {
  _id: string
  title: string
  description?: string
  slug?: SlugValue
}

interface Post {
  _id: string
  title: string
  slug?: SlugValue
  excerpt?: string
  publishedAt?: string
  tags?: Array<{ _ref: string }>
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>
}): Promise<Metadata> {
  const { slug } = await params
  const tag = await getDocBySlug<Tag>('tag', slug)
  if (!tag) return {}
  return barkparkMetadata(tag, {
    title: `#${tag.title}`,
    description: tag.description?.trim() || `Posts tagged #${tag.title}`,
  })
}

export default async function TagPage({
  params,
}: {
  params: Promise<{ slug: string }>
}) {
  const { slug } = await params
  const tag = await getDocBySlug<Tag>('tag', slug)
  if (!tag) notFound()

  // Every post, not one page: getDocs reads the query route's default page
  // (100 rows), so filtering it here dropped every match past the first 100.
  const allPosts = await getAllDocs<Post>('post')
  const posts = allPosts.filter((p) => p.tags?.some((t) => t._ref === tag._id))

  return (
    <div className="space-y-8">
      <header className="space-y-2">
        <h1 className="text-4xl font-bold">#{tag.title}</h1>
        {tag.description ? (
          <p className="text-slate-600 dark:text-slate-300">{tag.description}</p>
        ) : null}
      </header>

      <section className="space-y-3">
        <h2 className="text-2xl font-semibold">Tagged posts</h2>
        {posts.length === 0 ? (
          <p className="text-slate-500">No posts with this tag yet.</p>
        ) : (
          <ul className="space-y-3">
            {posts.map((post) => {
              const postSlug = slugOf(post.slug) ?? post._id
              return (
                <li key={post._id}>
                  <Link href={`/posts/${postSlug}`} className="underline">
                    {post.title}
                  </Link>
                </li>
              )
            })}
          </ul>
        )}
      </section>
    </div>
  )
}
