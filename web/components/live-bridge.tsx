"use client";

import { useMemo } from "react";
import { createClient } from "@barkpark/core";
import { BarkparkLive } from "@barkpark/nextjs/client";
import { DATASET } from "@/lib/config";

/**
 * Mounts the live-content subscription for the flat published surface.
 *
 * Builds a browser client pointed at the SAME ORIGIN (no token) so its
 * `/v1/data/listen/<dataset>` fetch hits our same-origin proxy
 * (`app/v1/data/listen/[dataset]/route.ts`), which injects the server token.
 * `<BarkparkLive/>` debounces incoming change events into `router.refresh()`,
 * re-rendering the server components with fresh data.
 *
 * Renders `null`. Mounted once in the root layout. Gated behind
 * `NEXT_PUBLIC_BARKPARK_LIVE=1` so it stays inert (no connection attempts, no
 * console noise) until the deployment is provisioned with a listen-capable
 * `BARKPARK_READ_TOKEN` and live is explicitly switched on.
 */
const liveEnabled = process.env.NEXT_PUBLIC_BARKPARK_LIVE === "1";

export function LiveBridge() {
  const client = useMemo(() => {
    if (!liveEnabled) return null;
    if (typeof window === "undefined") return null;
    return createClient({
      projectUrl: window.location.origin,
      dataset: DATASET,
      apiVersion: "2026-04-01",
      perspective: "published",
      // No token: the same-origin proxy authenticates upstream.
    });
  }, []);

  if (!client) return null;
  return <BarkparkLive client={client} />;
}
