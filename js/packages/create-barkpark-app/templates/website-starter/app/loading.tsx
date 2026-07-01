// Shown while a route segment's async data resolves (Next streams this instantly,
// then swaps in the page). A lightweight skeleton beats a blank screen.
export default function Loading() {
  return (
    <div className="mx-auto max-w-3xl animate-pulse space-y-4 py-8" aria-busy="true" aria-label="Loading">
      <div className="h-8 w-2/3 rounded bg-slate-200 dark:bg-slate-800" />
      <div className="h-4 w-1/3 rounded bg-slate-200 dark:bg-slate-800" />
      <div className="space-y-2 pt-4">
        <div className="h-4 w-full rounded bg-slate-200 dark:bg-slate-800" />
        <div className="h-4 w-full rounded bg-slate-200 dark:bg-slate-800" />
        <div className="h-4 w-4/5 rounded bg-slate-200 dark:bg-slate-800" />
      </div>
    </div>
  )
}
