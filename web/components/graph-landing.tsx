"use client";

import { useCallback } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { GraphView } from "@/components/graph-view";
import type { GraphNode, GraphEdge } from "@/lib/graph";
import { useHoveredDoc, useGraphMatches } from "@/lib/hovered-doc-context";

export interface GraphLandingProps {
  nodes: GraphNode[];
  edges: GraphEdge[];
  rootId?: string | null;
}

/**
 * The "/" right-pane landing: a full-height Obsidian-style graph of the docs
 * corpus. Clicking a node opens that document in the EXISTING master/detail
 * finder — the navigation swaps only the `(finder)` `children` segment, so the
 * left finder rail never remounts and its search state (in the query string)
 * survives. The live finder query is carried onto the doc href the same way the
 * result rows do it, keeping search + open-doc coexisting in the URL.
 *
 * The renderer owns its own search box + hover hop-cascade; we only translate a
 * node click into a route push and skip phantom (document-less) nodes.
 */
export function GraphLanding({ nodes, edges, rootId = null }: GraphLandingProps) {
  const router = useRouter();
  const sp = useSearchParams();
  const { hoveredId, setHoveredId } = useHoveredDoc();
  // The finder's visible result set drives which nodes the graph keeps lit, and
  // how strongly (by search rank).
  const { matches } = useGraphMatches();

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
    <div className="relative h-full w-full bg-[#16161a]">
      {/* Caption — quiet top-left overlay in the dark Obsidian aesthetic. It sits
          above the canvas but lets pointer events through to the graph. */}
      <div className="pointer-events-none absolute left-5 top-5 z-20 max-w-xs select-none">
        <p className="text-xs font-medium leading-relaxed text-zinc-400">
          Barkpark documentation graph
        </p>
        <p className="mt-1 text-[0.7rem] leading-relaxed text-zinc-500">
          {matches
            ? `${matches.length} ${matches.length === 1 ? "match" : "matches"} from your search · brightest = best · click to read`
            : "Search on the left to filter · click a node to read it"}
        </p>
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
