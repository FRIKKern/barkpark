"use client";

import { useCallback, useMemo } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { GraphView } from "@/components/graph-view";
import { SiteProvenance } from "@/components/site-provenance";
import type { GraphNode, GraphEdge } from "@/lib/graph";
import type { BuildIdentity, CorpusProvenance } from "@/lib/provenance";
import { useHoveredDoc, useGraphMatches } from "@/lib/hovered-doc-context";

/** Everything the caption needs that is NOT already in `nodes`/`edges`: the
 * deploy markers and the parts of the corpus read that survive as flags rather
 * than as nodes. The COUNTS are deliberately absent — they are derived below
 * from the very node array this component renders, so the number on screen can
 * never disagree with the graph on screen. */
export interface LandingProvenance {
  /** Deploy markers with the "dev"/"unknown" sentinels resolved to null. */
  build: BuildIdentity;
  /** Whether an API base URL was configured at all (`lib/bp-env`). */
  apiConfigured: boolean;
  /** Upstream status when the corpus could NOT be read; null on success. */
  upstreamStatus: number | null;
  /** `graph <status>: <message>` on failure, null on success. */
  upstreamReason: string | null;
}

export interface GraphLandingProps {
  nodes: GraphNode[];
  edges: GraphEdge[];
  rootId?: string | null;
  /** The server cut the corpus at a ceiling (`truncated` on the upstream
   * payload — see `lib/graph.ts`). Drives the "At least N" line below; absent
   * or false claims nothing. */
  truncated?: boolean;
  /** Upstream `truncation_reason` ("per_type_cap", "node_budget", …). Rendered
   * as VISIBLE text, never as a tooltip — see below. */
  truncationReason?: string | null;
  /** Build + connection truth for the provenance line. Omitted → no provenance
   * surface at all, which is the honest degradation: this component must never
   * invent a state it was not told about. */
  provenance?: LandingProvenance;
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
 *
 * WHAT THE CAPTION SAYS, and why it is not just a number: the corpus count used
 * to render as a bare "N documents" whether or not the server had cut it, with
 * the cut described as "Showing the first N — the full corpus is larger" and
 * the upstream reason parked in a `title=` attribute no touch, keyboard or
 * screen-reader user ever reaches. That copy describes a PREFIX cut; the cut
 * that actually fires on the live corpus is a per-TYPE cap, under which nothing
 * is "the first" of anything. The count, the ceiling, the build and the
 * connection state now all come from `lib/provenance` (pure, unit-pinned), and
 * the counts specifically are derived from THIS component's own `nodes` array.
 */
export function GraphLanding({
  nodes,
  edges,
  rootId = null,
  truncated = false,
  truncationReason = null,
  provenance,
}: GraphLandingProps) {
  const router = useRouter();
  const sp = useSearchParams();
  const { hoveredId, setHoveredId } = useHoveredDoc();
  // The finder's visible result set drives which nodes the graph keeps lit, and
  // how strongly (by search rank).
  const { matches } = useGraphMatches();

  // Real documents only — phantoms are referenced-but-absent, not corpus size.
  // The provenance line prints BOTH numbers rather than picking one, because
  // they are different numbers and a caption that shows one owes the other.
  const docCount = useMemo(
    () => nodes.reduce((n, node) => (node.phantom ? n : n + 1), 0),
    [nodes],
  );

  const corpus: CorpusProvenance | null = useMemo(() => {
    if (!provenance) return null;
    return {
      nodeCount: nodes.length,
      docCount,
      truncated,
      truncationReason,
      upstreamStatus: provenance.upstreamStatus,
      upstreamReason: provenance.upstreamReason,
      apiConfigured: provenance.apiConfigured,
    };
  }, [provenance, nodes.length, docCount, truncated, truncationReason]);

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
      <div className="pointer-events-none absolute bottom-5 left-5 z-20 max-w-sm select-none">
        <p className="text-xs font-medium leading-relaxed text-foreground/75">
          Barkpark document graph
        </p>
        <p className="mt-1 text-[0.7rem] leading-relaxed text-muted-text">
          {matches
            ? `${matches.length} ${matches.length === 1 ? "match" : "matches"} from your search · brightest = best · click to read`
            : "Search on the left to filter · click a node to read"}
        </p>
        {corpus && provenance ? (
          <SiteProvenance build={provenance.build} corpus={corpus} />
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
