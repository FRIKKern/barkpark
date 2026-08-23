import { Suspense } from "react";
import Link from "next/link";
import { client } from "@/lib/barkpark-client";
import {
  paperSlug,
  paperTitle,
  paperExcerpt,
  fetchPapersByTag,
  type PaperDocument,
} from "@/lib/papers";
import {
  paperTagEntries,
  sortPapersByTagStrength,
  tagStrength,
} from "@/lib/paper-tags";
import { PostsListSkeleton } from "@/components/posts-list";
import { EmptyState } from "@/components/empty-state";

export const dynamic = "force-dynamic";

// Clone of /app/papers/page.tsx's container so the tag listing speaks the same
// visual language as the rest of the reader.
const shell =
  "mx-auto flex min-h-screen w-full max-w-2xl flex-col gap-8 px-6 py-16";

type Params = Promise<{ tag: string }>;

async function TagListing({ tag }: { tag: string }) {
  let papers: PaperDocument[] = [];
  let error: string | null = null;

  try {
    // `fetchPapersByTag` (lib/papers.ts) walks the corpus page by page — it
    // used to be a single capped `.limit(200).find()` call here, which would
    // have silently dropped members past 200 (task-269eefbe4864d8a5).
    papers = await fetchPapersByTag(client, tag);
  } catch (err) {
    error = err instanceof Error ? err.message : String(err);
  }

  // Defensive: the server already filtered, but confirm the tag is really present
  // (guards a name-encoding quirk and lets every strength/rationale lookup below
  // resolve). Then rank by the authored weight — strongest topical match first.
  const carrying = papers.filter((paper) =>
    paperTagEntries(paper.tags).some((entry) => entry.tag === tag),
  );
  const matches = sortPapersByTagStrength(carrying, tag);

  return (
    <main className={shell}>
      <header className="flex flex-col gap-3 border-b border-zinc-200 pb-8 dark:border-zinc-800">
        <h1 className="text-4xl font-semibold tracking-tight">#{tag}</h1>
        <p className="text-zinc-500 dark:text-zinc-400">
          Papers tagged{" "}
          <span className="text-zinc-700 dark:text-zinc-300">
            {error ? "" : `${matches.length} `}
          </span>
          with{" "}
          <code className="rounded bg-zinc-200/70 px-1.5 py-0.5 font-mono text-[0.8em] dark:bg-zinc-800/70">
            #{tag}
          </code>
          .
        </p>
      </header>

      {error ? (
        <section className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-900 dark:border-red-900/60 dark:bg-red-950/40 dark:text-red-200">
          <strong className="font-medium">Failed to load papers.</strong>
          <pre className="mt-2 whitespace-pre-wrap text-xs">{error}</pre>
        </section>
      ) : matches.length === 0 ? (
        <EmptyState>No papers tagged #{tag}.</EmptyState>
      ) : (
        <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
          {matches.map((paper) => {
            const excerpt = paperExcerpt(paper);
            const strength = tagStrength(paper.tags, tag);
            const rationale = paperTagEntries(paper.tags).find(
              (entry) => entry.tag === tag,
            )?.rationale;
            return (
              <li key={paper._id}>
                <Link
                  href={`/d/paper/${paperSlug(paper)}`}
                  className="group -mx-3 flex flex-col gap-1.5 rounded-lg px-3 py-5 transition-colors hover:bg-zinc-100 dark:hover:bg-zinc-900/60"
                >
                  <span className="flex items-center gap-2 text-lg font-medium tracking-tight">
                    {paperTitle(paper)}
                    {strength !== undefined ? (
                      <span
                        title={`Tag strength ${strength}/100 for #${tag}`}
                        className="inline-flex items-center gap-1 rounded-full bg-zinc-200/70 px-2 py-0.5 font-mono text-[0.7rem] font-normal text-zinc-600 dark:bg-zinc-800/70 dark:text-zinc-300"
                      >
                        <span
                          aria-hidden
                          className="inline-block h-1.5 w-1.5 rounded-full bg-emerald-500"
                          style={{ opacity: Math.max(0.25, strength / 100) }}
                        />
                        {strength}
                      </span>
                    ) : null}
                    <span
                      aria-hidden
                      className="translate-x-0 text-zinc-400 opacity-0 transition-all group-hover:translate-x-1 group-hover:opacity-100"
                    >
                      →
                    </span>
                  </span>
                  {rationale ? (
                    <span className="text-sm italic text-zinc-500 dark:text-zinc-400">
                      “{rationale}”
                    </span>
                  ) : null}
                  {excerpt ? (
                    <span className="line-clamp-2 text-sm text-zinc-600 dark:text-zinc-400">
                      {excerpt}
                    </span>
                  ) : null}
                  <span className="flex flex-wrap items-center gap-x-2 text-xs text-zinc-400">
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

export default async function TagPage({ params }: { params: Params }) {
  // The tag name is a plain word url-encoded in the href; decode it back.
  const { tag: rawTag } = await params;
  const tag = decodeURIComponent(rawTag);

  return (
    <Suspense fallback={<PostsListSkeleton />}>
      <TagListing tag={tag} />
    </Suspense>
  );
}
