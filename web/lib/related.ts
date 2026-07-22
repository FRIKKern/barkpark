import "server-only";
import { unstable_cache } from "next/cache";
import { DATASET } from "@/lib/config";
import { bpAll } from "@/lib/bp-tags";
import { PUBLIC_API_URL } from "@/lib/bp-env";
import { bpFetchJson, BpUpstreamError, humanUpstreamMessage } from "@/lib/bp-fetch";
import { normalizeRelated, type RelatedEntry } from "@/lib/related-shape";

/**
 * The reader's Related section — the one place that talks to Barkpark's
 * related-documents endpoint (`GET /v1/data/related/:dataset/:id`). Mirrors
 * `lib/graph.ts` EXACTLY: `server-only` + a hand-rolled `unstable_cache`
 * (Phoenix marks responses `private, max-age=0`, so per-fetch `revalidate` is a
 * silent no-op), 5-min revalidate, tagged so a publish anywhere in the dataset
 * busts it via the existing webhook.
 *
 * The tag/backlink fusion is done server-side over the published-only edge
 * table and the tags_meta column — it genuinely cannot be recomputed in the
 * browser — so this is a Server-Component-only read. The pure normaliser lives
 * in `lib/related-shape.ts` (next-free, so `node --test` can drive it).
 */

/** Cache tag for the related Data Cache — `revalidateTag(RELATED_TAG)` busts it. */
export const RELATED_TAG = "related";

const API_URL = PUBLIC_API_URL;

/** Re-export so consumers share the resolved dataset + the entry shapes. */
export { DATASET };
export type { RelatedEntry, SharedTag, RelatedSource } from "@/lib/related-shape";
export { isBacklinkOnly, creditedStrength } from "@/lib/related-shape";

/** Raw, uncached upstream call. Caching is layered above by `cachedRelated`. */
async function rawRelated(id: string, dataset: string): Promise<RelatedEntry[]> {
  // The related endpoint is mounted FLAT (`/v1/data/related/:dataset/:id`,
  // [:api, :api_grant_read]) — tenancy comes from the bearer's default scope,
  // exactly like lib/graph.ts's use of the flat `/v1/graph` (the `/w/p/` scoped
  // mirror 404s when the token already scopes). Token/preview-only upstream:
  // an anonymous read 404s, which degrades to "no related" in `fetchRelated`.
  const url = `${API_URL}/v1/data/related/${encodeURIComponent(dataset)}/${encodeURIComponent(id)}`;

  let json: unknown;
  try {
    json = await bpFetchJson(url);
  } catch (e) {
    if (e instanceof BpUpstreamError) {
      throw new Error(`related ${e.status}: ${humanUpstreamMessage(e)}`);
    }
    throw e;
  }

  return normalizeRelated(json);
}

// `id` + `dataset` are folded into the Data Cache key by `unstable_cache` (it
// hashes the wrapped fn's args), so distinct documents never share an entry.
const cachedRelated = unstable_cache(rawRelated, ["related", DATASET], {
  revalidate: 300,
  tags: [RELATED_TAG, bpAll()],
});

/**
 * Related documents for `id` (a slug or doc id) within `dataset`, best first.
 * Never throws — an empty list is a first-class, common answer (the ~35%
 * untagged corpus, an anonymous/token-less deploy that 404s, or a transient
 * upstream error), and the Related section renders NOTHING for it.
 */
export async function fetchRelated(
  id: string,
  dataset: string = DATASET,
): Promise<RelatedEntry[]> {
  try {
    return await cachedRelated(id, dataset);
  } catch {
    return [];
  }
}
