import type { Metadata } from "next";
import { Suspense } from "react";
import { Finder } from "@/components/finder";

export const metadata: Metadata = {
  title: "Barkpark — search the whole CMS",
  description:
    "A headless CMS demo: one content model behind a Go TUI, a Phoenix Studio, a JS SDK, and this Next.js app. Find any document across every type — Postgres precision or Indx fuzzy/typo-tolerant search.",
};

/** The frontpage IS the finder — it showcases the CMS best: every document
 * type, faceted, searchable two ways. `<Finder>` reads `useSearchParams`, so it
 * needs a Suspense boundary. */
export default function Home() {
  return (
    <Suspense
      fallback={
        <main className="mx-auto w-full max-w-4xl px-6 py-12">
          <div className="h-12 w-72 max-w-full animate-pulse rounded-md bg-zinc-200 dark:bg-zinc-800" />
        </main>
      }
    >
      <Finder variant="home" />
    </Suspense>
  );
}
