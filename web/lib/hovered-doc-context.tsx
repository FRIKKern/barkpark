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

export function HoveredDocProvider({ children }: { children: ReactNode }) {
  const [hoveredId, setHoveredIdState] = useState<string | null>(null);
  // Stable setter so callers (the graph's onNodeHover) don't churn identity.
  const setHoveredId = useCallback((id: string | null) => {
    setHoveredIdState((prev) => (prev === id ? prev : id));
  }, []);
  const value = useMemo(
    () => ({ hoveredId, setHoveredId }),
    [hoveredId, setHoveredId],
  );
  return (
    <HoveredDocContext.Provider value={value}>
      {children}
    </HoveredDocContext.Provider>
  );
}

export function useHoveredDoc(): HoveredDocValue {
  return useContext(HoveredDocContext);
}
