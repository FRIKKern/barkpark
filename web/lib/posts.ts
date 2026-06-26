import {
  typedClient,
  type BarkparkClient,
  type BarkparkDocument,
} from "@barkpark/core";
import type { Post, BarkparkTypeMap } from "./barkpark.types";

/**
 * The shape of a `post` document as this demo reader consumes it.
 *
 * Base is the generated {@link Post} interface (emitted by `barkpark generate`
 * from the production schema — the single source of truth for `title`, `slug`,
 * `featuredImage`, `body`). The old hand-written `PostDocument` interface that
 * duplicated those fields (and would drift) is DELETED; this alias derives from
 * the generated type instead.
 *
 * Two deltas keep the Next.js demo building against the live `production` data
 * without hand-maintaining the schema:
 *  - `_publishedId` + the other system fields come from {@link BarkparkDocument}
 *    (the open envelope core returns), which the generated `BarkparkSystemFields`
 *    deliberately omits.
 *  - `slug`/`body` are WIDENED: the demo dataset ships `slug` as a plain string
 *    and `body` as a string (or a PortableDoc object), whereas the production
 *    schema types them `BarkparkSlug` / `unknown`. The consumers (`postSlug`,
 *    `bodyParagraphs`) already handle both runtime shapes.
 *  - `excerpt`/`author`/`publishedAt`/`category`/`featured`/`content` are
 *    demo-only presentation fields not present in the production schema.
 */
export type PostDocument = Omit<Post, "slug" | "body"> &
  BarkparkDocument & {
    slug?: string;
    /** Body copy. Plain string in the demo dataset; richer types use `content.body`. */
    body?: unknown;
    excerpt?: string;
    author?: string;
    /** Author-supplied publish date (free-form in the demo data); falls back to `_updatedAt`. */
    publishedAt?: string;
    category?: string;
    featured?: string | boolean;
    content?: { slug?: string; body?: unknown };
  };

/** Stable slug resolution shared by listing + detail. */
export function postSlug(post: PostDocument): string {
  return post.slug ?? post.content?.slug ?? post._publishedId ?? post._id;
}

/** Listing query — works for any scope, since the client carries the scope. */
export async function fetchPosts(
  client: BarkparkClient,
): Promise<PostDocument[]> {
  // `typedClient<BarkparkTypeMap>` narrows `docs("post")` to the generated
  // `Post`; cast to the demo's wider `PostDocument` view at the boundary.
  return typedClient<BarkparkTypeMap>(client)
    .docs("post")
    .order("_updatedAt:desc")
    .limit(50)
    .find() as Promise<PostDocument[]>;
}

/** Single post by slug (or id), scope-aware via the supplied client. */
export async function fetchPostBySlug(
  client: BarkparkClient,
  slug: string,
): Promise<PostDocument | null> {
  const bp = typedClient<BarkparkTypeMap>(client);
  const bySlug = (await bp
    .docs("post")
    .where("slug", "eq", slug)
    .findOne()) as PostDocument | null;
  if (bySlug) return bySlug;
  // Fall back to treating the param as a publishedId / _id. The query API does
  // not expose `_id` as a filterable field, so use the by-id doc endpoint
  // (`client.doc`) which fetches `/v1/data/doc/<dataset>/<type>/<id>` directly
  // and returns null on 404.
  return bp.doc("post", slug) as Promise<PostDocument | null>;
}
