"use client";

import { useCallback, useMemo } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { GraphView } from "@/components/graph-view";
import type { GraphNode, GraphEdge } from "@/lib/graph";
import { useHoveredDoc, useGraphMatches } from "@/lib/hovered-doc-context";

export interface GraphLandingProps {
  nodes: GraphNode[];
  edges: GraphEdge[];
  rootId?: string | null;
  /** The server cut the node list at its graph budget (`truncated` on the
   * upstream payload — see `lib/graph.ts`). Drives the honest showing-N line
   * below; absent/false claims nothing. */
  truncated?: boolean;
  /** Upstream `truncation_reason` (e.g. "node_budget") — surfaced for devtools
   * via a title attribute, never as user copy. */
  truncationReason?: string | null;
}

/**
 * The "/" right-pane landing: a full-height Obsidian-style graph of the docs
 * corpus. Clicking a node opens that document in the EXISTING master/detail
 * finder — the navigation swaps only the `(finder)` `children` segment, so the
 * left finder rail never remounts and its search state (in the query string)
 * survives. The live finder query is carried onto the doc href the same way the
 * result rows do it, keeping search + open-doc coexisting in the URL.
 *
 * The renderer owns its own legend/zoom chrome + hover hop-cascade; we only
 * translate a node click into a route push and skip phantom (document-less)
 * nodes.
 *
 * OVERLAY CORNERS (single-owner contract, mirrored in bp-graph.js): the
 * renderer owns top-left (legend) and bottom-right (zoom strip); top-right is
 * its search box, suppressed here via `externalSearch` (the finder owns
 * search). This caption is the host's ONE overlay and lives bottom-left — the
 * only free corner. Never move it onto a renderer-owned corner.
 */
export function GraphLanding({
  nodes,
  edges,
  rootId = null,
  truncated = false,
  truncationReason = null,
}: GraphLandingProps) {
  const router = useRouter();
  const sp = useSearchParams();
  const { hoveredId, setHoveredId } = useHoveredDoc();
  // The finder's visible result set drives which nodes the graph keeps lit, and
  // how strongly (by search rank).
  const { matches } = useGraphMatches();

  // Real documents only — phantoms are referenced-but-absent, not corpus size.
  const docCount = useMemo(
    () => nodes.reduce((n, node) => (node.phantom ? n : n + 1), 0),
    [nodes],
  );

  const onNodeClick = useCallback(
    (node: GraphNode) => {
      // Phantoms are referenced-but-absent nodes — no document to open. The
      // renderer already suppresses their click, but guard here too.
      if (node.phantom || !node.doc_id || !node.type) return;
      const qs = sp.toString();
      const href = `/d/${node.type}/${node.doc_id}`;
      router.push(qs ? `${href}?${qs}` : href);
    },
    [router, sp],
  );

  // Cross-surface highlight: hovering a graph node lights up its finder result
  // (matched by doc_id == hit.slug). Phantom/missing nodes clear the highlight.
  const onNodeHover = useCallback(
    (node: GraphNode | null) => {
      setHoveredId(node && !node.phantom && node.doc_id ? node.doc_id : null);
    },
    [setHoveredId],
  );

  return (
    <div className="relative h-full w-full bg-background">
      {/* Theme-AWARE panel (the panel-theme contract lives in graph-view.tsx):
          the renderer paints the whole canvas bed + chrome for the current
          data-theme and re-skins live on bp:themechange, so this host bg only
          shows pre-init and must track the site theme — the old always-dark
          `bg-graph-canvas` token is retired from this surface. */}
      {/* Caption — the host's single overlay, bottom-left (see corner contract
          above). It sits above the canvas but lets pointer events through. */}
      <div className="pointer-events-none absolute bottom-5 left-5 z-20 max-w-xs select-none">
        <p className="text-xs font-medium leading-relaxed text-foreground/75">
          Barkpark documentation graph
        </p>
        <p className="mt-1 text-[0.7rem] leading-relaxed text-muted-text">
          {matches
            ? `${matches.length} ${matches.length === 1 ? "match" : "matches"} from your search · brightest = best · click to read`
            : `${docCount.toLocaleString()} documents · search on the left to filter · click a node to read`}
        </p>
        {truncated ? (
          <p
            className="mt-1 text-[0.7rem] leading-relaxed text-muted-text"
            title={truncationReason ?? undefined}
          >
            {`Showing the first ${docCount.toLocaleString()} — the full corpus is larger`}
          </p>
        ) : null}
      </div>

      <GraphView
        nodes={nodes}
        edges={edges}
        rootId={rootId}
        matches={matches}
        hoveredId={hoveredId}
        onNodeClick={onNodeClick}
        onNodeHover={onNodeHover}
      />
    </div>
  );
}
