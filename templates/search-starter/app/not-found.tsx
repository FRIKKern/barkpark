import Link from "next/link";

/** Global 404 — an unknown document type/slug, or a hand-typed path. Links back
 * to the finder home (basePath-aware via next/link). */
export default function NotFound() {
  return (
    <div className="flex h-screen w-full flex-col items-center justify-center gap-4 px-8 text-center">
      <p className="font-mono text-sm text-zinc-400 dark:text-zinc-600">404</p>
      <h1 className="text-lg font-medium text-zinc-900 dark:text-zinc-100">
        Not found
      </h1>
      <p className="max-w-md text-sm text-zinc-500 dark:text-zinc-400">
        That document doesn&apos;t exist. Head back and search for what you need.
      </p>
      <Link
        href="/"
        className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
      >
        Back to search
      </Link>
    </div>
  );
}
