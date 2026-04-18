import Link from 'next/link'
import { notFound } from 'next/navigation'
import { getDocBySlug, getDocs } from '../../../lib/barkpark'

interface Tag {
  _id: string
  title: string
  description?: string
  slug?: { current: string }
}

interface Post {
  _id: string
  title: string
  slug?: { current: string }
  excerpt?: string
  publishedAt?: string
  tags?: Array<{ _ref: string }>
}

export default async function TagPage({
  params,
}: {
  params: Promise<{ slug: string }>
}) {
  const { slug } = await params
  const tag = await getDocBySlug<Tag>('tag', slug)
  if (!tag) notFound()

  const allPosts = await getDocs<Post>('post')
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
              const postSlug = post.slug?.current ?? post._id
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
