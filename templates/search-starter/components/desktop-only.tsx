"use client";

import { useSyncExternalStore } from "react";

/**
 * Tailwind's `md` breakpoint (768px) — the width above which the finder's
 * desktop-only landings (the docs graph / the listings map) are shown. Kept in
 * lockstep with the `md:` classes that hide the mobile fallback.
 */
const MD_QUERY = "(min-width: 768px)";

function subscribe(onChange: () => void) {
  const mql = window.matchMedia(MD_QUERY);
  mql.addEventListener("change", onChange);
  return () => mql.removeEventListener("change", onChange);
}

// Client reads the live match; the server snapshot is always `false`. Because
// `useSyncExternalStore` uses the server snapshot for SSR *and* the first
// hydration render, the desktop-only child is absent from the initial HTML and
// the first client render alike — they agree, so there is no hydration
// mismatch. Immediately after hydration React re-reads the client snapshot and
// mounts the child on wide screens.
const getClientSnapshot = () => window.matchMedia(MD_QUERY).matches;
const getServerSnapshot = () => false;

/**
 * `true` once mounted on a viewport ≥ `md`. Re-evaluates on resize / orientation
 * change via a matchMedia listener, so crossing the breakpoint re-renders the
 * consumer — mounting or unmounting the gated subtree cleanly.
 */
export function useIsDesktop() {
  return useSyncExternalStore(subscribe, getClientSnapshot, getServerSnapshot);
}

/**
 * Renders `children` only on viewports ≥ `md`, and only on the client. Below
 * `md` — and during SSR / the first hydration render — it renders null, so a
 * gated subtree's side effects never run on phones where the landing is hidden
 * anyway. The motivating case: `<GraphView>` mounts `<Script src="/bp-graph.js">`
 * (~131 KB); CSS `display:none` does NOT stop that script from downloading and
 * executing, but never mounting it does. On a breakpoint change the gate mounts
 * the child (desktop) or unmounts it — GraphView's effect cleanup tears the
 * renderer down — with no SSR/client divergence.
 */
export function DesktopOnly({ children }: { children: React.ReactNode }) {
  return useIsDesktop() ? <>{children}</> : null;
}
