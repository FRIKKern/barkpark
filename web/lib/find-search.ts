import "server-only";
import { unstable_cache } from "next/cache";
import {
  DOC_TYPES,
  normalizeHit,
  type FacetMap,
  type FindHit,
  type FindResponse,
  type ParsedQuery,
  type SearchEngine,
} from "@/lib/find";

/**
 * Shared upstream search — the one place that talks to the Barkpark search API.
 * Imported by both the `/api/find` route handler (client-driven searches) and
 * the home page (server-rendered initial browse), so the two never drift.
 *
 * WHY a hand-rolled `unstable_cache` instead of per-fetch `next: { revalidate }`:
 * the Phoenix API answers with `Cache-Control: max-age=0, private,
 * must-revalidate`, which Next's PER-FETCH Data Cache honours — so a
 * `fetch(url, { next: { revalidate } })` is never stored and "cache mode" was a
 * silent no-op (every request paid the full round-trip). `unstable_cache`
 * caches the FUNCTION'S RETURN VALUE and ignores the upstream Cache-Control,
 * so warm hits actually skip the origin (~0–5ms vs ~280ms). Same mechanism the
 * reader pages (getPost/getPaper) already use successfully.
 */

/** Cache tag for the find Data Cache — `revalidateTag(FIND_TAG)` busts it. */
export const FIND_TAG = "find";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:4000";
const TOKEN = process.env.BARKPARK_READ_TOKEN;
const DATASET = "production";
// Default tenancy — Indx only activates on the token-scoped route.
const SCOPE = "/w/default/p/default";
/** Cap the working set; the client facets + sorts + paginates over it. */
const MAX_HITS = 100;
/** The finder is a CONTENT browser: scope to known content types via the API's
 * `types` allowlist so both engines stay consistent and private config schemas
 * (siteSettings, navigation, …) never leak into browse + facet counts. */
const CONTENT_TYPES_CSV = DOC_TYPES.map((t) => t.type).join(",");

function authHeaders(): HeadersInit {
  return TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {};
}

function emptyParsed(): ParsedQuery {
  return { terms: [], phrases: [], excludes: [], prefixes: [] };
}

interface UpstreamJson {
  documents?: unknown[];
  count?: number;
  parsedQuery?: ParsedQuery;
  recovery?: string | null;
  facets?: FacetMap | null;
  truncation?: { index: number } | null;
  ms?: number;
}

/** Raw upstream call — always no-store; caching is layered above by
 * `cachedUpstream` so the Data Cache stores the parsed payload, not the HTTP
 * response (which the origin marks private/uncacheable). */
async function rawUpstream(url: string): Promise<UpstreamJson> {
  const res = await fetch(url, { headers: authHeaders(), cache: "no-store" });
  if (!res.ok) throw new Error(`search ${res.status}: ${await res.text()}`);
  return (await res.json()) as UpstreamJson;
}

/** Cached variant — keyed on the full URL, 5-min revalidate, tagged for
 * on-demand busting. Ignores the origin's Cache-Control (the whole point). */
const cachedUpstream = unstable_cache(rawUpstream, ["find-upstream"], {
  revalidate: 300,
  tags: [FIND_TAG],
});

export interface RunSearchArgs {
  q: string;
  engine: SearchEngine;
  browse?: boolean;
  cacheOn?: boolean;
}

/**
 * Run one search and shape it into a `FindResponse`. Times the upstream call so
 * a warm cache hit (~0–5ms) is visible in the latency readout. Throws on a hard
 * upstream failure — callers decide how to degrade (the route returns a
 * 200-with-error envelope; the page falls back to a client fetch).
 */
export async function runSearch({
  q,
  engine,
  browse = false,
  cacheOn = false,
}: RunSearchArgs): Promise<FindResponse> {
  const wantIndx = engine === "indx";
  // Indx only activates on the token-scoped route; without a token, fall back
  // to the public flat Postgres route and flag it.
  const useIndx = wantIndx && Boolean(TOKEN);
  const base = useIndx ? `${API_URL}${SCOPE}` : API_URL;
  const engineUsed: SearchEngine = useIndx ? "indx" : "postgres";

  // Browse sends a single space: the q-required guard passes but it parses to an
  // empty query, which Indx treats as "enumerate + facet" the dataset.
  const params = new URLSearchParams({
    q: browse ? " " : q,
    engine: engineUsed,
    types: CONTENT_TYPES_CSV,
    perspective: "published",
    limit: String(MAX_HITS),
  });
  const url = `${base}/v1/data/search/${DATASET}?${params.toString()}`;

  const t0 = performance.now();
  const json = cacheOn ? await cachedUpstream(url) : await rawUpstream(url);
  const upstreamMs = Math.round(performance.now() - t0);

  const hits = (json.documents ?? [])
    .map(normalizeHit)
    .filter((h): h is FindHit => h !== null);

  return {
    mode: browse ? "browse" : "search",
    hits,
    total: typeof json.count === "number" ? json.count : hits.length,
    engine,
    engineUsed,
    indxUnavailable: wantIndx && !useIndx,
    parsedQuery: browse ? null : (json.parsedQuery ?? emptyParsed()),
    recovery: json.recovery ?? null,
    facets: json.facets ?? null,
    truncation: json.truncation ?? null,
    ms: typeof json.ms === "number" ? json.ms : null,
    cache: cacheOn,
    upstreamMs,
    error: null,
  };
}

/** Empty/error envelope so callers can return a stable shape without throwing. */
export function emptyResponse(
  engine: SearchEngine,
  q: string,
  cacheOn: boolean,
  error: string | null = null,
): FindResponse {
  return {
    mode: q ? "search" : "browse",
    hits: [],
    total: 0,
    engine,
    engineUsed: engine,
    indxUnavailable: false,
    parsedQuery: q ? emptyParsed() : null,
    recovery: null,
    facets: null,
    truncation: null,
    ms: null,
    cache: cacheOn,
    upstreamMs: null,
    error,
  };
}
