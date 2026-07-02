"use client";

import Link from "next/link";
import { useEffect } from "react";

// Catches errors thrown by the root layout itself. It replaces that layout, so
// it must ship its own <html>/<body>. Global CSS may not be loaded here, so the
// styling stays inline-Tailwind-only and self-contained.
export default function GlobalError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error(error);
  }, [error]);

  return (
    <html lang="en">
      <body>
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
      </body>
    </html>
  );
}
