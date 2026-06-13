import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getPost } from "@/lib/get-post";
import { PostArticle } from "@/components/post-article";

export const revalidate = 60;

/**
 * Flat post detail — `/posts/[slug]`. The flat counterpart to the scoped
 * `/w/[workspace]/p/[project]/posts/[slug]` route: same fetch, but via the
 * default flat-scope client. Linked from the home listing (`basePath="/posts"`).
 */

type Params = Promise<{ slug: string }>;

export async function generateMetadata({
  params,
}: {
  params: Params;
}): Promise<Metadata> {
  const { slug } = await params;
  const { post, error } = await getPost(slug);
  // Trigger 404 here (metadata resolves before the response status is committed)
  // so a missing post yields a real HTTP 404 — not a 200 from the page throwing
  // notFound() after headers are already sent.
  if (!post && !error) notFound();
  if (!post) return { title: "Post unavailable · Barkpark" };
  const description = post.excerpt ?? undefined;
  return {
    title: `${post.title ?? "(untitled)"} · Barkpark`,
    description,
    openGraph: {
      title: post.title ?? undefined,
      description,
      type: "article",
    },
  };
}

export default async function PostDetail({ params }: { params: Params }) {
  const { slug } = await params;
  const { post, error } = await getPost(slug);

  if (!error && !post) notFound();

  return (
    <PostArticle
      post={post}
      error={error}
      backHref="/"
      backLabel="back to all posts"
    />
  );
}
