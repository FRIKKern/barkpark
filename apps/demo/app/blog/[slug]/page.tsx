import Link from "next/link";
import { notFound } from "next/navigation";
import { barkparkFetch } from "@/lib/revalidate";
import { BarkparkFetchError, type BarkparkDoc } from "@/lib/barkpark";

export const revalidate = 60;
export const dynamicParams = true;

type PostDoc = BarkparkDoc & {
  title?: string;
  author?: string;
  content?: { body?: string; excerpt?: string; [key: string]: unknown };
};

type PageProps = {
  params: Promise<{ slug: string }>;
};

async function loadPost(slug: string): Promise<PostDoc | null> {
  const id = decodeURIComponent(slug);
  try {
    return await barkparkFetch<PostDoc>(
      `/v1/data/doc/production/post/${encodeURIComponent(id)}`,
    );
  } catch (err) {
    if (err instanceof BarkparkFetchError && err.status === 404) return null;
    throw err;
  }
}

export async function generateMetadata({ params }: PageProps) {
  const { slug } = await params;
  const post = await loadPost(slug).catch(() => null);
  if (!post) return { title: "Post not found — Barkpark" };
  const title = typeof post.title === "string" && post.title.trim() ? post.title : post._id;
  return { title: `${title} — Barkpark blog` };
}

export default async function BlogPostPage({ params }: PageProps) {
  const { slug } = await params;
  const post = await loadPost(slug);
  if (!post) notFound();

  const title =
    typeof post.title === "string" && post.title.trim() ? post.title : post._id;
  const body =
    post.content && typeof post.content === "object" && typeof post.content.body === "string"
      ? post.content.body
      : null;
  const date = post._updatedAt ?? post._createdAt ?? null;

  return (
    <article>
      <p style={{ margin: "0 0 1rem", fontSize: "0.9rem" }}>
        <Link href="/blog" style={{ color: "#0366d6", textDecoration: "none" }}>
          ← Back to blog
        </Link>
      </p>

      <h1 style={{ margin: "0 0 0.5rem" }}>{title}</h1>

      <p
        style={{
          color: "#888",
          fontSize: "0.9rem",
          margin: "0 0 1.5rem",
        }}
      >
        {post.author ? `${post.author} · ` : ""}
        {date ?? ""}
      </p>

      {body ? (
        <div style={{ lineHeight: 1.7, whiteSpace: "pre-wrap" }}>{body}</div>
      ) : (
        <p style={{ color: "#666", fontStyle: "italic" }}>
          (No body content for this post yet.)
        </p>
      )}
    </article>
  );
}
