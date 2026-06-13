import "server-only";
import { cache } from "react";
import { client, createClient } from "./barkpark-client";
import { fetchPostBySlug, type PostDocument } from "./posts";

export interface PostResult {
  post: PostDocument | null;
  error: string | null;
}

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
    const c =
      workspace && project ? createClient({ workspace, project }) : client;
    try {
      return { post: await fetchPostBySlug(c, slug), error: null };
    } catch (err) {
      return {
        post: null,
        error: err instanceof Error ? err.message : String(err),
      };
    }
  },
);
