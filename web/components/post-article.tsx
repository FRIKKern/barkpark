import Link from "next/link";
import type { PostDocument } from "@/lib/posts";

interface PostArticleProps {
  post: PostDocument | null;
  error: string | null;
  /** Where the "back" link points (home for flat, the project for scoped). */
  backHref: string;
  backLabel: string;
}

/**
 * Resolve a displayable date from the first parseable candidate. Returns both
 * the formatted label and the ISO string that produced it, so the `<time>`
 * `dateTime` attr is always valid (never the raw free-form source, which may be
 * garbage like "WAZZAPPP").
 */
function resolveDate(
  ...candidates: (string | undefined)[]
): { label: string; iso: string } | null {
  for (const value of candidates) {
    if (!value) continue;
    const d = new Date(value);
    if (Number.isNaN(d.getTime())) continue;
    return {
      label: new Intl.DateTimeFormat("en-US", {
        year: "numeric",
        month: "long",
        day: "numeric",
      }).format(d),
      iso: d.toISOString(),
    };
  }
  return null;
}

/** Shared post-detail view for both the flat and scoped routes. */
export function PostArticle({
  post,
  error,
  backHref,
  backLabel,
}: PostArticleProps) {
  const published = resolveDate(post?.publishedAt, post?._updatedAt);

  return (
    <main className="mx-auto flex min-h-screen w-full max-w-2xl flex-col gap-8 px-6 py-16">
      <Link
        href={backHref}
        className="text-sm text-zinc-500 transition-colors hover:text-zinc-900 dark:hover:text-zinc-200"
      >
        ← {backLabel}
      </Link>

      {error ? (
        <section className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-900 dark:border-red-900/60 dark:bg-red-950/40 dark:text-red-200">
          <strong className="font-medium">Failed to load post.</strong>
          <pre className="mt-2 whitespace-pre-wrap text-xs">{error}</pre>
        </section>
      ) : post ? (
        <article className="flex flex-col gap-6">
          <header className="flex flex-col gap-3 border-b border-zinc-200 pb-6 dark:border-zinc-800">
            <h1 className="text-4xl font-semibold tracking-tight text-balance">
              {post.title ?? "(untitled)"}
            </h1>
            {(post.author || published) && (
              <p className="flex flex-wrap items-center gap-x-2 text-sm text-zinc-500">
                {post.author ? <span>{post.author}</span> : null}
                {post.author && published ? <span aria-hidden>·</span> : null}
                {published ? (
                  <time dateTime={published.iso}>{published.label}</time>
                ) : null}
              </p>
            )}
          </header>

          {post.excerpt ? (
            <p className="text-lg leading-relaxed text-zinc-600 dark:text-zinc-300">
              {post.excerpt}
            </p>
          ) : null}

          {post.body ? (
            <div className="flex flex-col gap-4 text-base leading-7 text-zinc-700 dark:text-zinc-300">
              {post.body.split(/\n{2,}/).map((para, i) => (
                <p key={i} className="whitespace-pre-wrap">
                  {para}
                </p>
              ))}
            </div>
          ) : !post.excerpt ? (
            <p className="text-sm text-zinc-400 italic">
              This post has no body content.
            </p>
          ) : null}
        </article>
      ) : null}
    </main>
  );
}
