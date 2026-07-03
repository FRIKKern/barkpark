import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getPost } from "@/lib/get-post";
import { PostArticle } from "@/components/post-article";

export const revalidate = 60;

/**
 * Scoped post detail. Same scoping path as the listing — params select the
 * `/w/<ws>/p/<project>` scope, then fetch the single post within it.
 */

type Params = Promise<{ workspace: string; project: string; slug: string }>;

export async function generateMetadata({
  params,
}: {
  params: Params;
}): Promise<Metadata> {
  const { workspace, project, slug } = await params;
  const { post, error } = await getPost(slug, workspace, project);
  // Trigger 404 here (metadata resolves before the response status is committed)
  // so a missing post yields a real HTTP 404 — not a 200 from the page throwing
  // notFound() after headers are already sent.
  if (!post && !error) notFound();
  if (!post) return { title: "Post unavailable · Barkpark" };
  const title = post.title ?? "(untitled)";
  const description = post.excerpt ?? undefined;
  const url = `/w/${encodeURIComponent(workspace)}/p/${encodeURIComponent(
    project,
  )}/posts/${encodeURIComponent(slug)}`;
  return {
    title: `${title} · Barkpark`,
    description,
    openGraph: {
      title: post.title ?? undefined,
      description,
      type: "article",
      url,
    },
    twitter: {
      card: "summary",
      title,
      description,
    },
  };
}

export default async function ScopedPostDetail({
  params,
}: {
  params: Params;
}) {
  const { workspace, project, slug } = await params;
  const { post, error } = await getPost(slug, workspace, project);

  if (!error && !post) notFound();

  return (
    <PostArticle
      post={post}
      error={error}
      backHref={`/w/${workspace}/p/${project}`}
      backLabel={`back to w/${workspace} · p/${project}`}
    />
  );
}
