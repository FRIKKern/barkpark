import Link from 'next/link'

// Rendered when a route calls notFound() (e.g. an unknown post slug) or a URL
// matches nothing. Replaces Next's unstyled default 404 with a branded page.
export default function NotFound() {
  return (
    <div className="mx-auto max-w-lg py-16 text-center">
      <p className="text-sm font-medium text-slate-500">404</p>
      <h1 className="mt-2 text-3xl font-bold">Page not found</h1>
      <p className="mt-3 text-slate-600 dark:text-slate-300">
        The page you&rsquo;re looking for doesn&rsquo;t exist or may have been moved.
      </p>
      <Link
        href="/"
        className="mt-6 inline-block rounded bg-slate-900 px-4 py-2 text-sm font-medium text-white dark:bg-white dark:text-slate-900"
      >
        Back home
      </Link>
    </div>
  )
}
