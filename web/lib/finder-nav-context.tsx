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
 * The keyboard bridge between the two route segments of the (finder) layout:
 * <Finder> (Search + Facets + List, left rail) and the Document detail pane
 * ({children}, right). They are separate segments, so a shared context is the
 * only clean channel — mirrors HoveredDocProvider, mounted right beside it.
 *
 * Navigation is a 2-D grid driven by roving DOM focus:
 *
 *        SEARCH (top, spans width)
 *      ↑↓        ↑↓          ↑↓
 *   FACETS  ←→  LIST   ←→  DOCUMENT
 *
 * The left grid (Search/Facets/List) lives entirely inside <Finder> and is
 * handled there. This context carries only the two CROSS-segment hops:
 *   • List → Document  (→/Enter opens a doc): Finder bumps `docFocusNonce`; the
 *     document layer takes whole-doc focus.
 *   • Document → List   (← from whole-doc):    the doc layer bumps
 *     `listFocusNonce`; Finder refocuses its active result row.
 * Nonces (monotonic counters), not booleans — every request re-fires the
 * consumer's effect even when the value would otherwise be unchanged.
 */
interface FinderNavValue {
  /** Bumped when the list opens a doc via keyboard → the doc pane takes focus. */
  docFocusNonce: number;
  requestDocFocus: () => void;
  /** Bumped when the doc pane hands focus back → the list refocuses its row. */
  listFocusNonce: number;
  requestListFocus: () => void;
}

const FinderNavContext = createContext<FinderNavValue>({
  docFocusNonce: 0,
  requestDocFocus: () => {},
  listFocusNonce: 0,
  requestListFocus: () => {},
});

export function FinderNavProvider({ children }: { children: ReactNode }) {
  const [docFocusNonce, setDoc] = useState(0);
  const [listFocusNonce, setList] = useState(0);
  const requestDocFocus = useCallback(() => setDoc((n) => n + 1), []);
  const requestListFocus = useCallback(() => setList((n) => n + 1), []);
  const value = useMemo(
    () => ({ docFocusNonce, requestDocFocus, listFocusNonce, requestListFocus }),
    [docFocusNonce, requestDocFocus, listFocusNonce, requestListFocus],
  );
  return (
    <FinderNavContext.Provider value={value}>
      {children}
    </FinderNavContext.Provider>
  );
}

export function useFinderNav(): FinderNavValue {
  return useContext(FinderNavContext);
}
