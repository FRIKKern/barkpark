import Link from 'next/link'
import { notFound } from 'next/navigation'
import { getDocById, getDocs } from '../../../lib/barkpark'

interface Author {
  _id: string
  name: string
  bio?: string
  slug?: { current: string }
  twitter?: string
}

interface Post {
  _id: string
  title: string
  slug?: { current: string }
  excerpt?: string
  publishedAt?: string
  author?: { _ref: string }
}

export default async function AuthorPage({
  params,
}: {
  params: Promise<{ id: string }>
}) {
  const { id } = await params
  const author = await getDocById<Author>('author', id)
  if (!author) notFound()

  const allPosts = await getDocs<Post>('post')
  const posts = allPosts.filter((p) => p.author?._ref === id)

  return (
    <div className="space-y-8">
      <header className="space-y-2">
        <h1 className="text-4xl font-bold">{author.name}</h1>
        {author.bio ? (
          <p className="text-slate-600 dark:text-slate-300">{author.bio}</p>
        ) : null}
        {author.twitter ? (
          <p className="text-sm text-slate-500">@{author.twitter}</p>
        ) : null}
      </header>

      <section className="space-y-3">
        <h2 className="text-2xl font-semibold">Posts by {author.name}</h2>
        {posts.length === 0 ? (
          <p className="text-slate-500">No posts yet.</p>
        ) : (
          <ul className="space-y-3">
            {posts.map((post) => {
              const slug = post.slug?.current ?? post._id
              return (
                <li key={post._id}>
                  <Link href={`/posts/${slug}`} className="underline">
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
