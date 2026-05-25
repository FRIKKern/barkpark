import { notFound } from "next/navigation";
import { createClient } from "@/lib/barkpark-client";
import { fetchPostBySlug } from "@/lib/posts";

export const revalidate = 60;

/**
 * Scoped post detail. Same scoping path as the listing — params build a
 * per-request scoped client, then fetch the single post within that scope.
 */
export default async function ScopedPostDetail({
  params,
}: {
  params: Promise<{ workspace: string; project: string; slug: string }>;
}) {
  const { workspace, project, slug } = await params;
  const client = createClient({ workspace, project });

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
      <a
        href={`/w/${workspace}/p/${project}`}
        className="text-sm text-zinc-500 hover:underline"
      >
        ← back to w/{workspace} · p/{project}
      </a>

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
