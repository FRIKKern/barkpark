import Link from 'next/link'
import { getDocs } from '../lib/barkpark'
import { POSTS_PER_PAGE } from '../lib/queries'
import { Pagination } from './components/Pagination'

interface Post {
  _id: string
  title: string
  excerpt?: string
  slug?: { current: string }
  publishedAt?: string
  author?: { _ref: string }
}

interface HomeProps {
  searchParams: Promise<{ page?: string }>
}

export default async function HomePage({ searchParams }: HomeProps) {
  const sp = await searchParams
  const pageNum = Math.max(1, Number(sp.page ?? '1') || 1)
  const offset = (pageNum - 1) * POSTS_PER_PAGE

  const posts = await getDocs<Post>('post', {
    limit: POSTS_PER_PAGE + 1,
    offset,
  })
  const hasNext = posts.length > POSTS_PER_PAGE
  const visible = posts.slice(0, POSTS_PER_PAGE)

  return (
    <div className="space-y-10">
      <section className="space-y-3">
        <h1 className="text-4xl font-bold">Latest posts</h1>
        <p className="text-slate-600 dark:text-slate-300">
          Page {pageNum}. Run <code className="rounded bg-slate-100 px-1 py-0.5 dark:bg-slate-800">pnpm seed</code> to populate sample content.
        </p>
      </section>

      {visible.length === 0 ? (
        <p className="text-slate-500">No posts yet.</p>
      ) : (
        <ul className="grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {visible.map((post) => {
            const slug = post.slug?.current ?? post._id
            return (
              <li
                key={post._id}
                className="rounded border border-slate-200 p-4 dark:border-slate-800"
              >
                <Link href={`/posts/${slug}`} className="block space-y-2">
                  <h2 className="text-lg font-medium">{post.title}</h2>
                  {post.excerpt ? (
                    <p className="text-sm text-slate-600 dark:text-slate-400">{post.excerpt}</p>
                  ) : null}
                  {post.publishedAt ? (
                    <p className="text-xs text-slate-500">
                      {new Date(post.publishedAt).toLocaleDateString()}
                    </p>
                  ) : null}
                </Link>
              </li>
            )
          })}
        </ul>
      )}

      <Pagination
        currentPage={pageNum}
        totalPages={hasNext ? pageNum + 1 : pageNum}
        basePath="/"
      />
    </div>
  )
}
