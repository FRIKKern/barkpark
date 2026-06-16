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
 * The reverse channel: the finder publishes the set of doc-ids currently
 * visible in its result list, and the landing graph dims everything else so the
 * two halves read as a single instrument. `matchIds === null` means "no active
 * filter" (idle browse) — the graph shows the whole corpus, undimmed. The ids
 * are finder hit `slug`s, which the graph matches against node `doc_id` (same
 * key the hover bridge uses). Split from the hovered-doc context on purpose:
 * graph-node hover (frequent) must not re-render the graph, and a result-set
 * change must not re-render every result row through the hover value.
 */
interface GraphMatchValue {
  matchIds: string[] | null;
  setMatchIds: (ids: string[] | null) => void;
}

const GraphMatchContext = createContext<GraphMatchValue>({
  matchIds: null,
  setMatchIds: () => {},
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

  const [matchIds, setMatchIdsState] = useState<string[] | null>(null);
  const setMatchIds = useCallback((ids: string[] | null) => {
    // Skip identical publishes so a re-render of the finder with the same
    // visible set doesn't churn the graph's match effect.
    setMatchIdsState((prev) => {
      if (prev === ids) return prev;
      if (prev && ids && prev.length === ids.length) {
        let same = true;
        for (let i = 0; i < ids.length; i++) {
          if (prev[i] !== ids[i]) {
            same = false;
            break;
          }
        }
        if (same) return prev;
      }
      return ids;
    });
  }, []);
  const matchValue = useMemo(
    () => ({ matchIds, setMatchIds }),
    [matchIds, setMatchIds],
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
