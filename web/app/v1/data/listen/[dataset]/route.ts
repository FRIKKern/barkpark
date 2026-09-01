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
 * token, and pipes the upstream `text/event-stream` back — so the browser
 * subscribes same-origin with no token and no CORS.
 *
 * INVARIANT: this demo reads exactly ONE configured dataset (`lib/config.ts`'s
 * `DATASET`), same as every other route in `web/`. The `[dataset]` path segment
 * is therefore checked against `DATASET` and any mismatch is refused with 404
 * BEFORE the privileged server token is attached to anything and BEFORE any
 * upstream fetch — this proxy is not a general-purpose forwarder for arbitrary
 * datasets, even though the upstream listen endpoint does its own per-token
 * redaction.
 *
 * INVARIANT: this demo reads exactly ONE perspective — `published`, same as
 * every other read surface in `web/` (`lib/barkpark-client.ts`,
 * `lib/find-search.ts` and `components/live-bridge.tsx` all pin it;
 * `lib/papers.ts` states the intent outright: draft values never leak into the
 * reader). On THIS route that invariant is enforced by `clampToPublished`
 * below — a filter over the response bytes — NOT by the `perspective` query
 * param.
 *
 * WHY THE PARAM IS NOT THE CONTROL. The threat model is real and unchanged: the
 * browser connects with NO token, this handler attaches the privileged server
 * one, and the API clamps a caller to public/published content only because
 * that caller is ANONYMOUS. Adding the credential removes that clamp. But the
 * remedy of pinning `?perspective=published` never implemented it — measured on
 * the API, not assumed:
 *
 *   - `grep -c perspective \
 *      api/lib/barkpark_web/controllers/listen_controller.ex` -> 0.
 *   - `ListenController.listen/2` reads exactly ONE thing off `params`:
 *     `params["lastEventId"]`.
 *   - Neither `Barkpark.Content.EventLog` nor `Barkpark.Content.Broadcast` has
 *     a perspective concept either.
 *
 * So the pinned param is discarded upstream and the stream is whatever the
 * SERVER TOKEN can see. Drafts demonstrably flow: the API's own
 * `listen_controller_test.exs` seeds `drafts.l1`, replays it, and asserts it IS
 * emitted. The only filtering the API runs on this path is `Envelope.render`
 * field-visibility, computed against the CALLER CONTEXT — which here is the
 * server token, not the anonymous browser that actually receives the bytes.
 *
 * The REPLAY leg is the bigger half. `lastEventId` is caller-controlled and
 * forwarded untouched, and the controller falls back to it when no
 * `Last-Event-ID` header is present. `EventLog.replay_since/4` has NO publish
 * filter at all, so `?lastEventId=0` replays the dataset's entire
 * `mutation_events` table — whose `document` column is written as
 * `Envelope.render(doc, nil, :internal)`, the full INTERNAL snapshot.
 *
 * The `perspective` pin is KEPT below only as forward-compatibility for an API
 * that may one day grow the concept. IT DOES NOTHING TODAY. `clampToPublished`
 * is the actual control, and it is what the tests assert
 * (`web/__tests__/listen-proxy-draft-clamp.test.ts` reads the CLIENT's bytes;
 * `listen-proxy-perspective.test.ts` only pins the URL the handler wrote).
 *
 * DOCTRINE: a proxy that ADDS credentials must re-derive every constraint that
 * was implied by not having them. Caller-controlled inputs on this route, and
 * where each now stands:
 *
 *   input                      | changes what the API returns? | clamped now?
 *   ---------------------------|-------------------------------|--------------
 *   `[dataset]` path segment   | yes (which dataset streams)   | yes, 404 gate
 *   `lastEventId` query param  | YES — unfiltered full replay  | yes, by the
 *                              |   of `mutation_events`        |   body filter
 *   `Last-Event-ID` header     | same, and takes PRECEDENCE    | same
 *   `perspective` query param  | no — the API never reads it   | n/a (inert)
 *   `types` query param        | no — the API never reads it   | n/a (inert)
 *   `filter[...]` query param  | no — the API never reads it   | n/a (inert)
 *   `x-barkpark-api-version`   | no — nothing in `api/lib`     | n/a (inert)
 *                              |   reads it; CORS-listed only  |
 *
 * `types`/`filter[...]` are forwarded and merely UNDOCUMENTED upstream, which is
 * not the same as clamped: if the API ever starts honouring them they become
 * caller-controlled selection under the server's credentials, and the body
 * filter — which judges every frame on its own payload — is what keeps that
 * safe rather than the forwarding rule.
 *
 * Requires the Node.js runtime (streaming fetch) — and `BARKPARK_TOKEN`
 * with listen permission in the environment. Without the token, upstream 401s
 * and this returns 401 to the client (surfaced by <BarkparkLive/>).
 *
 * LIVENESS, honestly: `BarkparkWeb.Plugs.PublicRead` 403s a `public-read` token
 * on `listen` (it allows only `GET /v1/data/query|doc` and `/v1/graph`). So
 * depending on the deployed token's tier this route is either leaking drafts (a
 * read/write/admin token) or entirely dead (a public-read token). This change
 * fixes the first case and does not affect the second.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const apiUrl = PUBLIC_API_URL.replace(/\/+$/, "");
const token = READ_TOKEN;

/**
 * Forward-compatibility only — the upstream `ListenController` does NOT read
 * this param today (see the note above). The stream filter is the control.
 */
const PERSPECTIVE = "published";

/** The `drafts.` id prefix — `Barkpark.Content.DraftId`'s own discriminator. */
const DRAFT_ID_PREFIX = "drafts.";

/**
 * SSE `event:` names the API emits that carry no document payload:
 * `welcome` (the connect frame) and `overloaded` (the backpressure shed
 * frame). Heartbeats are comment-only blocks and are handled separately.
 * Anything else that is not a verified-published `mutation` is DROPPED.
 */
const DOCUMENTLESS_EVENTS = new Set(["welcome", "overloaded"]);

/** SSE frame terminators, per spec: CRLF CRLF, LF LF, or CR CR. */
const FRAME_TERMINATORS = ["\r\n\r\n", "\n\n", "\r\r"];

/** Earliest frame terminator in `buffer`, or null while the frame is partial. */
function findFrameEnd(
  buffer: string,
): { index: number; length: number } | null {
  let best: { index: number; length: number } | null = null;
  for (const terminator of FRAME_TERMINATORS) {
    const index = buffer.indexOf(terminator);
    if (index === -1) continue;
    if (best === null || index < best.index) {
      best = { index, length: terminator.length };
    }
  }
  return best;
}

/**
 * Is this mutation payload affirmatively PUBLISHED?
 *
 * The discriminator is `_draft` on the rendered envelope, cross-checked against
 * the `drafts.` id prefix. Both are on the wire and neither can be redacted
 * away: `Envelope.render/3` stamps `_id`, `_draft` (`Content.draft?(doc_id)`)
 * and `_publishedId`, and every `_`-prefixed key is in `envelope.ex`'s
 * `@reserved` list, which redaction always keeps. `format_event/2` additionally
 * puts the raw `doc_id` on the frame as `documentId`, which survives a delete
 * event whose `result` snapshot may be absent.
 *
 * `_publishedId` is deliberately NOT used: it is present on drafts and
 * published documents alike, so it discriminates nothing.
 *
 * FAILS CLOSED, two ways. Every signal that IS present must say published, and
 * at least ONE must be present — a payload that says nothing about its own
 * publish state is dropped rather than assumed safe.
 */
function isPublishedPayload(payload: Record<string, unknown>): boolean {
  let sawSignal = false;

  const documentId = payload.documentId;
  if (documentId !== undefined) {
    if (typeof documentId !== "string") return false;
    if (documentId.startsWith(DRAFT_ID_PREFIX)) return false;
    sawSignal = true;
  }

  const result = payload.result;
  if (result !== undefined && result !== null) {
    if (typeof result !== "object" || Array.isArray(result)) return false;
    const envelope = result as Record<string, unknown>;

    const id = envelope._id;
    if (id !== undefined) {
      if (typeof id !== "string") return false;
      if (id.startsWith(DRAFT_ID_PREFIX)) return false;
      sawSignal = true;
    }

    const draft = envelope._draft;
    if (draft !== undefined) {
      // Strictly `false` — `undefined`, `null`, `0` and `"false"` all drop.
      if (draft !== false) return false;
      sawSignal = true;
    }
  }

  return sawSignal;
}

/** Parse a frame's JSON `data`, or null if it is not a JSON object. */
function parseData(data: string): Record<string, unknown> | null {
  if (data === "") return null;
  try {
    const parsed: unknown = JSON.parse(data);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      return null;
    }
    return parsed as Record<string, unknown>;
  } catch {
    return null;
  }
}

/**
 * May this whole SSE frame reach the browser? Fails closed on anything it
 * cannot positively account for — an unparseable frame is exactly what an
 * attacker would aim for.
 */
function framePasses(block: string): boolean {
  const lines = block.split(/\r\n|\r|\n/);

  // Comment-only block: a heartbeat (`: keepalive`). No payload, always safe,
  // and dropping it would make the client judge the connection dead.
  if (lines.every((line) => line.startsWith(":"))) return true;

  let event = "message";
  const data: string[] = [];

  for (const line of lines) {
    if (line === "" || line.startsWith(":")) continue;
    const colon = line.indexOf(":");
    const field = colon === -1 ? line : line.slice(0, colon);
    let value = colon === -1 ? "" : line.slice(colon + 1);
    if (value.startsWith(" ")) value = value.slice(1);

    if (field === "event") event = value;
    // Per spec, multiple `data:` lines concatenate with a newline.
    else if (field === "data") data.push(value);
    else if (field === "id" || field === "retry") continue;
    // An unknown SSE field is an unknown frame shape — fail closed.
    else return false;
  }

  const payload = parseData(data.join("\n"));

  if (DOCUMENTLESS_EVENTS.has(event)) {
    // Allowed by name, but still refused if it ever starts carrying a document,
    // so this allowlist cannot become a bypass.
    if (payload === null) return data.length === 0;
    return payload.result === undefined && payload.documentId === undefined;
  }

  if (event !== "mutation") return false;
  if (payload === null) return false;
  return isPublishedPayload(payload);
}

/**
 * The control this route's threat model actually needs: re-frame the upstream
 * SSE stream and forward only frames proven to carry published content.
 *
 * Buffers across chunk boundaries — a frame can arrive split in half, and a
 * filter that judged each network chunk independently would leak the tail of a
 * draft frame. Passed frames are re-emitted VERBATIM, so `id:` / `event:` /
 * `retry:` semantics and the blank-line terminator survive untouched and
 * Last-Event-ID resume keeps working. Trailing bytes at end-of-stream are an
 * incomplete frame and are never emitted.
 */
function clampToPublished(
  upstream: ReadableStream<Uint8Array>,
): ReadableStream<Uint8Array> {
  const reader = upstream.getReader();
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  let buffer = "";

  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      for (;;) {
        let chunk: ReadableStreamReadResult<Uint8Array>;
        try {
          chunk = await reader.read();
        } catch (err) {
          controller.error(err);
          return;
        }

        if (chunk.done) {
          // `buffer` may still hold a PARTIAL frame. Fail closed: drop it.
          controller.close();
          return;
        }

        buffer += decoder.decode(chunk.value, { stream: true });

        let emitted = false;
        let end = findFrameEnd(buffer);
        while (end !== null) {
          const block = buffer.slice(0, end.index);
          const terminator = buffer.slice(end.index, end.index + end.length);
          buffer = buffer.slice(end.index + end.length);
          if (block !== "" && framePasses(block)) {
            controller.enqueue(encoder.encode(block + terminator));
            emitted = true;
          }
          end = findFrameEnd(buffer);
        }

        // Yield to the consumer once we have something; otherwise keep reading
        // rather than returning an empty pull (which would stall the stream).
        if (emitted) return;
      }
    },
    cancel(reason) {
      return reader.cancel(reason);
    },
  });
}

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
  // Forward types / filter[...] / lastEventId, then set the perspective. The
  // set() collapses a browser-supplied value and fills in an omitted one, so
  // exactly one value reaches upstream — but see the note above: the API does
  // NOT read this param, so this line clamps NOTHING on its own. The response
  // filter below is what enforces the published-only invariant.
  upstream.search = incoming.search;
  upstream.searchParams.set("perspective", PERSPECTIVE);

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

  return new Response(clampToPublished(upstreamRes.body), {
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
