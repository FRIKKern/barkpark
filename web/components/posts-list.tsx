import Link from "next/link";
import type { PostDocument } from "@/lib/posts";
import { postSlug } from "@/lib/posts";

/** Format an ISO date as a short label; null when unparseable. */
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

interface PostsListProps {
  posts: PostDocument[];
  error: string | null;
  /** Base href for a post link, e.g. "/posts" or "/w/acme/p/blog/posts". */
  basePath: string;
  /** Optional sub-heading describing the active scope. */
  scopeLabel?: string;
}

/** Shared listing view for both flat and scoped routes. */
export function PostsList({
  posts,
  error,
  basePath,
  scopeLabel,
}: PostsListProps) {
  return (
    <main className="mx-auto flex min-h-screen max-w-3xl flex-col gap-8 px-6 py-16 font-sans text-zinc-900 dark:text-zinc-50">
      <header className="flex flex-col gap-2">
        <h1 className="text-3xl font-semibold tracking-tight">Barkpark</h1>
        <p className="text-zinc-600 dark:text-zinc-400">
          Headless CMS demo — published posts from the{" "}
          <code>production</code> dataset.
          {scopeLabel ? (
            <>
              {" "}
              <span className="text-zinc-500">({scopeLabel})</span>
            </>
          ) : null}
        </p>
      </header>

      {error ? (
        <section className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-900 dark:border-red-900 dark:bg-red-950/40 dark:text-red-200">
          <strong className="font-medium">Failed to load posts.</strong>
          <pre className="mt-2 whitespace-pre-wrap text-xs">{error}</pre>
        </section>
      ) : posts.length === 0 ? (
        <p className="text-zinc-500">No published posts yet.</p>
      ) : (
        <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
          {posts.map((post) => {
            const date = shortDate(post.publishedAt) ?? shortDate(post._updatedAt);
            return (
              <li key={post._id} className="group py-5">
                <Link
                  href={`${basePath}/${postSlug(post)}`}
                  className="flex flex-col gap-1.5"
                >
                  <span className="text-lg font-medium tracking-tight group-hover:underline">
                    {post.title ?? "(untitled)"}
                  </span>
                  {post.excerpt ? (
                    <span className="line-clamp-2 text-sm text-zinc-600 dark:text-zinc-400">
                      {post.excerpt}
                    </span>
                  ) : null}
                  <span className="flex flex-wrap items-center gap-x-2 text-xs text-zinc-400">
                    {date ? <span>{date}</span> : null}
                    {date ? <span aria-hidden>·</span> : null}
                    <span className="font-mono">/{postSlug(post)}</span>
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
