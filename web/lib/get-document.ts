import "server-only";
import { cache } from "react";
import { unstable_cache } from "next/cache";
import { client } from "./barkpark-client";
import { bpAll, bpType } from "./bp-tags";
import { resolveDocOutcome } from "./doc-absence";
import { docReadOptions } from "./doc-read-options";

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
/**
 * EXPORTED FOR TESTS. `getDocument` wraps this in `unstable_cache`, which
 * throws `Invariant: incrementalCache missing` outside a Next request scope —
 * so the cached entry point cannot be driven under `node --test`, and the
 * per-type read shaping below would only be checkable by reading this file.
 * A grep is not a live probe; this export is what lets one run.
 */
export async function fetchByTypeSlug(
  type: string,
  slug: string,
): Promise<GenericDoc | null> {
  // Per-type read shaping — today, `?resolve=tasks` for papers, so query-shaped
  // task blocks arrive with live rows instead of empty. Both legs get it: a
  // paper resolved by the id fallback must not render a different document from
  // the same paper resolved by slug. See `./doc-read-options.ts`.
  const opts = docReadOptions(type);
  const bySlug = await client
    .docs<GenericDoc>(type, opts)
    .where("slug", "eq", slug)
    .findOne();
  if (bySlug) return bySlug;
  // The query API doesn't expose `_id` as a filterable field; the by-id doc
  // endpoint fetches it directly and returns null on 404.
  return client.doc<GenericDoc>(type, slug, opts);
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
 *
 * The two absent-doc shapes are kept DISTINCT (they render differently):
 *   { doc: null, error: null }   → absent, honestly     → the page 404s
 *   { doc: null, error: "…" }    → the reader must see it → inline error panel
 *
 * The FIRST bucket is the SUCCESS path, not a catch: `.findOne()` resolved null
 * and the by-id fallback resolved null too (core maps the by-id 404 to null
 * itself). The slug-query leg REJECTS with `BarkparkNotFoundError` when the
 * TYPE is unknown or private to this token (a decided asymmetry —
 * `js/packages/core/src/docs.ts`, wave-7 D72), and because the route gates on
 * its own hard-coded `KNOWN_TYPES` set that can only mean THIS SITE'S config is
 * wrong — so it lands in the SECOND bucket with a message naming the type.
 * The ruling and its full reasoning live in `./doc-absence.ts`.
 */
export const getDocument = cache(
  async (type: string, slug: string): Promise<DocResult> =>
    resolveDocOutcome<GenericDoc>(type, () => cachedDoc(type)(slug)),
);
