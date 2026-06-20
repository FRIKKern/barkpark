import Link from "next/link";
import type { PostDocument } from "@/lib/posts";

/**
 * Normalize a post body into paragraph strings. The demo `docs` dataset ships
 * `body` as a plain string (split on blank lines); richer datasets (e.g.
 * `production`) ship a structured `{ blocks, html }` PortableDoc — there we pull
 * the text out of each block. Anything unrecognized yields `[]` (→ "no body").
 */
function bodyParagraphs(body: unknown): string[] {
  if (typeof body === "string") {
    return body.split(/\n{2,}/).filter((p) => p.trim().length > 0);
  }
  if (body && typeof body === "object" && Array.isArray((body as { blocks?: unknown }).blocks)) {
    const blocks = (body as { blocks: unknown[] }).blocks;
    return blocks
      .map((b) => {
        const block = b as { text?: unknown; content?: unknown };
        if (typeof block.text === "string") return block.text;
        if (Array.isArray(block.content)) {
          return block.content
            .map((c) => (c && typeof (c as { value?: unknown }).value === "string" ? (c as { value: string }).value : ""))
            .join("");
        }
        return "";
      })
      .filter((p) => p.trim().length > 0);
  }
  return [];
}

interface PostArticleProps {
  post: PostDocument | null;
  error: string | null;
  /** Where the "back" link points (home for flat, the project for scoped). */
  backHref?: string;
  backLabel?: string;
  /**
   * Rendered inside the master/detail pane rather than as a standalone page.
   * Drops the `min-h-screen` `<main>` chrome and the back-link — the detail
   * pane owns its own scroll container and a `<DetailChrome>` close affordance —
   * and emits just the `<article>` (or the error panel) so it sits flush in the
   * pane. The standalone path (no `embedded`) is byte-identical to before.
   */
  embedded?: boolean;
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
      // timeZone:"UTC" → deterministic server/client text (no React #418).
      label: new Intl.DateTimeFormat("en-US", {
        timeZone: "UTC",
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
  embedded,
}: PostArticleProps) {
  const published = resolveDate(post?.publishedAt, post?._updatedAt);

  // The error panel / article body is identical for both surfaces; only the
  // outer chrome (page `<main>` + back-link, vs. nothing) differs.
  const inner = (
    <>
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

          {bodyParagraphs(post.body).length > 0 ? (
            <div className="flex flex-col gap-4 text-base leading-7 text-zinc-700 dark:text-zinc-300">
              {bodyParagraphs(post.body).map((para, i) => (
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
    </>
  );

  // Embedded in the master/detail pane: no page chrome, no back-link — the
  // detail pane owns the scroll container and a close affordance.
  if (embedded) {
    return inner;
  }

  return (
    <main className="mx-auto flex min-h-screen w-full max-w-2xl flex-col gap-8 px-6 py-16">
      <Link
        href={backHref ?? "/"}
        className="text-sm text-zinc-500 transition-colors hover:text-zinc-900 dark:hover:text-zinc-200"
      >
        ← {backLabel ?? "back"}
      </Link>

      {inner}
    </main>
  );
}
