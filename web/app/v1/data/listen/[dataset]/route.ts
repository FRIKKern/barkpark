import "server-only";
import { PUBLIC_API_URL, READ_TOKEN } from "@/lib/bp-env";
import { DATASET } from "@/lib/config";

/**
 * Same-origin SSE proxy for the live-listen stream.
 *
 * `@barkpark/nextjs`'s client `<BarkparkLive/>` opens a streaming fetch against
 * `<origin>/v1/data/listen/<dataset>`. The upstream Phoenix endpoint
 * (`/v1/data/listen/:dataset`) is token-gated (private API), but the read token
 * is server-only and must never reach the browser. This handler bridges that:
 * it forwards the browser's query params + `Last-Event-ID`, injects the server
 * token, and pipes the upstream `text/event-stream` straight back — so the
 * browser subscribes same-origin with no token and no CORS.
 *
 * INVARIANT: this demo reads exactly ONE configured dataset (`lib/config.ts`'s
 * `DATASET`), same as every other route in `web/`. The `[dataset]` path segment
 * is therefore checked against `DATASET` and any mismatch is refused with 404
 * BEFORE the privileged server token is attached to anything and BEFORE any
 * upstream fetch — this proxy is not a general-purpose forwarder for arbitrary
 * datasets, even though the upstream listen endpoint does its own per-token
 * redaction.
 *
 * Requires the Node.js runtime (streaming fetch) — and `BARKPARK_TOKEN`
 * with listen permission in the environment. Without the token, upstream 401s
 * and this returns 401 to the client (surfaced by <BarkparkLive/>).
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const apiUrl = PUBLIC_API_URL.replace(/\/+$/, "");
const token = READ_TOKEN;

export async function GET(
  req: Request,
  { params }: { params: Promise<{ dataset: string }> },
) {
  const { dataset } = await params;
  if (dataset !== DATASET) {
    return new Response(`listen proxy: unknown dataset "${dataset}"`, {
      status: 404,
    });
  }
  const incoming = new URL(req.url);

  const upstream = new URL(
    `${apiUrl}/v1/data/listen/${encodeURIComponent(dataset)}`,
  );
  // Forward types / perspective / filter[...] verbatim.
  upstream.search = incoming.search;

  const headers: Record<string, string> = {
    Accept: "text/event-stream",
    "X-Barkpark-Api-Version":
      req.headers.get("x-barkpark-api-version") ?? "2026-04-01",
  };
  if (token) headers.Authorization = `Bearer ${token}`;
  const lastEventId = req.headers.get("last-event-id");
  if (lastEventId) headers["Last-Event-ID"] = lastEventId;

  let upstreamRes: Response;
  try {
    upstreamRes = await fetch(upstream.toString(), {
      method: "GET",
      headers,
      // Abort the upstream stream when the browser disconnects.
      signal: req.signal,
      cache: "no-store",
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return new Response(`listen proxy: upstream fetch failed — ${message}`, {
      status: 502,
    });
  }

  const contentType = upstreamRes.headers.get("content-type") ?? "";
  if (!upstreamRes.ok || !upstreamRes.body) {
    return new Response(
      `listen proxy: upstream ${upstreamRes.status}${
        token ? "" : " (no BARKPARK_TOKEN configured)"
      }`,
      { status: upstreamRes.status || 502 },
    );
  }
  if (!contentType.includes("text/event-stream")) {
    return new Response(
      `listen proxy: expected text/event-stream, got ${contentType || "(none)"}`,
      { status: 502 },
    );
  }

  return new Response(upstreamRes.body, {
    status: 200,
    headers: {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
      // Disable proxy buffering (Caddy/Vercel) so events flush immediately.
      "X-Accel-Buffering": "no",
    },
  });
}
