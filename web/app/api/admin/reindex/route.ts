import { NextResponse } from "next/server";
import { revalidateTag } from "next/cache";
import { FIND_TAG } from "@/lib/find-search";

// Trigger an Indx blue/green rebuild via the token-gated Barkpark endpoint
// (uses the server-only read token — never bundled). The rebuild runs async on
// the API node (~30s); we purge the find cache so cached results refresh once
// the new dataset swaps in.
export const runtime = "nodejs";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:4000";
const TOKEN = process.env.BARKPARK_READ_TOKEN;
const DATASET = "production";
// Mirrors the finder's content types (lib/find.ts DOC_TYPES) so Indx indexes
// everything the finder can browse — including sheets, so /d/sheet/:slug docs
// are findable on the Indx engine (not just Postgres).
const TYPES = "post,page,author,category,project,paper,sheet";

export async function POST(): Promise<NextResponse> {
  if (!TOKEN) {
    return NextResponse.json(
      { ok: false, error: "reindex needs BARKPARK_READ_TOKEN" },
      { status: 503 },
    );
  }
  try {
    const res = await fetch(
      `${API_URL}/v1/data/search/${DATASET}/reindex?types=${TYPES}`,
      { method: "POST", headers: { Authorization: `Bearer ${TOKEN}` }, cache: "no-store" },
    );
    const body = await res.json();
    revalidateTag(FIND_TAG, { expire: 0 }); // index changing → drop stale cache
    return NextResponse.json(body, { status: res.ok ? 200 : 502 });
  } catch (e) {
    return NextResponse.json(
      { ok: false, error: (e as Error).message },
      { status: 502 },
    );
  }
}
