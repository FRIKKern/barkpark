"use client";

import { useEffect, useMemo, useRef } from "react";
import Script from "next/script";
import type { GraphNode, GraphEdge } from "@/lib/graph";
import type { GraphMatch } from "@/lib/hovered-doc-context";

/* ── renderer contract (mirrors public/bp-graph.js public surface) ──────── */

/** Options accepted by `window.BarkparkGraphRenderer`. Only the subset we use. */
interface GraphRendererOpts {
  theme?: "dark" | "light" | "auto";
  rootId?: string | null;
  fullColor?: boolean;
  flow?: boolean;
  reducedMotion?: boolean;
  /** Suppress the renderer's own in-canvas search box — the host (finder) owns
   * search and drives the graph via `setMatches`. */
  externalSearch?: boolean;
  onNodeClick?: (node: GraphNode) => void;
  onNodeHover?: (node: GraphNode | null) => void;
}

/** The controller `window.BarkparkGraphRenderer(...)` returns. */
interface GraphController {
  update: (
    nodes: GraphNode[],
    edges: GraphEdge[],
    opts?: { rootId?: string | null },
  ) => void;
  fit: () => void;
  setError: (on: boolean) => void;
  setFetching: (on: boolean) => void;
  /** Emphasize each match by weight and dim the rest; `null` clears the filter. */
  setMatches: (matches: GraphMatch[] | null) => void;
  /** Focus the node whose `doc_id` matches (same hop-cascade as a real hover);
   * `null` clears it. Drives the list→graph half of the hover bridge. */
  setHovered: (docId: string | null) => void;
  destroy: () => void;
}

type GraphRendererFactory = (
  container: HTMLElement,
  data: { nodes: GraphNode[]; edges: GraphEdge[] },
  opts?: GraphRendererOpts,
) => GraphController;

declare global {
  interface Window {
    BarkparkGraphRenderer?: GraphRendererFactory;
  }
}

/* ── props ──────────────────────────────────────────────────────────────── */

export interface GraphViewProps {
  nodes: GraphNode[];
  edges: GraphEdge[];
  /** Accent / anchor node id — the highest-degree node, per lib/graph. */
  rootId?: string | null;
  /** Forwarded to the renderer — a node was clicked (phantoms never fire). */
  onNodeClick?: (node: GraphNode) => void;
  /** Forwarded to the renderer — hover entered a node, or null on leave. */
  onNodeHover?: (node: GraphNode | null) => void;
  /** The host finder's visible results with per-result score weights — the graph
   * keeps these lit (size/color/label scaled by weight) and dims the rest.
   * `null`/undefined = no filter (full graph). */
  matches?: GraphMatch[] | null;
  /** Doc-id currently hovered elsewhere (a finder result row). The graph focuses
   * the matching node with the same cascade as an in-canvas hover. `null` = none. */
  hoveredId?: string | null;
  /** Extra classes on the host div. It is always `relative` + full-size. */
  className?: string;
}

/**
 * Thin React wrapper over the self-contained vanilla Canvas2D renderer at
 * `public/bp-graph.js`. The renderer creates its OWN `<canvas>` inside the host
 * div (which therefore needs a real height and a relative position — both set
 * here), owns one rAF loop, and ships its own Obsidian-style search box + hover
 * hop-cascade. We never touch the canvas; we only construct/destroy/update the
 * controller and forward node click/hover out as React callbacks.
 *
 * The script-load race is handled both ways:
 *   • script loads BEFORE mount → `onReady` fires, but the host is already in
 *     the DOM, so init runs immediately when the effect reads `window.BGR`.
 *   • script loads AFTER mount  → the effect polls `window.BarkparkGraphRenderer`
 *     until it appears (and `onReady`/`onLoad` flips a ref to stop early), then
 *     constructs.
 * Either way init runs exactly once per mount; the prop-change effect only
 * `update()`s an existing controller.
 */
export function GraphView({
  nodes,
  edges,
  rootId = null,
  onNodeClick,
  onNodeHover,
  matches = null,
  hoveredId = null,
  className,
}: GraphViewProps) {
  const hostRef = useRef<HTMLDivElement | null>(null);
  const ctlRef = useRef<GraphController | null>(null);
  // Latest match set in a ref so init (which may run after a script-load poll)
  // can stamp the current filter the moment the controller exists.
  const matchRef = useRef<GraphMatch[] | null>(matches);
  /** Flipped true once the script reports ready (load/ready handler). Lets the
   * init effect short-circuit its poll the moment the factory is guaranteed. */
  const scriptReadyRef = useRef(false);

  // Latest callbacks in a ref so the renderer's long-lived closures always call
  // the current handler without us re-constructing the renderer on every render.
  // Synced in an effect (not during render) — refs are write-only post-commit.
  const clickRef = useRef(onNodeClick);
  const hoverRef = useRef(onNodeHover);
  useEffect(() => {
    clickRef.current = onNodeClick;
    hoverRef.current = onNodeHover;
  }, [onNodeClick, onNodeHover]);

  // INIT — construct the controller once the factory exists AND the host is
  // mounted. Polls for the factory to cover the "script loads after mount" race.
  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;

    let cancelled = false;
    let pollId: ReturnType<typeof setInterval> | null = null;

    const init = () => {
      if (cancelled || ctlRef.current) return false;
      const factory = window.BarkparkGraphRenderer;
      if (!factory) return false;
      ctlRef.current = factory(
        host,
        { nodes, edges },
        {
          theme: "dark",
          fullColor: false,
          rootId,
          externalSearch: true,
          onNodeClick: (node) => clickRef.current?.(node),
          onNodeHover: (node) => hoverRef.current?.(node),
        },
      );
      // Stamp any filter that was already active before the script finished
      // loading (the host could have searched during the load poll window).
      if (matchRef.current) ctlRef.current.setMatches(matchRef.current);
      return true;
    };

    // Try immediately (script may already be present), else poll until it lands.
    if (!init()) {
      pollId = setInterval(() => {
        if (scriptReadyRef.current || window.BarkparkGraphRenderer) {
          if (init() && pollId) {
            clearInterval(pollId);
            pollId = null;
          }
        }
      }, 60);
    }

    return () => {
      cancelled = true;
      if (pollId) clearInterval(pollId);
      ctlRef.current?.destroy();
      ctlRef.current = null;
    };
    // Construct ONCE per mount. Data + root changes are handled by the update
    // effect below (re-running this would tear down and re-layout the graph).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // A CONTENT signature of the graph topology. The server page re-renders on
  // every search navigation (it doesn't read the query, but App Router re-runs it
  // anyway), handing us fresh-but-identical `nodes`/`edges` arrays each time. The
  // UPDATE effect below keys on this signature, NOT array identity — so a search
  // that doesn't change the corpus never re-ingests + reheats the sim (which read
  // as the whole layout re-animating between searches). Only a real topology
  // change (navigating to a different corpus/root) fires update().
  const topoSig = useMemo(
    () =>
      String(rootId) +
      "|" +
      nodes.map((n) => n.id).join(",") +
      "|" +
      edges.map((e) => e.from_id + ">" + e.to_id).join(","),
    [nodes, edges, rootId],
  );
  // Seed the ref with the MOUNT signature so the first effect run is a no-op:
  // init() already ingested this exact data, and re-calling update() would reheat.
  const lastTopoSigRef = useRef<string>(topoSig);

  // UPDATE — push genuinely-new nodes/edges/root into the live controller (no
  // remount, so positions morph rather than re-seeding). Guarded by topoSig so
  // identical-content re-renders are ignored. No-op until init has run.
  useEffect(() => {
    if (lastTopoSigRef.current === topoSig) return;
    lastTopoSigRef.current = topoSig;
    ctlRef.current?.update(nodes, edges, { rootId });
    // nodes/edges/rootId are read inside but the guard is topoSig; they move in
    // lockstep with it, so depending on topoSig alone is correct and intended.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [topoSig]);

  // MATCHES — the finder's visible set drives which nodes stay lit and how
  // strongly. Keep the ref current (for the init-race stamp) and push into the
  // live controller.
  useEffect(() => {
    matchRef.current = matches;
    ctlRef.current?.setMatches(matches);
  }, [matches]);

  // HOVER (list → graph) — a finder result row published a hovered doc-id; focus
  // the matching node. No-op until init; hover is transient so a miss during the
  // script-load race just means focus appears on the next hover. The reverse
  // direction (graph node hover → finder row) flows out via onNodeHover.
  useEffect(() => {
    ctlRef.current?.setHovered(hoveredId);
  }, [hoveredId]);

  return (
    <>
      <Script
        src="/bp-graph.js"
        strategy="afterInteractive"
        onReady={() => {
          scriptReadyRef.current = true;
        }}
        onLoad={() => {
          scriptReadyRef.current = true;
        }}
      />
      <div
        ref={hostRef}
        // The renderer injects an absolutely-positioned canvas filling this box,
        // so it needs `relative` + a real height. The parent gives it height;
        // min-h is a floor so it never collapses to 0 during layout.
        className={`relative h-full w-full min-h-[20rem] ${className ?? ""}`}
      />
    </>
  );
}
