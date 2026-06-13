import type { Metadata } from "next";
import { Suspense } from "react";
import { Finder } from "@/components/finder";

export const metadata: Metadata = {
  title: "Find anything · Barkpark",
  description:
    "Advanced finder across every Barkpark document type — Postgres precision or Indx fuzzy/typo-tolerant search, faceted by type.",
};

/** `<Finder>` reads `useSearchParams`, which requires a Suspense boundary. */
export default function FindPage() {
  return (
    <Suspense
      fallback={
        <main className="mx-auto w-full max-w-4xl px-6 py-12">
          <div className="h-9 w-48 animate-pulse rounded-md bg-zinc-200 dark:bg-zinc-800" />
        </main>
      }
    >
      <Finder />
    </Suspense>
  );
}
