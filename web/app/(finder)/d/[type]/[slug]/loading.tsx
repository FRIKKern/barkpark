/**
 * Route-level fallback for the detail pane. DetailPage is an async server
 * component awaiting getDocument() (ISR revalidate=300), so on a cache miss or
 * cold start a finder-result / graph-node click would otherwise freeze the
 * previous pane with no feedback. This gives Next an instant skeleton that
 * mirrors DetailChrome + the reader column — static markup only (no client
 * component, no data) so the fallback paints immediately.
 */
export default function DetailLoading() {
  return (
    <div>
      <header className="sticky top-0 z-10 flex items-center gap-3 border-b border-zinc-200 bg-white/90 px-4 py-3 backdrop-blur dark:border-zinc-800 dark:bg-zinc-950/90">
        <div className="h-5 w-14 animate-pulse rounded-full bg-zinc-200 dark:bg-zinc-800" />
        <div className="h-5 w-48 animate-pulse rounded bg-zinc-200 dark:bg-zinc-800" />
      </header>

      <div className="mx-auto max-w-2xl px-4 py-8 space-y-4">
        <div className="h-9 w-40 animate-pulse rounded-md bg-zinc-200 dark:bg-zinc-800" />
        <div className="h-3 w-full animate-pulse rounded bg-zinc-100 dark:bg-zinc-900" />
        <div className="h-3 w-full animate-pulse rounded bg-zinc-100 dark:bg-zinc-900" />
        <div className="h-3 w-2/3 animate-pulse rounded bg-zinc-100 dark:bg-zinc-900" />
      </div>
    </div>
  );
}
