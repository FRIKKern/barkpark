import { NextResponse } from "next/server";
import { DATASET } from "@/lib/config";
import { PUBLIC_API_URL, READ_TOKEN } from "@/lib/bp-env";

// Node runtime: reads the server-only BARKPARK_TOKEN (never bundled to the
// browser) and proxies same-origin so the client never sees the API host/token.
// This route records search-feedback signals — a "Did you mean" correction
// accept, or a result-row click — both of which the upstream attributes to the
// browser's distinct session (X-BP-SEARCH-CLIENT) for anti-gaming.
export const runtime = "nodejs";

const API_URL = PUBLIC_API_URL;
const TOKEN = READ_TOKEN;
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

/** The receipt this route answers with — see `recordingReceipt`. */
interface FindEventReceipt {
  /** The proxy handled the request. Never a claim about the recording. */
  ok: true;
  /** Whether the upstream write actually happened. Descends from the write. */
  recorded: boolean;
  /** Why nothing was recorded — the measurement `recorded:false` came from. */
  reason?: string;
}

/**
 * Every exit of this route goes through here, so `recorded` can only ever be a
 * value someone measured.
 *
 * The status line stays 200 at ALL exits, deliberately. A dropped analytics
 * signal must not break search UX; and if the receipt rode the status line for
 * some exits only, a caller reading `res.ok` would see RED for a body we could
 * not parse and GREEN for an upstream 500 — the inversion this shape exists to
 * prevent. `app/api/find/route.ts` answers 200-with-a-derived-field the same way.
 */
function recordingReceipt(recorded: boolean, reason?: string): NextResponse {
  const receipt: FindEventReceipt = { ok: true, recorded };
  if (reason) receipt.reason = reason;
  return NextResponse.json(receipt, { status: 200 });
}

/**
 * Fire-and-forget feedback recorder — best-effort about DELIVERY, exact about
 * REPORTING. Always answers 200 so a recording failure never blocks the user (a
 * dropped signal is acceptable; a blocked correction-accept or a delayed result
 * navigation is not), but the body's `recorded` field always descends from what
 * actually happened: the upstream response status where a write was attempted,
 * and an explicit false where none was. Upstream failures are logged
 * server-side AND reported in the receipt — never laundered into a green.
 */
export async function POST(request: Request): Promise<NextResponse> {
  let body: FindEventBody;
  try {
    body = (await request.json()) as FindEventBody;
  } catch {
    // Nothing was parsed, so nothing was sent: not a failed write, no write.
    return recordingReceipt(
      false,
      "unparsable request body: no upstream write was attempted",
    );
  }

  const { kind, from, to, queryEventId, objectId, position, sid } = body;

  // Resolve the signal to its upstream write FIRST: a signal that routes
  // nowhere (unknown kind, a correction with no `to`, a click with no
  // `queryEventId`) is a distinct outcome from a write that failed, and the
  // receipt has to be able to say which one happened.
  let url: string;
  let payload: Record<string, unknown>;
  if (kind === "correction" && from && to) {
    // The user accepted a "Did you mean <to>?" suggestion for <from>.
    url = `${API_URL}/v1/data/search/${DATASET}/correction`;
    payload = { from, to };
  } else if (kind === "click" && queryEventId && objectId) {
    // The user clicked result <objectId> at <position> for query event
    // <queryEventId> — the EXISTING interaction endpoint.
    url = `${API_URL}/v1/data/search/${DATASET}/interaction`;
    payload = { queryEventId, objectId, position };
  } else {
    return recordingReceipt(
      false,
      `unroutable signal (kind=${kind ?? "absent"}): no upstream write was attempted`,
    );
  }

  try {
    // Bind the response: fetch does NOT reject on 4xx/5xx, so an upstream 422
    // or 500 reaches this line as a resolved value and would otherwise pass
    // straight through the catch below unseen.
    const res = await fetch(url, {
      method: "POST",
      headers: upstreamHeaders(sid),
      cache: "no-store",
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      console.error(`find-event upstream refused ${kind}: HTTP ${res.status}`);
      return recordingReceipt(false, `upstream responded ${res.status}`);
    }
    return recordingReceipt(true);
  } catch (err) {
    // Best-effort delivery: a recording failure must not break search UX — but
    // it is still reported, not swallowed.
    console.error("find-event upstream error:", err);
    const message = err instanceof Error ? err.message : String(err);
    return recordingReceipt(false, `upstream unreachable: ${message}`);
  }
}
