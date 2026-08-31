import Link from 'next/link'
import { pageWindow } from '../../lib/page-param'

interface PaginationProps {
  currentPage: number
  totalPages: number
  basePath: string
}

export function Pagination({ currentPage, totalPages, basePath }: PaginationProps) {
  if (!Number.isFinite(totalPages) || totalPages <= 1) return null

  // This is a SERVER component: every element below is materialised on the
  // server, per request. `pageWindow` therefore owns the array length — it is
  // bounded by MAX_PAGE_LINKS and can never be Infinity, so a caller that
  // passed an unclamped page number (or a corpus that grew to 5 000 pages)
  // cannot turn one request into thousands of server-rendered <Link>s. The
  // previous version built the array straight from `totalPages` and so had no
  // such bound — `?page=Infinity` reached it and threw RangeError (a 500).
  const pageNumbers = pageWindow(currentPage, totalPages)
  const href = (n: number): string =>
    n === 1 ? basePath : `${basePath}${basePath.includes('?') ? '&' : '?'}page=${n}`

  return (
    <nav className="flex items-center justify-between text-sm" aria-label="Pagination">
      {currentPage > 1 ? (
        <Link href={href(currentPage - 1)} className="underline" aria-label="Previous page">
          ← Newer
        </Link>
      ) : (
        <span />
      )}
      <ul className="flex gap-2">
        {pageNumbers.map((n) => (
          <li key={n}>
            {n === currentPage ? (
              <span
                aria-current="page"
                className="rounded bg-slate-900 px-2 py-1 text-white dark:bg-slate-100 dark:text-slate-900"
              >
                {n}
              </span>
            ) : (
              <Link href={href(n)} className="rounded px-2 py-1 hover:bg-slate-100 dark:hover:bg-slate-800">
                {n}
              </Link>
            )}
          </li>
        ))}
      </ul>
      {currentPage < totalPages ? (
        <Link href={href(currentPage + 1)} className="underline" aria-label="Next page">
          Older →
        </Link>
      ) : (
        <span />
      )}
    </nav>
  )
}
