'use client'

// App Router error boundary — catches render/runtime errors in this segment and
// offers a retry (reset re-renders the segment). Must be a client component.
export default function Error({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <div className="mx-auto max-w-lg py-16 text-center">
      <h1 className="text-3xl font-bold">Something went wrong</h1>
      <p className="mt-3 text-slate-600 dark:text-slate-300">
        An unexpected error occurred while rendering this page.
      </p>
      <button
        type="button"
        onClick={reset}
        className="mt-6 inline-block rounded bg-slate-900 px-4 py-2 text-sm font-medium text-white dark:bg-white dark:text-slate-900"
      >
        Try again
      </button>
    </div>
  )
}
