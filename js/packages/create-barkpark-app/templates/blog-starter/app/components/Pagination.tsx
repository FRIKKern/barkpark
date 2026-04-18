import Link from 'next/link'

interface PaginationProps {
  currentPage: number
  totalPages: number
  basePath: string
}

export function Pagination({ currentPage, totalPages, basePath }: PaginationProps) {
  if (totalPages <= 1) return null

  const pageNumbers = Array.from({ length: totalPages }, (_, i) => i + 1)
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
              <span className="rounded bg-slate-900 px-2 py-1 text-white dark:bg-slate-100 dark:text-slate-900">
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
