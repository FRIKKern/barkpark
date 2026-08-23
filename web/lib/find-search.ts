import "server-only";
import {
  DOC_TYPES,
  type FindResponse,
  type SearchEngine,
} from "@/lib/find";
import { PUBLIC_API_URL, READ_TOKEN } from "@/lib/bp-env";
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

const API_URL = PUBLIC_API_URL;
const TOKEN = READ_TOKEN;
// DATASET is imported from lib/config (one source of truth, env-overridable).
// Default tenancy — a token unlocks the scoped route; the public flat route
// already serves anonymous retrieval.
const SCOPE = "/w/default/p/default";

/**
 * The API ORIGIN — scheme + host only, any path stripped. The managed deploy
 * path hands this app a PRE-SCOPED `BARKPARK_API_URL`
 * (`https://host/w/<ws>/p/<proj>`), while a local/self-managed `.env` sets a
 * bare origin. Concatenating `SCOPE` onto the raw URL double-scoped the managed
 * case (`…/w/x/p/y/w/x/p/y/v1/…` → 404 on first paint), so the search base is
 * composed from the ORIGIN + SCOPE exactly ONCE, below — correct for both
 * shapes of `BARKPARK_API_URL`.
 */
const ORIGIN = new URL(API_URL).origin;

/**
 * The one search base. Tokened requests MUST stay on the tenancy-scoped route
 * (the flat search route 403s public-read tokens — its PublicRead allowlist is
 * query/doc only); tokenless requests ride the flat anonymous route, which
 * serves both engines.
 */
const SEARCH_BASE = TOKEN ? `${ORIGIN}${SCOPE}` : ORIGIN;

/** Cap the working set; the client facets + sorts + paginates over it. */
const MAX_HITS = 100;

/**
 * Upstream column projection: everything `normalizeHit` actually reads —
 * scalar candidates for title/excerpt/date/slug/facets, PLUS `blocks`
 * (deriveTitle/Excerpt/Body all walk the block tree; dropping it kills the
 * contextual snippets). Meta keys (`_id`, `_type`, `_draft`, `_publishedId`,
 * `_createdAt`, `_updatedAt`) always ride along server-side. Cuts the browse
 * payload ~2.7MB→732KB on the demo corpus at the fastest server ms.
 */
const SEARCH_FIELDS = [
  "title",
  "name",
  "slug",
  "excerpt",
  "description",
  "bio",
  "body",
  "publishedAt",
  "status",
  "author",
  "category",
  "blocks",
].join(",");
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
/** Compose the upstream search URL for one engine — always over the module's
 * single `SEARCH_BASE` (origin + scope composed exactly once). */
function searchUrl(engineUsed: SearchEngine, q: string, browse: boolean): string {
  // Browse sends a single space: the q-required guard passes but it parses to an
  // empty query, which the engine treats as "enumerate + facet" the dataset.
  const params = new URLSearchParams({
    q: browse ? " " : q,
    engine: engineUsed,
    types: CONTENT_TYPES_CSV,
    perspective: "published",
    limit: String(MAX_HITS),
    fields: SEARCH_FIELDS,
  });
  return `${SEARCH_BASE}/v1/data/search/${DATASET}?${params.toString()}`;
}

export async function runSearch({
  q,
  engine,
  browse = false,
  sessionId = null,
}: RunSearchArgs): Promise<FindResponse> {
  // Record a real (non-browse) query event when we have a session to attribute
  // it to (the anti-gaming key for correction auto-promotion).
  const record = Boolean(sessionId) && !browse && Boolean(q);
  const signals: UpstreamSignals = { sessionId, record };

  const t0 = performance.now();
  try {
    const json = await rawUpstream(searchUrl(engine, q, browse), signals);
    return shapeFindResponse(json, {
      engine,
      // Fallback only — the upstream's server-reported `engineUsed` (which
      // retriever ACTUALLY answered) wins in the shaper.
      engineUsed: engine,
      browse,
      cache: false,
      upstreamMs: Math.round(performance.now() - t0),
    });
  } catch (err) {
    // Indx unavailable (unprovisioned instance, engine error) → ONE retry on
    // Postgres so the caller still gets real results. Only explicit
    // `engine=indx` requests enter this branch — the SSR seed and the default
    // browse ride DEFAULT_ENGINE and never do. The shaper derives `indxUnavailable: true` from
    // engine="indx" + engineUsed="postgres" — the honest-degrade signal the
    // Finder renders as a calm inline note. The retry never re-records the
    // query event (the first attempt already did, when recording was on).
    if (engine !== "indx") throw err;
    const json = await rawUpstream(searchUrl("postgres", q, browse), {
      sessionId,
      record: false,
    });
    return shapeFindResponse(json, {
      engine: "indx",
      engineUsed: "postgres",
      browse,
      cache: false,
      upstreamMs: Math.round(performance.now() - t0),
    });
  }
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
