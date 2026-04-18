import Link from 'next/link'
import { getDoc, getDocs } from '../lib/barkpark'

interface Page {
  _id: string
  title: string
  subtitle?: string
}

interface Post {
  _id: string
  title: string
  excerpt?: string
  slug?: { current: string }
  publishedAt?: string
}

export default async function HomePage() {
  const [home, posts] = await Promise.all([
    getDoc<Page>('page', 'home'),
    getDocs<Post>('post'),
  ])

  return (
    <div className="space-y-12">
      <section className="space-y-3">
        <h1 className="text-4xl font-bold">{home?.title ?? 'Welcome'}</h1>
        {home?.subtitle ? (
          <p className="text-lg text-slate-600 dark:text-slate-300">{home.subtitle}</p>
        ) : (
          <p className="text-lg text-slate-600 dark:text-slate-300">
            Run <code className="rounded bg-slate-100 px-1 py-0.5 dark:bg-slate-800">pnpm seed</code> to populate this site.
          </p>
        )}
      </section>

      <section className="space-y-4">
        <h2 className="text-2xl font-semibold">Latest posts</h2>
        {posts.length === 0 ? (
          <p className="text-slate-500">No posts yet.</p>
        ) : (
          <ul className="space-y-4">
            {posts.map((post) => {
              const slug = post.slug?.current ?? post._id
              return (
                <li key={post._id} className="border-b border-slate-200 pb-4 dark:border-slate-800">
                  <Link href={`/posts/${slug}`} className="block">
                    <h3 className="text-xl font-medium">{post.title}</h3>
                    {post.excerpt ? (
                      <p className="text-slate-600 dark:text-slate-400">{post.excerpt}</p>
                    ) : null}
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
