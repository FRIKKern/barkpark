import { NextResponse } from "next/server";
import {
  DOC_TYPES,
  normalizeHit,
  type FindHit,
  type FindResponse,
  type ParsedQuery,
  type PopularQuery,
  type SearchEngine,
} from "@/lib/find";

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
): Promise<FindResponse> {
  const wantIndx = engine === "indx";
  // Indx only activates on the token-scoped route; without a token we cannot
  // reach it, so fall back to the public flat Postgres route and flag it.
  const useIndx = wantIndx && Boolean(TOKEN);
  const base = useIndx ? `${API_URL}${SCOPE}` : API_URL;
  const engineUsed: SearchEngine = useIndx ? "indx" : "postgres";

  const params = new URLSearchParams({
    q,
    engine: engineUsed,
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
    ms?: number;
  };
  const hits = (json.documents ?? [])
    .map(normalizeHit)
    .filter((h): h is FindHit => h !== null);

  return {
    mode: "search",
    hits,
    total: typeof json.count === "number" ? json.count : hits.length,
    engine,
    engineUsed,
    indxUnavailable: wantIndx && !useIndx,
    parsedQuery: json.parsedQuery ?? emptyParsed(),
    recovery: json.recovery ?? null,
    ms: typeof json.ms === "number" ? json.ms : null,
    error: null,
  };
}

/* ── browse (no q) ─────────────────────────────────────────────────────── */

async function browse(): Promise<FindResponse> {
  const perType = Math.ceil(MAX_HITS / DOC_TYPES.length);
  const settled = await Promise.all(
    DOC_TYPES.map(async (t) => {
      try {
        const res = await fetch(
          `${API_URL}/v1/data/query/${DATASET}/${t.type}?order=_updatedAt:desc&limit=${perType}`,
          { headers: authHeaders(), cache: "no-store" },
        );
        if (!res.ok) return [];
        const json = (await res.json()) as {
          documents?: unknown[];
          result?: { documents?: unknown[] };
        };
        return json.documents ?? json.result?.documents ?? [];
      } catch {
        return [];
      }
    }),
  );

  const hits = settled
    .flat()
    .map(normalizeHit)
    .filter((h): h is FindHit => h !== null)
    .sort((a, b) => (b.date ?? "").localeCompare(a.date ?? ""))
    .slice(0, MAX_HITS);

  return {
    mode: "browse",
    hits,
    total: hits.length,
    engine: "postgres",
    engineUsed: "postgres",
    indxUnavailable: false,
    parsedQuery: null,
    recovery: null,
    ms: null,
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
    const payload = q ? await search(q, engine) : await browse();
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
      ms: null,
      error: message,
    };
    return NextResponse.json(fallback, { status: 200 });
  }
}
