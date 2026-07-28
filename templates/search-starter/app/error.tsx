"use client";

/**
 * Route-level error boundary. The finder degrades gracefully in-page (an
 * upstream hiccup renders an empty result set with an error line, never a
 * crash), so this only catches a genuine render fault — an honest, recoverable
 * panel rather than a blank screen.
 */
export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <div className="flex h-screen w-full flex-col items-center justify-center gap-4 px-8 text-center">
      <h1 className="text-lg font-medium text-zinc-900 dark:text-zinc-100">
        Something went wrong
      </h1>
      <p className="max-w-md text-sm text-muted-text">
        {error.message || "An unexpected error occurred while rendering this page."}
      </p>
      {/* `reset` is the only control on this screen — a keyboard visitor who
          lands here must be able to see where they are. */}
      <button
        type="button"
        onClick={reset}
        className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-zinc-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
      >
        Try again
      </button>
    </div>
  );
}
