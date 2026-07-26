import {
  normalizeHit,
  type FacetMap,
  type FindHit,
  type FindResponse,
  type ParsedQuery,
  type SearchEngine,
} from "./find.ts";

/**
 * Pure `upstream JSON → FindResponse` mapping — NO server-only deps, so it runs
 * in both the Node route handler (`find-search.ts`) and the browser
 * (`use-live-search.ts`). Extracting it is what lets the WebSocket path render
 * byte-identically to the HTTP path: the Phoenix `SearchChannel` reply is
 * deliberately shaped to this same `UpstreamSearchJson`, so both transports feed
 * the exact same shaper and the finder can't tell them apart.
 */

export interface UpstreamSearchJson {
  documents?: unknown[];
  count?: number;
  parsedQuery?: ParsedQuery;
  recovery?: string | null;
  facets?: FacetMap | null;
  truncation?: { index: number } | null;
  ms?: number;
  searchEventId?: string;
  correctedTo?: string | null;
  /** Which retriever ACTUALLY served, reported by the query pipeline — the
   * server truth `engineUsed` is set from. "postgres" even when indx was
   * requested but silently substituted (zero-hit recovery, no live dataset). */
  engineUsed?: string | null;
}

export function emptyParsed(): ParsedQuery {
  return { terms: [], phrases: [], excludes: [], prefixes: [] };
}

export interface ShapeArgs {
  /** The engine the caller ASKED for (drives `indxUnavailable`). */
  engine: SearchEngine;
  /** Transport-level fallback for the served engine, used ONLY when the
   * upstream did not report `engineUsed` (an older API). The server value in
   * the payload always wins — the client guessing "what actually served" has
   * shipped dead code twice; the pipeline is the only place that knows. */
  engineUsed: SearchEngine;
  browse: boolean;
  cache: boolean;
  /** Round-trip the caller measured, when the upstream didn't report `ms`. */
  upstreamMs: number | null;
}

/** Assemble a `FindResponse` from a raw upstream/channel payload. */
export function shapeFindResponse(
  json: UpstreamSearchJson,
  { engine, engineUsed, browse, cache, upstreamMs }: ShapeArgs,
): FindResponse {
  const hits = (json.documents ?? [])
    .map(normalizeHit)
    .filter((h): h is FindHit => h !== null);

  // SERVER TRUTH: prefer the pipeline-reported engine over the caller's echo,
  // so `indxUnavailable` below is reachable — an indx request the server
  // silently answered on Postgres (zero-hit recovery) now says so.
  const served: SearchEngine =
    json.engineUsed === "indx"
      ? "indx"
      : json.engineUsed === "postgres"
        ? "postgres"
        : engineUsed;

  return {
    mode: browse ? "browse" : "search",
    hits,
    total: typeof json.count === "number" ? json.count : hits.length,
    engine,
    engineUsed: served,
    indxUnavailable: engine === "indx" && served !== "indx",
    parsedQuery: browse ? null : (json.parsedQuery ?? emptyParsed()),
    recovery: json.recovery ?? null,
    facets: json.facets ?? null,
    truncation: json.truncation ?? null,
    ms: typeof json.ms === "number" ? json.ms : null,
    cache,
    upstreamMs,
    searchEventId:
      typeof json.searchEventId === "string" ? json.searchEventId : null,
    correctedTo: typeof json.correctedTo === "string" ? json.correctedTo : null,
    error: null,
  };
}
