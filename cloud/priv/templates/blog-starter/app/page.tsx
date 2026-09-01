import Link from 'next/link'
import { countDocs, getDocs } from '../lib/barkpark'
import { POSTS_PER_PAGE } from '../lib/queries'
import { pageCount, resolvePageParam } from '../lib/page-param'
import { Pagination } from './components/Pagination'
import { formatDate } from '../lib/format-date'

interface Post {
  _id: string
  title: string
  excerpt?: string
  slug?: { current: string }
  publishedAt?: string
  author?: { _ref: string }
}

interface HomeProps {
  // Next hands an ARRAY when a param repeats (`?page=2&page=9`), so the type
  // has to admit it — and `resolvePageParam` has to handle it.
  searchParams: Promise<{ page?: string | string[] }>
}

export default async function HomePage({ searchParams }: HomeProps) {
  const sp = await searchParams

  // `?page=` is anonymous, caller-controlled input, and `totalPages` flows
  // straight into `Array.from({ length: totalPages })` inside <Pagination>, a
  // SERVER component. So the page number is clamped to the REAL corpus size
  // before it is used for anything: `countDocs` is one small fetch that returns
  // the envelope's true total-match count. Without the upper clamp,
  // `?page=20000` renders 20 000 <Link> elements server-side per request and
  // `?page=Infinity` throws RangeError (a 500) — see lib/page-param.ts.
  const totalPages = pageCount(await countDocs('post'), POSTS_PER_PAGE)
  const pageNum = resolvePageParam(sp.page, totalPages)
  const offset = (pageNum - 1) * POSTS_PER_PAGE

  const posts = await getDocs<Post>('post', {
    limit: POSTS_PER_PAGE,
    offset,
  })

  return (
    <div className="space-y-10">
      <section className="space-y-3">
        <h1 className="text-4xl font-bold">Latest posts</h1>
        <p className="text-slate-600 dark:text-slate-300">
          Page {pageNum}. Run <code className="rounded bg-slate-100 px-1 py-0.5 dark:bg-slate-800">pnpm seed</code> to populate sample content.
        </p>
      </section>

      {posts.length === 0 ? (
        <p className="text-slate-500">No posts yet.</p>
      ) : (
        <ul className="grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {posts.map((post) => {
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
                  {formatDate(post.publishedAt) ? (
                    <p className="text-xs text-slate-500">
                      {formatDate(post.publishedAt)}
                    </p>
                  ) : null}
                </Link>
              </li>
            )
          })}
        </ul>
      )}

      <Pagination currentPage={pageNum} totalPages={totalPages} basePath="/" />
    </div>
  )
}
