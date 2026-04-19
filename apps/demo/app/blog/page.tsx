import Link from "next/link";
import { barkparkFetch, DEFAULT_REVALIDATE } from "@/lib/revalidate";
import type { BarkparkDoc } from "@/lib/barkpark";

export const revalidate = 60;

type PostDoc = BarkparkDoc & {
  title?: string;
  author?: string;
  content?: { excerpt?: string; body?: string; [key: string]: unknown };
};

type QueryResult = {
  count: number;
  documents: PostDoc[];
};

function excerptOf(doc: PostDoc): string {
  const c = doc.content;
  if (c && typeof c === "object") {
    if (typeof c.excerpt === "string" && c.excerpt.trim()) return c.excerpt;
    if (typeof c.body === "string" && c.body.trim()) {
      const trimmed = c.body.trim();
      return trimmed.length > 200 ? `${trimmed.slice(0, 200)}…` : trimmed;
    }
  }
  return "";
}

export default async function BlogIndexPage() {
  let posts: PostDoc[] = [];
  let errored = false;

  try {
    const result = await barkparkFetch<QueryResult>(
      "/v1/data/query/production/post",
    );
    posts = (result.documents ?? []).slice().sort((a, b) => {
      const ad = a._updatedAt ?? a._createdAt ?? "";
      const bd = b._updatedAt ?? b._createdAt ?? "";
      return bd.localeCompare(ad);
    });
  } catch {
    errored = true;
  }

  return (
    <section>
      <h1 style={{ marginBottom: "0.25rem" }}>Blog</h1>
      <p style={{ color: "#666", marginBottom: "2rem", fontSize: "0.95rem" }}>
        Posts are served from the live Barkpark API with ISR (revalidate every{" "}
        {DEFAULT_REVALIDATE}s).
      </p>

      {errored && (
        <p style={{ color: "#b00", marginBottom: "1.5rem" }}>
          Could not load posts right now. Please try again shortly.
        </p>
      )}

      {!errored && posts.length === 0 && (
        <p style={{ color: "#666" }}>No published posts yet.</p>
      )}

      <ul style={{ listStyle: "none", padding: 0, margin: 0 }}>
        {posts.map((post) => {
          const title =
            typeof post.title === "string" && post.title.trim()
              ? post.title
              : post._id;
          const excerpt = excerptOf(post);
          return (
            <li
              key={post._id}
              style={{
                borderBottom: "1px solid #eee",
                padding: "1.25rem 0",
              }}
            >
              <h2 style={{ margin: "0 0 0.35rem", fontSize: "1.2rem" }}>
                <Link
                  href={`/blog/${encodeURIComponent(post._id)}`}
                  style={{ color: "#0366d6", textDecoration: "none" }}
                >
                  {title}
                </Link>
              </h2>
              {excerpt && (
                <p style={{ margin: "0.25rem 0", color: "#333" }}>{excerpt}</p>
              )}
              <p
                style={{
                  margin: "0.5rem 0 0",
                  color: "#888",
                  fontSize: "0.85rem",
                }}
              >
                {post.author ? `${post.author} · ` : ""}
                {post._updatedAt ?? post._createdAt ?? ""}
              </p>
            </li>
          );
        })}
      </ul>
    </section>
  );
}
