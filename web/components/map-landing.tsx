"use client";

import { useCallback } from "react";
import { ListingsMap } from "@/components/listings-map";
import type { Listing } from "@/lib/listings-data";
import { useHoveredDoc, useGraphMatches } from "@/lib/hovered-doc-context";

export interface MapLandingProps {
  listings: Listing[];
}

/**
 * The "/" right-pane landing for the directory template: a full-height map of
 * every listing, in place of the old documentation graph. It is a drop-in peer
 * of `components/graph-landing.tsx` and reuses the SAME finder bridge:
 *
 *   - `useGraphMatches()` carries the finder's visible result set (with rank
 *     weights) → the map dims every pin that isn't a current hit, so searching
 *     the left rail filters the map.
 *   - `useHoveredDoc()` is the two-way hover highlight: hovering a pin lights
 *     the matching result row (`setHoveredId`), and a hovered row focuses its
 *     pin (`hoveredId`).
 *
 * The keys (listing `id` ⇄ finder hit `slug`) line up only when the map and the
 * finder read the same backend; with the bundled sample data the bridge is
 * inert and every pin simply stays lit. Pin clicks open the map's own marker
 * popover — a directory opens an info card, it doesn't navigate away.
 */
export function MapLanding({ listings }: MapLandingProps) {
  const { hoveredId, setHoveredId } = useHoveredDoc();
  const { matches } = useGraphMatches();

  const onHover = useCallback(
    (listing: Listing | null) => {
      setHoveredId(listing?.id ?? null);
    },
    [setHoveredId],
  );

  return (
    <div className="relative h-full w-full">
      {/* Quiet top-left caption, matching the old graph landing's overlay. */}
      <div className="pointer-events-none absolute left-5 top-5 z-20 max-w-xs select-none">
        <p className="text-xs font-semibold leading-relaxed text-zinc-700">
          {listings.length} {listings.length === 1 ? "location" : "locations"}
        </p>
        <p className="mt-1 text-[0.7rem] leading-relaxed text-zinc-500">
          {matches
            ? `${matches.length} ${matches.length === 1 ? "match" : "matches"} from your search · search to filter · click a pin`
            : "Search on the left to filter · click a pin for details"}
        </p>
      </div>

      <ListingsMap
        listings={listings}
        matches={matches}
        hoveredId={hoveredId}
        onHover={onHover}
      />
    </div>
  );
}
