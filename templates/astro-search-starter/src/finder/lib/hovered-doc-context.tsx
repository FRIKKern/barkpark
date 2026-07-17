"use client";

import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useState,
  type ReactNode,
} from "react";

/**
 * Cross-surface link between the landing graph and the finder rail: hovering a
 * graph node publishes its doc-id here, and each finder ResultRow lights up when
 * its slug matches. One small context shared by both halves of the (finder)
 * layout. Safe by construction — the default value is a no-op, so any consumer
 * rendered outside the provider simply never highlights (no crash, no behavior
 * change). The hovered id is the published doc-id (== a finder hit's `slug`).
 */
interface HoveredDocValue {
  hoveredId: string | null;
  setHoveredId: (id: string | null) => void;
}

const HoveredDocContext = createContext<HoveredDocValue>({
  hoveredId: null,
  setHoveredId: () => {},
});

/**
 * One visible result, published from the finder to the graph: its doc-id (a hit
 * `slug`, matched against the graph node's `doc_id` — same key the hover bridge
 * uses) plus a `w`eight in (0..1] derived from its search rank (1 = top hit).
 * The graph scales each match's emphasis — dot size, accent warmth, label
 * prominence — by `w`, so the strongest results read loudest.
 */
export interface GraphMatch {
  id: string;
  w: number;
}

/**
 * The reverse channel: the finder publishes its currently-visible results (with
 * per-result weights), and the landing graph dims everything else so the two
 * halves read as a single instrument. `matches === null` means "no active
 * filter" (idle browse) — the graph shows the whole corpus, undimmed. Split from
 * the hovered-doc context on purpose: graph-node hover (frequent) must not
 * re-render the graph, and a result-set change must not re-render every result
 * row through the hover value.
 */
interface GraphMatchValue {
  matches: GraphMatch[] | null;
  setMatches: (matches: GraphMatch[] | null) => void;
}

const GraphMatchContext = createContext<GraphMatchValue>({
  matches: null,
  setMatches: () => {},
});

export function HoveredDocProvider({ children }: { children: ReactNode }) {
  const [hoveredId, setHoveredIdState] = useState<string | null>(null);
  // Stable setter so callers (the graph's onNodeHover) don't churn identity.
  const setHoveredId = useCallback((id: string | null) => {
    setHoveredIdState((prev) => (prev === id ? prev : id));
  }, []);
  const hoveredValue = useMemo(
    () => ({ hoveredId, setHoveredId }),
    [hoveredId, setHoveredId],
  );

  const [matches, setMatchesState] = useState<GraphMatch[] | null>(null);
  const setMatches = useCallback((next: GraphMatch[] | null) => {
    // Skip identical publishes so a re-render of the finder with the same
    // visible set + weights doesn't churn the graph's match effect.
    setMatchesState((prev) => {
      if (prev === next) return prev;
      if (prev && next && prev.length === next.length) {
        let same = true;
        for (let i = 0; i < next.length; i++) {
          if (prev[i].id !== next[i].id || prev[i].w !== next[i].w) {
            same = false;
            break;
          }
        }
        if (same) return prev;
      }
      return next;
    });
  }, []);
  const matchValue = useMemo(
    () => ({ matches, setMatches }),
    [matches, setMatches],
  );

  return (
    <HoveredDocContext.Provider value={hoveredValue}>
      <GraphMatchContext.Provider value={matchValue}>
        {children}
      </GraphMatchContext.Provider>
    </HoveredDocContext.Provider>
  );
}

export function useHoveredDoc(): HoveredDocValue {
  return useContext(HoveredDocContext);
}

export function useGraphMatches(): GraphMatchValue {
  return useContext(GraphMatchContext);
}
