import "server-only";
import { cache } from "react";
import { unstable_cache } from "next/cache";
import { client } from "./barkpark-client";
import { bpAll, bpType } from "./bp-tags";

/**
 * The raw document, type-agnostic. Every reader (post / paper / sheet / meta)
 * branches off `_type` and reads whatever extra fields it needs off the index
 * signature — there is one canonical fetch, not one per type.
 */
export interface GenericDoc {
  _id: string;
  _type: string;
  _updatedAt?: string;
  _createdAt?: string;
  title?: string;
  slug?: string;
  [k: string]: unknown;
}

export interface DocResult {
  doc: GenericDoc | null;
  error: string | null;
}

/**
 * Two-step fetch shared by every type: try the slug filter first, then fall
 * back to the by-id doc endpoint. Sheets carry no `slug`, so the id fallback
 * (`client.doc(type, slug)` → `/v1/data/doc/<dataset>/<type>/<id>`) is what
 * resolves them when the slug param is really an id. Mirrors
 * `fetchPostBySlug` / `fetchPaperBySlug`, generalised across `_type`.
 */
async function fetchByTypeSlug(
  type: string,
  slug: string,
): Promise<GenericDoc | null> {
  const bySlug = await client
    .docs<GenericDoc>(type)
    .where("slug", "eq", slug)
    .findOne();
  if (bySlug) return bySlug;
  // The query API doesn't expose `_id` as a filterable field; the by-id doc
  // endpoint fetches it directly and returns null on 404.
  return client.doc<GenericDoc>(type, slug);
}

// Data Cache layer (enables ISR on the detail pane): keyed on type + slug,
// 5-min revalidate, tagged for invalidation. The cache key embeds `type` (via
// the keyParts segment AND the inner-fn args) so post/paper/sheet caches never
// collide on a shared slug.
//
// 300s is a SAFETY NET, not the freshness mechanism: a publish in Studio fires
// the webhook → revalidateTag(bp:ds:<dataset>:type:<type>) → instant bust.
// (Tag granularity is per-type, not per-slug — the slug→id map isn't known at
// cache-wrap time.)
const cachedDoc = (type: string) =>
  unstable_cache((slug: string) => fetchByTypeSlug(type, slug), [
    "doc-by-type-slug",
    type,
  ], {
    revalidate: 300,
    tags: ["doc", `doc:${type}`, bpAll(), bpType(type)],
  });

/**
 * Request-deduped single-document fetch by `(type, slug)`.
 *
 * The detail page component and the slot's metadata both need the doc; wrapping
 * the fetch in React's `cache()` (keyed on the primitive args — type + slug)
 * means they share ONE round-trip per request instead of fetching twice.
 *
 * Error handling lives here too, so callers stay declarative: they branch on
 * `{ doc, error }` rather than each wrapping their own try/catch. Mirrors
 * `getPost` exactly.
 */
export const getDocument = cache(
  async (type: string, slug: string): Promise<DocResult> => {
    try {
      return { doc: await cachedDoc(type)(slug), error: null };
    } catch (err) {
      return {
        doc: null,
        error: err instanceof Error ? err.message : String(err),
      };
    }
  },
);
