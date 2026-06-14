import { NextResponse } from "next/server";
import type { PopularQuery, SearchEngine } from "@/lib/find";
import { emptyResponse, runSearch } from "@/lib/find-search";

// Node runtime: reads the server-only BARKPARK_READ_TOKEN (never bundled to the
// browser) and proxies same-origin so the client never sees the API host/token.
// NOT force-dynamic: the handler is dynamic anyway (reads searchParams), but the
// search caching lives in `runSearch`'s `unstable_cache`, not a route directive.
export const runtime = "nodejs";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:4000";
const TOKEN = process.env.BARKPARK_READ_TOKEN;
const DATASET = "production";

function authHeaders(): HeadersInit {
  return TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {};
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

/* ── handler ───────────────────────────────────────────────────────────── */

export async function GET(request: Request): Promise<NextResponse> {
  const { searchParams } = new URL(request.url);

  if (searchParams.get("suggest") === "1") return suggestions();

  const q = (searchParams.get("q") ?? "").trim();
  const engine: SearchEngine =
    searchParams.get("engine") === "indx" ? "indx" : "postgres";
  const cacheOn = searchParams.get("cache") === "on";

  try {
    // Browse (no query) is a single-space search: both engines treat it as
    // "enumerate + facet" the dataset, so the landing gets facets either way.
    const payload = q
      ? await runSearch({ q, engine, browse: false, cacheOn })
      : await runSearch({ q: " ", engine, browse: true, cacheOn });
    return NextResponse.json(payload);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return NextResponse.json(emptyResponse(engine, q, cacheOn, message), {
      status: 200,
    });
  }
}
