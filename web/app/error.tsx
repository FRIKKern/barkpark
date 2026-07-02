"use client";

import Link from "next/link";
import { useEffect } from "react";

export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    // Next convention: surface the error to the console for diagnostics.
    console.error(error);
  }, [error]);

  return (
    <main className="mx-auto flex min-h-screen w-full max-w-2xl flex-col items-start justify-center gap-4 px-6 py-16">
      <p className="font-mono text-sm text-zinc-400">error</p>
      <h1 className="text-3xl font-semibold tracking-tight">
        Something went wrong.
      </h1>
      <p className="text-zinc-600 dark:text-zinc-400">
        An unexpected error interrupted this page. You can try again — if it
        keeps happening, head back home.
      </p>
      <div className="flex items-center gap-4">
        <button
          type="button"
          onClick={reset}
          className="rounded-md bg-zinc-900 px-3 py-1.5 text-sm font-medium text-zinc-50 transition-colors hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
        >
          Try again
        </button>
        <Link
          href="/"
          className="text-sm text-zinc-500 transition-colors hover:text-zinc-900 dark:hover:text-zinc-200"
        >
          ← back home
        </Link>
      </div>
    </main>
  );
}
