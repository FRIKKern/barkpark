import { NextResponse } from "next/server";
import { DEFAULT_ENGINE, type PopularQuery, type SearchEngine } from "@/lib/find";
import { emptyResponse, runSearch } from "@/lib/find-search";
import { API_URL, bpFetchJson } from "@/lib/bp-fetch";
import { DATASET } from "@/lib/config";

// Node runtime: reads the server-only BARKPARK_TOKEN (never bundled to the
// browser) and proxies same-origin so the client never sees the API host/token.
// NOT force-dynamic: the handler is dynamic anyway (reads searchParams). Search
// is always fresh — runSearch hits the engine directly, no cache.
export const runtime = "nodejs";

/* ── suggestions (popular / no-hit past queries) ───────────────────────── */

/**
 * What `?suggest=1` answers with. `error` is the field the two empty lists
 * descend from: `null` when the upstream actually answered (the corpus really
 * has no popular or no-hit queries yet), and the upstream's own reason when it
 * did not. Without it, "nobody has searched yet" and "the suggestions endpoint
 * is down" are the same bytes — which is exactly what the search path below
 * already refuses to do at :56-60.
 */
interface SuggestionsResponse {
  popular: PopularQuery[];
  nohits: PopularQuery[];
  error: string | null;
}

async function suggestions(): Promise<NextResponse> {
  try {
    // bpFetchJson bakes in auth + timeout and guards res.ok before parsing, so a
    // 5xx HTML page during an API restart no longer throws a cryptic
    // SyntaxError — it throws a structured error caught below.
    const json = (await bpFetchJson(
      `${API_URL}/v1/data/search/${DATASET}/suggestions?q=&limit=8`,
    )) as { result?: { popular?: PopularQuery[]; nohits?: PopularQuery[] } };
    const answered: SuggestionsResponse = {
      popular: json.result?.popular ?? [],
      nohits: json.result?.nohits ?? [],
      error: null,
    };
    return NextResponse.json(answered);
  } catch (err) {
    // An empty suggestion list is a harmless degrade for the UI — the finder
    // simply shows no popular queries — but it must not be reported as one the
    // upstream sent. The message descends from the failure, the same way the
    // search path's does at :56-60; the status line deliberately stays 200 so a
    // caller reading `res.ok` never sees this optional panel as a page failure.
    console.error("find suggestions upstream error:", err);
    const message = err instanceof Error ? err.message : String(err);
    const degraded: SuggestionsResponse = {
      popular: [],
      nohits: [],
      error: message,
    };
    return NextResponse.json(degraded, { status: 200 });
  }
}

/* ── handler ───────────────────────────────────────────────────────────── */

export async function GET(request: Request): Promise<NextResponse> {
  const { searchParams } = new URL(request.url);

  if (searchParams.get("suggest") === "1") return suggestions();

  const q = (searchParams.get("q") ?? "").trim();
  // Same unbiased reader as the Finder: explicit `engine=indx` opts in, anything
  // else resolves to the ONE shared default.
  const engine: SearchEngine =
    searchParams.get("engine") === "indx" ? "indx" : DEFAULT_ENGINE;
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
