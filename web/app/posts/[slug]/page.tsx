import Link from "next/link";
import { notFound } from "next/navigation";
import { client } from "@/lib/barkpark-client";
import { fetchPostBySlug } from "@/lib/posts";

export const revalidate = 60;

/**
 * Flat post detail — `/posts/[slug]`. The flat counterpart to the scoped
 * `/w/[workspace]/p/[project]/posts/[slug]` route: same fetch, but via the
 * default flat-scope `client`. Linked from the home listing (`basePath="/posts"`).
 */
export default async function PostDetail({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;

  let error: string | null = null;
  let post = null;

  try {
    post = await fetchPostBySlug(client, slug);
  } catch (err) {
    error = err instanceof Error ? err.message : String(err);
  }

  if (!error && !post) notFound();

  return (
    <main className="mx-auto flex min-h-screen max-w-3xl flex-col gap-6 px-6 py-16 font-sans text-zinc-900 dark:text-zinc-50">
      <Link href="/" className="text-sm text-zinc-500 hover:underline">
        ← back to all posts
      </Link>

      {error ? (
        <section className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-900 dark:border-red-900 dark:bg-red-950/40 dark:text-red-200">
          <strong className="font-medium">Failed to load post.</strong>
          <pre className="mt-2 whitespace-pre-wrap text-xs">{error}</pre>
        </section>
      ) : post ? (
        <article className="flex flex-col gap-4">
          <h1 className="text-3xl font-semibold tracking-tight">
            {post.title ?? "(untitled)"}
          </h1>
          {post.excerpt ? (
            <p className="text-zinc-600 dark:text-zinc-400">{post.excerpt}</p>
          ) : null}
        </article>
      ) : null}
    </main>
  );
}
