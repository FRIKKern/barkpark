import { NextResponse } from "next/server";
import { revalidateTag } from "next/cache";
import { FIND_TAG } from "@/lib/find-search";
import {
  API_URL,
  bpFetchJson,
  BpUpstreamError,
  humanUpstreamMessage,
  isTransient,
} from "@/lib/bp-fetch";
import { DATASET } from "@/lib/config";
import { READ_TOKEN } from "@/lib/bp-env";

// Trigger an Indx blue/green rebuild via the token-gated Barkpark endpoint
// (uses the server-only read token — never bundled). The rebuild runs async on
// the API node (~30s); we purge the find cache so cached results refresh once
// the new dataset swaps in.
export const runtime = "nodejs";

const TOKEN = READ_TOKEN;
// DATASET imported from lib/config (one source of truth, env-overridable).
// Mirrors the finder's content types (lib/find.ts DOC_TYPES) so Indx indexes
// everything the finder can browse — including sheets, so /d/sheet/:slug docs
// are findable on the Indx engine (not just Postgres).
const TYPES = "post,page,author,category,project,paper,sheet";

export async function POST(): Promise<NextResponse> {
  if (!TOKEN) {
    return NextResponse.json(
      { ok: false, error: "reindex needs BARKPARK_TOKEN" },
      { status: 503 },
    );
  }
  try {
    // bpFetchJson guards res.ok BEFORE consuming the body and parses defensively
    // (text → JSON.parse), so an empty/HTML body during an API restart surfaces
    // as a structured BpUpstreamError instead of "Unexpected end of JSON input".
    // It also retries the API-restart window (network / 502 / 503 / 504).
    const body = await bpFetchJson(
      `${API_URL}/v1/data/search/${DATASET}/reindex?types=${TYPES}`,
      { method: "POST", headers: { Authorization: `Bearer ${TOKEN}` } },
    );
    revalidateTag(FIND_TAG, { expire: 0 }); // index changing → drop stale cache
    // Transparent proxy: the rebuild-job envelope is owned by the Phoenix
    // endpoint and forwarded verbatim.
    return NextResponse.json(body, { status: 200 });
  } catch (e) {
    // Status mapping: a transient restart-window failure → 503 (retryable) with
    // the friendly "restarting" message; a definitive upstream answer (e.g. a
    // reindex_failed or 401) → its real HTTP status + real message; anything else
    // → 502. Never let a raw JSON-parse SyntaxError reach the client.
    const status = isTransient(e)
      ? 503
      : e instanceof BpUpstreamError && e.status >= 400
        ? e.status
        : 502;
    return NextResponse.json(
      { ok: false, error: humanUpstreamMessage(e) },
      { status },
    );
  }
}
