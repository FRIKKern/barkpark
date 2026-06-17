import {
  normalizeHit,
  type FacetMap,
  type FindHit,
  type FindResponse,
  type ParsedQuery,
  type SearchEngine,
} from "@/lib/find";

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
}

export function emptyParsed(): ParsedQuery {
  return { terms: [], phrases: [], excludes: [], prefixes: [] };
}

export interface ShapeArgs {
  /** The engine the caller ASKED for (drives `indxUnavailable`). */
  engine: SearchEngine;
  /** The engine actually served (may downgrade indx→postgres on no token). */
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

  return {
    mode: browse ? "browse" : "search",
    hits,
    total: typeof json.count === "number" ? json.count : hits.length,
    engine,
    engineUsed,
    indxUnavailable: engine === "indx" && engineUsed !== "indx",
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
