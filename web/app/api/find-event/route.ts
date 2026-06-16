import { NextResponse } from "next/server";
import { DATASET } from "@/lib/config";

// Node runtime: reads the server-only BARKPARK_READ_TOKEN (never bundled to the
// browser) and proxies same-origin so the client never sees the API host/token.
// This route records search-feedback signals — a "Did you mean" correction
// accept, or a result-row click — both of which the upstream attributes to the
// browser's distinct session (X-BP-SEARCH-CLIENT) for anti-gaming.
export const runtime = "nodejs";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:4000";
const TOKEN = process.env.BARKPARK_READ_TOKEN;
// DATASET imported from lib/config (one source of truth, env-overridable).

interface FindEventBody {
  kind?: "correction" | "click";
  from?: string;
  to?: string;
  queryEventId?: string;
  objectId?: string;
  position?: number;
  sid?: string;
}

function upstreamHeaders(sid: string | undefined): HeadersInit {
  const h: Record<string, string> = { "Content-Type": "application/json" };
  if (TOKEN) h["Authorization"] = `Bearer ${TOKEN}`;
  if (sid) h["X-BP-SEARCH-CLIENT"] = sid;
  return h;
}

/**
 * Fire-and-forget feedback recorder. Always answers 200 `{ ok: true }` so a
 * recording failure never blocks the user — a dropped signal is acceptable, a
 * blocked correction-accept or a delayed result navigation is not. Upstream
 * errors are logged server-side, not surfaced.
 */
export async function POST(request: Request): Promise<NextResponse> {
  let body: FindEventBody;
  try {
    body = (await request.json()) as FindEventBody;
  } catch {
    return NextResponse.json({ ok: true });
  }

  const { kind, from, to, queryEventId, objectId, position, sid } = body;
  const headers = upstreamHeaders(sid);

  try {
    if (kind === "correction") {
      // The user accepted a "Did you mean <to>?" suggestion for <from>.
      if (from && to) {
        await fetch(`${API_URL}/v1/data/search/${DATASET}/correction`, {
          method: "POST",
          headers,
          cache: "no-store",
          body: JSON.stringify({ from, to }),
        });
      }
    } else if (kind === "click") {
      // The user clicked result <objectId> at <position> for query event
      // <queryEventId> — the EXISTING interaction endpoint.
      if (queryEventId && objectId) {
        await fetch(`${API_URL}/v1/data/search/${DATASET}/interaction`, {
          method: "POST",
          headers,
          cache: "no-store",
          body: JSON.stringify({ queryEventId, objectId, position }),
        });
      }
    }
  } catch (err) {
    // Best-effort: a recording failure must not break search UX.
    console.error("find-event upstream error:", err);
  }

  return NextResponse.json({ ok: true });
}
