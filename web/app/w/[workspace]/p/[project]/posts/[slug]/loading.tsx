/**
 * Route-level fallback for a scoped post detail. The page awaits getPost() at
 * the top level (no inner <Suspense>), so on a cache miss or cold navigation the
 * previous pane would freeze with no feedback. This mirrors PostArticle's
 * standalone chrome — back-link, title, byline, body — as static markup (no
 * client component, no data) so the fallback paints immediately and the real
 * article slots in without a layout jump.
 */
export default function ScopedPostLoading() {
  return (
    <main className="mx-auto flex min-h-screen w-full max-w-2xl flex-col gap-8 px-6 py-16">
      {/* back-link */}
      <div className="h-4 w-32 animate-pulse rounded bg-zinc-100 dark:bg-zinc-900" />

      <article className="flex flex-col gap-6">
        <header className="flex flex-col gap-3 border-b border-zinc-200 pb-6 dark:border-zinc-800">
          <div className="h-10 w-3/4 animate-pulse rounded-md bg-zinc-200 dark:bg-zinc-800" />
          <div className="h-4 w-40 animate-pulse rounded bg-zinc-100 dark:bg-zinc-900" />
        </header>

        <div className="flex flex-col gap-4">
          <div className="h-4 w-full animate-pulse rounded bg-zinc-100 dark:bg-zinc-900" />
          <div className="h-4 w-full animate-pulse rounded bg-zinc-100 dark:bg-zinc-900" />
          <div className="h-4 w-5/6 animate-pulse rounded bg-zinc-100 dark:bg-zinc-900" />
          <div className="h-4 w-2/3 animate-pulse rounded bg-zinc-100 dark:bg-zinc-900" />
        </div>
      </article>
    </main>
  );
}
