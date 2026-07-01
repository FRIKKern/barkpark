import { NextResponse } from "next/server";
import type { PopularQuery, SearchEngine } from "@/lib/find";
import { emptyResponse, runSearch } from "@/lib/find-search";
import { API_URL, bpFetchJson } from "@/lib/bp-fetch";
import { DATASET } from "@/lib/config";

// Node runtime: reads the server-only BARKPARK_TOKEN (never bundled to the
// browser) and proxies same-origin so the client never sees the API host/token.
// NOT force-dynamic: the handler is dynamic anyway (reads searchParams). Search
// is always fresh — runSearch hits the engine directly, no cache.
export const runtime = "nodejs";

/* ── suggestions (popular / no-hit past queries) ───────────────────────── */

async function suggestions(): Promise<NextResponse> {
  try {
    // bpFetchJson bakes in auth + timeout and guards res.ok before parsing, so a
    // 5xx HTML page during an API restart no longer throws a cryptic
    // SyntaxError — it throws a structured error caught below.
    const json = (await bpFetchJson(
      `${API_URL}/v1/data/search/${DATASET}/suggestions?q=&limit=8`,
    )) as { result?: { popular?: PopularQuery[]; nohits?: PopularQuery[] } };
    return NextResponse.json({
      popular: json.result?.popular ?? [],
      nohits: json.result?.nohits ?? [],
    });
  } catch {
    // Empty suggestions is a harmless degrade — keep the existing default.
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
  // Browser session id (localStorage `bp-search-client`) — forwarded upstream as
  // X-BP-SEARCH-CLIENT so the recorded query event is attributed to a session.
  const sid = searchParams.get("sid");

  try {
    // Browse (no query) is a single-space search: both engines treat it as
    // "enumerate + facet" the dataset, so the landing gets facets either way.
    const payload = q
      ? await runSearch({ q, engine, browse: false, sessionId: sid })
      : await runSearch({ q: " ", engine, browse: true, sessionId: sid });
    return NextResponse.json(payload);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return NextResponse.json(emptyResponse(engine, q, message), {
      status: 200,
    });
  }
}
