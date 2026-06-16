import "server-only";
import { cache } from "react";
import { unstable_cache } from "next/cache";
import { client } from "./barkpark-client";
import { fetchPaperBySlug, type PaperDocument } from "./papers";
import { bpAll, bpType } from "./bp-tags";

export interface PaperResult {
  paper: PaperDocument | null;
  error: string | null;
}

// Data Cache layer (enables ISR on the reader): cache the published lookup per
// slug for 5 min, tagged for on-demand invalidation. Errors throw out of the
// cached fn, so transient failures are never cached.
const cachedPaper = unstable_cache(
  (slug: string) => fetchPaperBySlug(client, slug),
  ["paper-by-slug"],
  // 300s safety net; the webhook (revalidateTag bp:ds:<dataset>:type:paper)
  // is the real freshness path on publish.
  { revalidate: 300, tags: ["doc", "doc:paper", bpAll(), bpType("paper")] },
);

/**
 * Request-deduped single-paper fetch — `generateMetadata` and the page share
 * one round-trip (React `cache()`), over a 5-min Data Cache (`unstable_cache`).
 * Flat scope only (papers are a public reader surface).
 */
export const getPaper = cache(async (slug: string): Promise<PaperResult> => {
  try {
    return { paper: await cachedPaper(slug), error: null };
  } catch (err) {
    return {
      paper: null,
      error: err instanceof Error ? err.message : String(err),
    };
  }
});
