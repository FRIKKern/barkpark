import { NextResponse } from "next/server";
import { revalidateTag } from "next/cache";
import { createHmac, timingSafeEqual } from "node:crypto";
import { FIND_TAG } from "@/lib/find-search";
import { bpAll } from "@/lib/bp-tags";
import { DATASET } from "@/lib/config";

// Node runtime: HMAC verification needs node:crypto. Force-dynamic: this is a
// pure side-effect endpoint (verify → revalidate), never cached.
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const SECRET = process.env.BARKPARK_WEBHOOK_SECRET;
const PREVIOUS_SECRET = process.env.BARKPARK_WEBHOOK_PREVIOUS_SECRET;
const TOLERANCE_S = 300; // ±5 min, matches the dispatcher/handler contract
const DEDUP_LRU = 512;

/** Best-effort in-process dedup (the dispatcher also dedups via a UNIQUE
 * (endpoint_id, event_id) row, so this is belt-and-suspenders against retries
 * landing on the same warm instance). */
const seen = new Set<string>();
function alreadySeen(id: string): boolean {
  if (seen.has(id)) return true;
  seen.add(id);
  if (seen.size > DEDUP_LRU) {
    const oldest = seen.values().next().value;
    if (oldest !== undefined) seen.delete(oldest);
  }
  return false;
}

/**
 * Parse the timestamp + v1 hex out of the headers. Accepts BOTH wire formats:
 *  - dispatcher (as shipped): `x-barkpark-signature: v1=<hex>` + a separate
 *    `x-barkpark-timestamp: <unix>` header
 *  - Stripe-style combined:   `x-barkpark-signature: t=<unix>,v1=<hex>`
 * so this keeps working if the dispatcher is later reconciled to the combined
 * contract (the contract's declared fix direction).
 */
function parseSig(
  sigHeader: string | null,
  tsHeader: string | null,
): { t: number; v1: string } | null {
  if (!sigHeader) return null;
  let t: number | null = null;
  let v1: string | null = null;
  for (const part of sigHeader.split(",")) {
    const p = part.trim();
    if (p.startsWith("t=")) {
      const n = Number(p.slice(2));
      if (Number.isFinite(n) && n > 0) t = Math.floor(n);
    } else if (p.startsWith("v1=")) {
      const hex = p.slice(3);
      if (hex.length > 0 && /^[0-9a-f]+$/i.test(hex)) v1 = hex.toLowerCase();
    }
  }
  // Split format: timestamp arrives in its own header.
  if (t === null && tsHeader) {
    const n = Number(tsHeader);
    if (Number.isFinite(n) && n > 0) t = Math.floor(n);
  }
  if (t === null || v1 === null) return null;
  return { t, v1 };
}

function verify(
  secret: string | undefined,
  signed: string,
  providedHex: string,
): boolean {
  if (!secret) return false;
  const expected = createHmac("sha256", secret).update(signed).digest("hex");
  if (expected.length !== providedHex.length || expected.length === 0)
    return false;
  return timingSafeEqual(
    Buffer.from(expected, "hex"),
    Buffer.from(providedHex, "hex"),
  );
}

interface WebhookPayload {
  event?: string;
  type?: string;
  doc_id?: string;
  dataset?: string;
  workspace?: string;
  project?: string;
  sync_tags?: string[];
  deliveryId?: string;
}

/** Tags to bust for one mutation: the dispatcher's doc/type tags (scoped +
 * flat), the reconstructed `_all` (flat + scoped — dispatcher omits it), and
 * the finder's tag (any content change can change search results). */
function tagsFor(p: WebhookPayload): string[] {
  const out = new Set<string>(p.sync_tags ?? []);
  const ds = p.dataset ?? DATASET;
  out.add(bpAll(ds));
  if (p.workspace && p.project) {
    out.add(`bp:ws:${p.workspace}:p:${p.project}:ds:${ds}:_all`);
  }
  out.add(FIND_TAG);
  return [...out].filter(Boolean);
}

export async function POST(req: Request): Promise<NextResponse> {
  if (!SECRET) {
    // Misconfigured deploy — fail loud (not a silent 200) so it shows up.
    return NextResponse.json(
      { error: "webhook_not_configured" },
      { status: 500 },
    );
  }

  const sig = parseSig(
    req.headers.get("x-barkpark-signature"),
    req.headers.get("x-barkpark-timestamp"),
  );
  if (!sig) return NextResponse.json({ error: "bad_signature" }, { status: 401 });

  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - sig.t) > TOLERANCE_S) {
    return NextResponse.json({ error: "stale" }, { status: 401 });
  }

  let rawBody: string;
  try {
    rawBody = await req.text();
  } catch {
    return NextResponse.json({ error: "bad_request" }, { status: 400 });
  }

  // Sign exactly what the dispatcher signed: "<timestamp>.<rawBody>".
  const signed = `${sig.t}.${rawBody}`;
  if (!verify(SECRET, signed, sig.v1) && !verify(PREVIOUS_SECRET, signed, sig.v1)) {
    return NextResponse.json({ error: "bad_signature" }, { status: 401 });
  }

  let payload: WebhookPayload;
  try {
    const parsed = rawBody.length === 0 ? {} : JSON.parse(rawBody);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      return NextResponse.json({ error: "bad_request" }, { status: 400 });
    }
    payload = parsed as WebhookPayload;
  } catch {
    return NextResponse.json({ error: "bad_request" }, { status: 400 });
  }

  const deliveryId =
    req.headers.get("x-barkpark-event-id") ??
    req.headers.get("x-barkpark-delivery-id") ??
    (typeof payload.deliveryId === "string" ? payload.deliveryId : null);
  if (deliveryId && alreadySeen(deliveryId)) {
    return NextResponse.json({ deduped: true });
  }

  // Bust the affected caches. revalidateTag is synchronous-enough here; Next
  // 16 takes a profile arg — `{ expire: 0 }` purges immediately.
  const tags = tagsFor(payload);
  for (const tag of tags) revalidateTag(tag, { expire: 0 });

  return NextResponse.json({ ok: true, revalidated: tags });
}

export async function GET(): Promise<NextResponse> {
  return NextResponse.json({ error: "method_not_allowed" }, { status: 405 });
}
