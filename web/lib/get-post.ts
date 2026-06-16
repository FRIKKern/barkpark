import "server-only";
import { cache } from "react";
import { unstable_cache } from "next/cache";
import { client, createClient } from "./barkpark-client";
import { fetchPostBySlug, type PostDocument } from "./posts";
import { bpAll, bpType } from "./bp-tags";

export interface PostResult {
  post: PostDocument | null;
  error: string | null;
}

// Data Cache layer (enables ISR on the reader): keyed on slug + scope strings,
// 5-min revalidate, tagged for invalidation. Empty scope strings = flat client.
const cachedPost = unstable_cache(
  (slug: string, workspace: string, project: string) =>
    fetchPostBySlug(
      workspace && project ? createClient({ workspace, project }) : client,
      slug,
    ),
  ["post-by-slug"],
  // 300s is now a SAFETY NET, not the freshness mechanism: a publish in Studio
  // fires the webhook → revalidateTag(bp:ds:<dataset>:type:post) → instant
  // bust. (Tag granularity is per-type, not per-slug — coarse but correct: the
  // slug→id map isn't known at cache-wrap time.)
  { revalidate: 300, tags: ["doc", "doc:post", bpAll(), bpType("post")] },
);

/**
 * Request-deduped single-post fetch.
 *
 * `generateMetadata` and the page component both need the post; wrapping the
 * fetch in React's `cache()` (keyed on the primitive args — slug + scope) means
 * they share ONE round-trip per request instead of fetching twice. Build the
 * client inside so the cache key stays primitive (passing the client object
 * would defeat memoisation — new instance per render → cache miss).
 *
 * Error handling lives here too, so pages stay declarative: they branch on
 * `{ post, error }` rather than each wrapping their own try/catch.
 */
export const getPost = cache(
  async (
    slug: string,
    workspace?: string,
    project?: string,
  ): Promise<PostResult> => {
    try {
      return {
        post: await cachedPost(slug, workspace ?? "", project ?? ""),
        error: null,
      };
    } catch (err) {
      return {
        post: null,
        error: err instanceof Error ? err.message : String(err),
      };
    }
  },
);
