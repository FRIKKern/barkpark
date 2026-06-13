import "server-only";
import { cache } from "react";
import { client } from "./barkpark-client";
import { fetchPaperBySlug, type PaperDocument } from "./papers";

export interface PaperResult {
  paper: PaperDocument | null;
  error: string | null;
}

/**
 * Request-deduped single-paper fetch — `generateMetadata` and the page share
 * one round-trip. Mirrors `getPost`; flat scope only (papers are a public
 * reader surface).
 */
export const getPaper = cache(async (slug: string): Promise<PaperResult> => {
  try {
    return { paper: await fetchPaperBySlug(client, slug), error: null };
  } catch (err) {
    return {
      paper: null,
      error: err instanceof Error ? err.message : String(err),
    };
  }
});
