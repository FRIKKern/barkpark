import { Suspense } from "react";
import Link from "next/link";
import { client } from "@/lib/barkpark-client";
import {
  paperSlug,
  paperTitle,
  paperExcerpt,
  type PaperDocument,
} from "@/lib/papers";
import { PostsListSkeleton } from "@/components/posts-list";

export const dynamic = "force-dynamic";

// Clone of /app/papers/page.tsx's container so the tag listing speaks the same
// visual language as the rest of the reader.
const shell =
  "mx-auto flex min-h-screen w-full max-w-2xl flex-col gap-8 px-6 py-16";

type Params = Promise<{ tag: string }>;

/**
 * Tags live at `content["tags"]` (a string array). The rendered envelope
 * (`Envelope.render`) spreads `content` to the top level, so they surface as the
 * declared `PaperDocument.tags` field. We still guard the runtime shape (the
 * projection could omit or malform it) and keep only string entries.
 */
function paperTags(paper: PaperDocument): string[] {
  return Array.isArray(paper.tags)
    ? paper.tags.filter((t): t is string => typeof t === "string")
    : [];
}

async function TagListing({ tag }: { tag: string }) {
  let papers: PaperDocument[] = [];
  let error: string | null = null;

  try {
    // The generic query endpoint does scalar equality, not JSONB array
    // containment, so there's no server-side `tags includes ?` filter to lean
    // on. We fetch the corpus and filter CLIENT/SERVER-side in this RSC —
    // scale-bounded but fine at this app's size (~94 papers). A server-side
    // JSONB-containment endpoint (`content->'tags' @> to_jsonb(?)`, which the
    // Phoenix layer already has as `docs_with_tag`) is the future optimization.
    papers = await client
      .docs<PaperDocument>("paper")
      .order("_updatedAt:desc")
      .limit(200)
      .find();
  } catch (err) {
    error = err instanceof Error ? err.message : String(err);
  }

  const matches = papers.filter((paper) => paperTags(paper).includes(tag));

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
        <p className="text-zinc-500">No papers tagged #{tag}.</p>
      ) : (
        <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
          {matches.map((paper) => {
            const excerpt = paperExcerpt(paper);
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
