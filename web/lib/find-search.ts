import "server-only";
import {
  DOC_TYPES,
  type FindResponse,
  type SearchEngine,
} from "@/lib/find";
import {
  emptyParsed,
  shapeFindResponse,
  type UpstreamSearchJson,
} from "@/lib/find-shape";
import { bpFetchJson, BpUpstreamError, humanUpstreamMessage } from "@/lib/bp-fetch";
import { DATASET } from "@/lib/config";

/**
 * Shared upstream search — the one place that talks to the Barkpark search API.
 * Imported by both the `/api/find` route handler (client-driven searches) and
 * the home page (server-rendered initial browse), so the two never drift.
 *
 * Search is ALWAYS fresh: every call goes straight to Postgres/Indx (no-store),
 * no Data Cache layer. The engine is the single source of truth and is fast
 * enough (direct WebSocket + keep-alive pool + batch hydration) that caching
 * search results would only risk serving stale ones. Page-level ISR for the
 * reader pages (getPost/getPaper) is unaffected — that's standard and lives
 * elsewhere.
 */

/** Legacy cache tag, retained because a few revalidation routes still import it
 * (webhook / reindex / reset). Search no longer caches, so `revalidateTag(FIND_TAG)`
 * is now a harmless no-op — kept only to avoid churning those call sites. */
export const FIND_TAG = "find";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:4000";
const TOKEN = process.env.BARKPARK_READ_TOKEN;
// DATASET is imported from lib/config (one source of truth, env-overridable).
// Default tenancy — a token unlocks the scoped route; the public flat route
// already serves Indx (typo-tolerant) retrieval anonymously.
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

/** Per-search signals the route handler threads to the upstream so a search can
 * be recorded against the browser's distinct session. `sessionId` becomes the
 * `X-BP-SEARCH-CLIENT` header; presence of either flag flips on the record
 * header so the API logs the query event (returning its `searchEventId`). */
interface UpstreamSignals {
  sessionId?: string | null;
  record?: boolean;
}

function searchHeaders(signals: UpstreamSignals): HeadersInit {
  const h: Record<string, string> = { ...(authHeaders() as Record<string, string>) };
  if (signals.sessionId) h["X-BP-SEARCH-CLIENT"] = signals.sessionId;
  if (signals.record) h["X-BP-SEARCH-RECORD"] = "1";
  return h;
}

/** Upstream call — always no-store, straight to the engine. */
async function rawUpstream(url: string, signals: UpstreamSignals = {}): Promise<UpstreamSearchJson> {
  // bpFetchJson layers the shared resilience (15s timeout, retry over the
  // API-restart window, res.ok guard, defensive JSON parse) and bakes in auth;
  // searchHeaders adds the per-search X-BP-SEARCH-* signals on top (caller
  // headers win over the injected bearer). Re-wrap into a `search …` message so
  // the route's error envelope keeps the same human-facing prefix.
  try {
    return (await bpFetchJson(url, { headers: searchHeaders(signals) })) as UpstreamSearchJson;
  } catch (e) {
    if (e instanceof BpUpstreamError) {
      throw new Error(`search ${e.status}: ${humanUpstreamMessage(e)}`);
    }
    throw e;
  }
}

export interface RunSearchArgs {
  q: string;
  engine: SearchEngine;
  browse?: boolean;
  /** Browser session id (localStorage `bp-search-client`) — forwarded as
   * `X-BP-SEARCH-CLIENT` so the recorded query event is attributed to a
   * distinct session (the anti-gaming key for correction auto-promotion). */
  sessionId?: string | null;
}

/**
 * Run one search and shape it into a `FindResponse`. Times the upstream call so
 * the engine latency is visible in the readout. Throws on a hard upstream
 * failure — callers decide how to degrade (the route returns a 200-with-error
 * envelope; the page falls back to a client fetch).
 */
export async function runSearch({
  q,
  engine,
  browse = false,
  sessionId = null,
}: RunSearchArgs): Promise<FindResponse> {
  const wantIndx = engine === "indx";
  // Indx (typo-tolerant retrieval) runs on the public flat route anonymously, so
  // honour the requested engine even without a token; a token additionally
  // unlocks the tenancy-scoped route. Postgres always uses the flat route.
  const useIndx = wantIndx;
  const base = useIndx && TOKEN ? `${API_URL}${SCOPE}` : API_URL;
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

  // Record a real (non-browse) query event when we have a session to attribute
  // it to (the anti-gaming key for correction auto-promotion).
  const record = Boolean(sessionId) && !browse && Boolean(q);
  const signals: UpstreamSignals = { sessionId, record };

  const t0 = performance.now();
  const json = await rawUpstream(url, signals);
  const upstreamMs = Math.round(performance.now() - t0);

  return shapeFindResponse(json, {
    engine,
    engineUsed,
    browse,
    cache: false,
    upstreamMs,
  });
}

/** Empty/error envelope so callers can return a stable shape without throwing. */
export function emptyResponse(
  engine: SearchEngine,
  q: string,
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
    cache: false,
    upstreamMs: null,
    searchEventId: null,
    correctedTo: null,
    error,
  };
}
