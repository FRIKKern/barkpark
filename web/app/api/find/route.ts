import { NextResponse } from "next/server";
import {
  DOC_TYPES,
  normalizeHit,
  type FacetMap,
  type FindHit,
  type FindResponse,
  type ParsedQuery,
  type PopularQuery,
  type SearchEngine,
} from "@/lib/find";

// The finder is a CONTENT browser: scope every search to the known content
// types via the API's `types` allowlist. The backend filters results, count,
// AND facets to this set, so both engines are consistent (Indx indexes only
// these; Postgres would otherwise also surface private config schemas —
// siteSettings, navigation, colors, … — in browse + facet counts).
const CONTENT_TYPES_CSV = DOC_TYPES.map((t) => t.type).join(",");

// Node runtime: reads the server-only BARKPARK_READ_TOKEN (never bundled to the
// browser) and proxies same-origin so the client never sees the API host/token.
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:4000";
const TOKEN = process.env.BARKPARK_READ_TOKEN;
const DATASET = "production";
// Default tenancy — the flat route pins to these; the scoped route (the only
// one that truly engages Indx) addresses them explicitly.
const SCOPE = "/w/default/p/default";

/** Cap the working set we pull back; the client facets + paginates over it.
 * The demo dataset is small, so one round-trip beats N facet-count queries. */
const MAX_HITS = 100;

function authHeaders(): HeadersInit {
  return TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {};
}

function emptyParsed(): ParsedQuery {
  return { terms: [], phrases: [], excludes: [], prefixes: [] };
}

/* ── suggestions (popular / no-hit past queries) ───────────────────────── */

async function suggestions(): Promise<NextResponse> {
  try {
    const res = await fetch(
      `${API_URL}/v1/data/search/${DATASET}/suggestions?q=&limit=8`,
      { headers: authHeaders(), cache: "no-store" },
    );
    const json = (await res.json()) as {
      result?: { popular?: PopularQuery[]; nohits?: PopularQuery[] };
    };
    return NextResponse.json({
      popular: json.result?.popular ?? [],
      nohits: json.result?.nohits ?? [],
    });
  } catch {
    return NextResponse.json({ popular: [], nohits: [] });
  }
}

/* ── search (q present) ────────────────────────────────────────────────── */

async function search(
  q: string,
  engine: SearchEngine,
  browse = false,
): Promise<FindResponse> {
  const wantIndx = engine === "indx";
  // Indx only activates on the token-scoped route; without a token we cannot
  // reach it, so fall back to the public flat Postgres route and flag it.
  const useIndx = wantIndx && Boolean(TOKEN);
  const base = useIndx ? `${API_URL}${SCOPE}` : API_URL;
  const engineUsed: SearchEngine = useIndx ? "indx" : "postgres";

  // Browse mode sends a single space: the q-required guard passes, but it parses
  // to an empty query, which Indx treats as "enumerate + facet" the dataset.
  const params = new URLSearchParams({
    q: browse ? " " : q,
    engine: engineUsed,
    types: CONTENT_TYPES_CSV,
    perspective: "published",
    limit: String(MAX_HITS),
  });

  const res = await fetch(
    `${base}/v1/data/search/${DATASET}?${params.toString()}`,
    { headers: authHeaders(), cache: "no-store" },
  );
  if (!res.ok) {
    throw new Error(`search ${res.status}: ${await res.text()}`);
  }
  const json = (await res.json()) as {
    documents?: unknown[];
    count?: number;
    parsedQuery?: ParsedQuery;
    recovery?: string | null;
    facets?: FacetMap | null;
    truncation?: { index: number } | null;
    ms?: number;
  };
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
    error: null,
  };
}

/* ── handler ───────────────────────────────────────────────────────────── */

export async function GET(request: Request): Promise<NextResponse> {
  const { searchParams } = new URL(request.url);

  if (searchParams.get("suggest") === "1") return suggestions();

  const q = (searchParams.get("q") ?? "").trim();
  const engine: SearchEngine =
    searchParams.get("engine") === "indx" ? "indx" : "postgres";

  try {
    // Browse (no query) is a single-space search: both engines treat it as
    // "enumerate + facet" the dataset, so the landing gets facets either way.
    const payload = q ? await search(q, engine) : await search(" ", engine, true);
    return NextResponse.json(payload);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    const fallback: FindResponse = {
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
      error: message,
    };
    return NextResponse.json(fallback, { status: 200 });
  }
}
