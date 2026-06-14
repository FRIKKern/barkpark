import { Suspense } from "react";
import Link from "next/link";
import { client } from "@/lib/barkpark-client";
import {
  fetchPapers,
  paperSlug,
  paperTitle,
  paperExcerpt,
  type PaperDocument,
} from "@/lib/papers";
import { PostsListSkeleton } from "@/components/posts-list";

export const dynamic = "force-dynamic";

function shortDate(value?: string): string | null {
  if (!value) return null;
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return null;
  return new Intl.DateTimeFormat("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
  }).format(d);
}

const shell =
  "mx-auto flex min-h-screen w-full max-w-2xl flex-col gap-8 px-6 py-16";

async function PapersListing() {
  let papers: PaperDocument[] = [];
  let error: string | null = null;

  try {
    papers = await fetchPapers(client);
  } catch (err) {
    error = err instanceof Error ? err.message : String(err);
  }

  return (
    <main className={shell}>
      <header className="flex flex-col gap-3 border-b border-zinc-200 pb-8 dark:border-zinc-800">
        <h1 className="text-4xl font-semibold tracking-tight">Papers</h1>
        <p className="text-zinc-500 dark:text-zinc-400">
          Portable Docs —{" "}
          <span className="text-zinc-700 dark:text-zinc-300">
            {error ? "" : `${papers.length} `}published
          </span>{" "}
          block documents from the{" "}
          <code className="rounded bg-zinc-200/70 px-1.5 py-0.5 font-mono text-[0.8em] dark:bg-zinc-800/70">
            production
          </code>{" "}
          dataset.
        </p>
      </header>

      {error ? (
        <section className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-900 dark:border-red-900/60 dark:bg-red-950/40 dark:text-red-200">
          <strong className="font-medium">Failed to load papers.</strong>
          <pre className="mt-2 whitespace-pre-wrap text-xs">{error}</pre>
        </section>
      ) : papers.length === 0 ? (
        <p className="text-zinc-500">No published papers yet.</p>
      ) : (
        <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
          {papers.map((paper) => {
            const excerpt = paperExcerpt(paper);
            const date =
              shortDate(paper.publishedAt as string | undefined) ??
              shortDate(paper._updatedAt);
            return (
              <li key={paper._id}>
                <Link
                  href={`/d/paper/${paperSlug(paper)}`}
                  className="group -mx-3 flex flex-col gap-1.5 rounded-lg px-3 py-5 transition-colors hover:bg-zinc-100 dark:hover:bg-zinc-900/60"
                >
                  <span className="flex items-center gap-2 text-lg font-medium tracking-tight">
                    {paperTitle(paper)}
                    <span
                      aria-hidden
                      className="translate-x-0 text-zinc-400 opacity-0 transition-all group-hover:translate-x-1 group-hover:opacity-100"
                    >
                      →
                    </span>
                  </span>
                  {excerpt ? (
                    <span className="line-clamp-2 text-sm text-zinc-600 dark:text-zinc-400">
                      {excerpt}
                    </span>
                  ) : null}
                  <span className="flex flex-wrap items-center gap-x-2 text-xs text-zinc-400">
                    {date ? <span>{date}</span> : null}
                    {date ? <span aria-hidden>·</span> : null}
                    <span className="font-mono">/d/paper/{paperSlug(paper)}</span>
                  </span>
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </main>
  );
}

export default function PapersPage() {
  return (
    <Suspense fallback={<PostsListSkeleton />}>
      <PapersListing />
    </Suspense>
  );
}
