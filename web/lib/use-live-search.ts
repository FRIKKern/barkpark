"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Socket, type Channel } from "phoenix";
import { DOC_TYPES, type FindResponse, type SearchEngine } from "@/lib/find";
import {
  shapeFindResponse,
  type UpstreamSearchJson,
} from "@/lib/find-shape";
import { DATASET } from "@/lib/config";

/**
 * Per-keystroke live search over ONE persistent WebSocket, browser → Barkpark
 * API DIRECT (bypassing the Vercel hop entirely). Each keystroke is a frame on
 * an already-open connection — no per-request TLS handshake, no serverless cold
 * path — which is the whole reason this exists over the HTTP `/api/find` route.
 *
 * Ships DARK, exactly like `LiveBridge`: inert unless BOTH
 *   - `NEXT_PUBLIC_BARKPARK_WS_URL`   (e.g. wss://api.barkpark.cloud/socket), and
 *   - `NEXT_PUBLIC_BARKPARK_WS_TOKEN` (a READ-ONLY token scoped to the public
 *      workspace/dataset — it reaches the browser, so it must grant nothing
 *      beyond the already-public published reads the demo serves anyway)
 * are set. With either unset, `enabled` is false and the finder keeps using the
 * same-origin HTTP path. `ready` only flips true once the channel has JOINED, so
 * any keystroke typed during the connect handshake still falls back to HTTP and
 * no query is dropped on the floor.
 *
 * Stale-reply safety: every `search()` stamps a monotonic `seq`. A reply whose
 * `seq` isn't the latest is rejected as an `AbortError` — which the finder's
 * fetch path already ignores — so a slow earlier keystroke can never overwrite a
 * newer result.
 */

const WS_URL = process.env.NEXT_PUBLIC_BARKPARK_WS_URL;
const WS_TOKEN = process.env.NEXT_PUBLIC_BARKPARK_WS_TOKEN;
const LIVE_ENABLED = Boolean(WS_URL && WS_TOKEN);

/** Same content-type allowlist the server route scopes to (keeps both consistent
 * and private config schemas out of browse/facets). */
const CONTENT_TYPES_CSV = DOC_TYPES.map((t) => t.type).join(",");
/** Tenancy scope the topic encodes — mirrors find-search's `/w/default/p/default`. */
const WS_SCOPE = "default:default";
const MAX_HITS = 100;

export interface LiveSearchArgs {
  q: string;
  engine: SearchEngine;
  browse: boolean;
}

export interface UseLiveSearch {
  /** Configured (both env vars present) — independent of connection state. */
  enabled: boolean;
  /** Channel has joined; safe to route searches over the socket. */
  ready: boolean;
  /** Push one query; resolves with a `FindResponse`. Rejects superseded queries
   * with an `AbortError` (the finder ignores those, same as a fetch abort). */
  search: (args: LiveSearchArgs) => Promise<FindResponse>;
}

function abortError(): Error {
  const e = new Error("superseded");
  e.name = "AbortError";
  return e;
}

export function useLiveSearch(): UseLiveSearch {
  const [ready, setReady] = useState(false);
  const channelRef = useRef<Channel | null>(null);
  // Monotonic query stamp — the latest wins; everything older is superseded.
  const seqRef = useRef(0);

  useEffect(() => {
    if (!LIVE_ENABLED || typeof window === "undefined") return;

    const socket = new Socket(WS_URL as string, { params: { token: WS_TOKEN } });
    socket.connect();

    const channel = socket.channel(`search:${WS_SCOPE}:${DATASET}`, {});
    channel
      .join()
      .receive("ok", () => {
        channelRef.current = channel;
        setReady(true);
      })
      .receive("error", () => {
        // Join refused (bad token/scope) — stay on HTTP. No console noise beyond
        // Phoenix's own; the finder simply never sees `ready`.
        channelRef.current = null;
        setReady(false);
      });

    return () => {
      channelRef.current = null;
      setReady(false);
      channel.leave();
      socket.disconnect();
    };
  }, []);

  const search = useCallback(
    ({ q, engine, browse }: LiveSearchArgs): Promise<FindResponse> => {
      const channel = channelRef.current;
      if (!channel) return Promise.reject(abortError());

      const seq = ++seqRef.current;
      const t0 = performance.now();

      return new Promise<FindResponse>((resolve, reject) => {
        channel
          .push("query", {
            q: browse ? " " : q,
            engine,
            types: CONTENT_TYPES_CSV,
            limit: MAX_HITS,
            seq,
          })
          .receive("ok", (reply: UpstreamSearchJson & { seq?: number }) => {
            // Drop any reply that a newer keystroke has already superseded.
            if (seqRef.current !== seq) return reject(abortError());
            resolve(
              shapeFindResponse(reply, {
                engine,
                // The socket always carries the scoped read token, so indx is
                // live — what the caller asked for is what's served.
                engineUsed: engine,
                browse,
                cache: false,
                upstreamMs: Math.round(performance.now() - t0),
              }),
            );
          })
          .receive("error", (err: unknown) =>
            reject(new Error(`live search error: ${JSON.stringify(err)}`)),
          )
          .receive("timeout", () => reject(new Error("live search timed out")));
      });
    },
    [],
  );

  return { enabled: LIVE_ENABLED, ready, search };
}
