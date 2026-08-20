import Link from "next/link";

/** Global 404 — an unknown document type/slug, or a hand-typed path. Links back
 * to the finder home (basePath-aware via next/link). */
export default function NotFound() {
  return (
    <div className="flex h-screen w-full flex-col items-center justify-center gap-4 px-8 text-center">
      {/* The old zinc 400/600 light-dark pairing failed in BOTH modes
          (2.42–2.56:1 light, 2.09–2.57:1 dark) — below even the 3:1 non-text
          floor. One --color-muted-text covers both (5.02–5.42 light,
          5.71–7.77 dark). Class names are deliberately NOT spelled out here:
          Tailwind's source scanner does not strip comments, so naming a
          utility in prose still emits its rule into the shipped CSS. */}
      <p className="font-mono text-sm text-muted-text">404</p>
      <h1 className="text-lg font-medium text-zinc-900 dark:text-zinc-100">
        Not found
      </h1>
      <p className="max-w-md text-sm text-muted-text">
        That document doesn&apos;t exist. Head back and search for what you need.
      </p>
      <Link
        href="/"
        className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-zinc-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
      >
        Back to search
      </Link>
    </div>
  );
}
