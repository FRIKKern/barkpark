/**
 * Single source of truth for the Barkpark dataset this demo reads from.
 *
 * The whole finder + reader + graph landing run on ONE dataset. It used to be
 * hard-coded as "production" in six places (find-search, get-document, the
 * barkpark client, bp-tags, and the find / find-event / admin-reindex routes);
 * now it lives here once and every module imports it.
 *
 *   BARKPARK_DATASET   — override at deploy time (defaults to "docs").
 *
 * Why a plain `.ts` constant and not `server-only`: the value is just a dataset
 * NAME (no secret), and a couple of importers are shared between server libs and
 * route handlers. The token + base URL still live behind `server-only` modules
 * (bp-fetch, barkpark-client) — only the dataset label is centralised here.
 *
 * NOTE for cache coherence: `lib/bp-tags.ts` derives its default revalidation
 * dataset from this same constant, so the webhook (which emits `dataset:"docs"`
 * for docs-dataset publishes) busts exactly the caches the finder/reader/graph
 * tagged their reads with. Keep the two in lock-step by importing — never by
 * re-declaring a second literal.
 */
export const DATASET = process.env.BARKPARK_DATASET || "docs";
