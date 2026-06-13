import type { BarkparkClient, BarkparkDocument } from "@barkpark/core";

export interface PostDocument extends BarkparkDocument {
  title?: string;
  slug?: string;
  excerpt?: string;
  /** Body copy. Plain string in the demo dataset; richer types use `content.body`. */
  body?: string;
  author?: string;
  /** Author-supplied publish date (free-form in the demo data); falls back to `_updatedAt`. */
  publishedAt?: string;
  category?: string;
  featured?: string | boolean;
  content?: { slug?: string; body?: unknown };
}

/** Stable slug resolution shared by listing + detail. */
export function postSlug(post: PostDocument): string {
  return post.slug ?? post.content?.slug ?? post._publishedId ?? post._id;
}

/** Listing query — works for any scope, since the client carries the scope. */
export async function fetchPosts(
  client: BarkparkClient,
): Promise<PostDocument[]> {
  return client
    .docs<PostDocument>("post")
    .order("_updatedAt:desc")
    .limit(50)
    .find();
}

/** Single post by slug (or id), scope-aware via the supplied client. */
export async function fetchPostBySlug(
  client: BarkparkClient,
  slug: string,
): Promise<PostDocument | null> {
  const bySlug = await client
    .docs<PostDocument>("post")
    .where("slug", "eq", slug)
    .findOne();
  if (bySlug) return bySlug;
  // Fall back to treating the param as a publishedId / _id. The query API does
  // not expose `_id` as a filterable field, so use the by-id doc endpoint
  // (`client.doc`) which fetches `/v1/data/doc/<dataset>/<type>/<id>` directly
  // and returns null on 404.
  return client.doc<PostDocument>("post", slug);
}
