import Link from "next/link";
import type { PostDocument } from "@/lib/posts";
import { postSlug } from "@/lib/posts";

interface PostsListProps {
  posts: PostDocument[];
  error: string | null;
  /** Base href for a post link, e.g. "/posts" or "/w/acme/p/blog/posts". */
  basePath: string;
  /** Optional sub-heading describing the active scope. */
  scopeLabel?: string;
}

/** Format an ISO date as a short label; null when unparseable. */
function shortDate(value?: string): string | null {
  if (!value) return null;
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return null;
  // timeZone:"UTC" → deterministic server/client text (no React #418).
  return new Intl.DateTimeFormat("en-US", {
    timeZone: "UTC",
    year: "numeric",
    month: "short",
    day: "numeric",
  }).format(d);
}

/** Page header — wordmark + a one-line description of what's listed. */
function ListHeader({
  count,
  scopeLabel,
}: {
  count?: number;
  scopeLabel?: string;
}) {
  return (
    <header className="flex flex-col gap-3 border-b border-zinc-200 pb-8 dark:border-zinc-800">
      <h1 className="text-4xl font-semibold tracking-tight">Barkpark</h1>
      <p className="text-zinc-500 dark:text-zinc-400">
        Headless CMS demo —{" "}
        {typeof count === "number" ? (
          <span className="text-zinc-700 dark:text-zinc-300">
            {count} published {count === 1 ? "post" : "posts"}
          </span>
        ) : (
          "published posts"
        )}{" "}
        from the{" "}
        <code className="rounded bg-zinc-200/70 px-1.5 py-0.5 font-mono text-[0.8em] dark:bg-zinc-800/70">
          production
        </code>{" "}
        dataset.
        {scopeLabel ? (
          <span className="block pt-1 font-mono text-sm text-zinc-400">
            {scopeLabel}
          </span>
        ) : null}
      </p>
      <nav className="flex flex-wrap gap-x-5 gap-y-1 text-sm">
        <Link
          href="/find"
          className="font-medium text-zinc-700 transition-colors hover:text-zinc-950 dark:text-zinc-300 dark:hover:text-zinc-50"
        >
          Find anything →
        </Link>
        <Link
          href="/papers"
          className="text-zinc-500 transition-colors hover:text-zinc-900 dark:hover:text-zinc-200"
        >
          Browse Papers (Portable Docs) →
        </Link>
      </nav>
    </header>
  );
}

const shell =
  "mx-auto flex min-h-screen w-full max-w-2xl flex-col gap-8 px-6 py-16";

/** Shared listing view for both flat and scoped routes. */
export function PostsList({
  posts,
  error,
  basePath,
  scopeLabel,
}: PostsListProps) {
  return (
    <main className={shell}>
      <ListHeader count={error ? undefined : posts.length} scopeLabel={scopeLabel} />

      {error ? (
        <section className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-900 dark:border-red-900/60 dark:bg-red-950/40 dark:text-red-200">
          <strong className="font-medium">Failed to load posts.</strong>
          <pre className="mt-2 whitespace-pre-wrap text-xs">{error}</pre>
        </section>
      ) : posts.length === 0 ? (
        <p className="text-zinc-500">No published posts yet.</p>
      ) : (
        <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
          {posts.map((post) => {
            const date =
              shortDate(post.publishedAt) ?? shortDate(post._updatedAt);
            return (
              <li key={post._id}>
                <Link
                  href={`${basePath}/${postSlug(post)}`}
                  className="group -mx-3 flex flex-col gap-1.5 rounded-lg px-3 py-5 transition-colors hover:bg-zinc-100 dark:hover:bg-zinc-900/60"
                >
                  <span className="flex items-center gap-2 text-lg font-medium tracking-tight">
                    {post.title ?? "(untitled)"}
                    <span
                      aria-hidden
                      className="translate-x-0 text-zinc-400 opacity-0 transition-all group-hover:translate-x-1 group-hover:opacity-100"
                    >
                      →
                    </span>
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

/** Suspense fallback mirroring the listing layout — header + placeholder rows. */
export function PostsListSkeleton() {
  return (
    <main className={shell}>
      <div className="flex flex-col gap-3 border-b border-zinc-200 pb-8 dark:border-zinc-800">
        <div className="h-9 w-40 animate-pulse rounded-md bg-zinc-200 dark:bg-zinc-800" />
        <div className="h-4 w-80 max-w-full animate-pulse rounded bg-zinc-100 dark:bg-zinc-900" />
      </div>
      <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
        {Array.from({ length: 6 }).map((_, i) => (
          <li key={i} className="flex flex-col gap-2 py-5">
            <div className="h-5 w-2/3 animate-pulse rounded bg-zinc-200 dark:bg-zinc-800" />
            <div className="h-3 w-full animate-pulse rounded bg-zinc-100 dark:bg-zinc-900" />
            <div className="h-3 w-24 animate-pulse rounded bg-zinc-100 dark:bg-zinc-900" />
          </li>
        ))}
      </ul>
    </main>
  );
}
