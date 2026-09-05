/**
 * The ONE flat corpus-graph URL — `GET /v1/graph?dataset=…` — built from the
 * BARE ORIGIN of whatever `BARKPARK_API_URL` this app was handed.
 *
 * WHY THIS FILE EXISTS: `lib/graph.ts` pulls in `server-only`, `next/cache` and
 * `@/` path aliases, so `node --test` cannot load it — the same constraint that
 * produced `lib/graph-truncation.ts` and `lib/paginate.ts`. The URL law ships
 * and is tested as ONE artifact under bare `node --test`.
 *
 * WHY THE ORIGIN, NOT THE RAW BASE: the corpus endpoint is mounted FLAT
 * (`/v1/graph`, `[:api, :require_token]`) — tenancy comes from the bearer's
 * default scope, not a `/w/:ws/p/:proj` path prefix (the scoped path 404s). The
 * managed deploy path injects a SCOPED `BARKPARK_API_URL`
 * (`<origin>/w/:ws/p/:proj`), which is correct for every CONTENT read and wrong
 * for this one flat call. `templates/search-starter/lib/graph.ts` carries the
 * live-caught incident behind it: the scoped+flat concatenation 404'd, the
 * corpus came back empty, and the HEALTH gate honestly refused the deploy
 * (empty bp-doc-id). PR #3842 fixed the two template trees and never reached
 * `web/`.
 *
 * LATENT, NOT LIVE for `web/` today: `lib/bp-env.ts` resolves the base from
 * `NEXT_PUBLIC_BARKPARK_API_URL` / `NEXT_PUBLIC_API_URL` with a bare
 * `DEFAULT_API_URL`, and every environment web ships to sets a bare origin — so
 * the concatenation and the derivation agree there. This module makes the
 * invariant `lib/graph.ts`'s header ASSERTS ("ONE flat URL shape, always") hold
 * for BOTH base shapes instead of resting on an env convention nothing checks.
 * The failure mode it forecloses is an EMPTY GRAPH, not an error.
 */

/**
 * `{origin}/v1/graph?dataset=…` — any path on `apiUrl` (a managed deploy's
 * `/w/:ws/p/:proj` scope prefix) is stripped. Throws `TypeError` on a base that
 * is not an absolute URL, exactly as the template's `new URL(API_URL)` does.
 */
export function corpusGraphUrl(apiUrl: string, dataset: string): string {
  const origin = new URL(apiUrl).origin;
  return `${origin}/v1/graph?dataset=${encodeURIComponent(dataset)}`;
}
