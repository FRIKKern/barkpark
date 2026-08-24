// Is the viewport at or above Tailwind's `md` breakpoint — RIGHT NOW, as a
// render-time value the React tree can branch on?
//
// WHY THIS EXISTS (search-template charter D79). index.astro hides the graph
// slot below `md` with CSS alone (`class="hidden … md:block"`), and hiding is
// not not-shipping. Measured in a real 390x844 emulation on the deployed
// flagship: `getComputedStyle('#bp-graph-slot').display` was literally `none`
// and the pane was invisible — while the page had still fetched bp-graph.js
// (140,221 B) and graph.json (436,769 B) = 576,990 B. The portal mounted
// GraphPane into the hidden element, and GraphPane's mount effect appended the
// renderer <script> to document.head. `display: none` stops PAINT. It does not
// stop a `document.createElement('script')` its subtree ran.
//
// The mechanism here is the one templates/search-starter/components/
// desktop-only.tsx already documents in code for the Next edition: gate the
// MOUNT on matchMedia, so the subtree — and therefore its effects — never runs
// below the breakpoint. Deliberately NOT imported from there: that is a
// different tree (a Next package, and byte-locked vendoring rules apply to
// src/finder/ only), so the astro edition carries its own small copy.
//
// `useSyncExternalStore` rather than `useState` + an effect: the store snapshot
// is read DURING render, so the very first client render already knows the
// width and a phone never has a frame in which the gated child is mounted.
// (This island is `client:only="react"`, so there is no SSR pass to diverge
// from — but the server snapshot is still supplied, and still `false`, so the
// hook stays correct if the island is ever hydrated instead.)
import { useSyncExternalStore } from 'react'

/**
 * Tailwind's `md` breakpoint. MUST stay in lockstep with the `md:block` on
 * `#bp-graph-slot` in src/pages/index.astro — if the CSS and this query
 * disagree, one width shows an empty box and the other renders a graph nobody
 * can see.
 */
const MD_QUERY = '(min-width: 768px)'

function subscribe(onChange: () => void): () => void {
  if (typeof window === 'undefined' || !window.matchMedia) return () => {}
  const mql = window.matchMedia(MD_QUERY)
  mql.addEventListener('change', onChange)
  return () => mql.removeEventListener('change', onChange)
}

const getClientSnapshot = (): boolean =>
  typeof window !== 'undefined' && !!window.matchMedia && window.matchMedia(MD_QUERY).matches

// Never `true` off the client: a gated subtree must be ABSENT from the first
// render, because the whole point is that its effects never run on a phone.
const getServerSnapshot = (): boolean => false

/**
 * `true` only once mounted on a viewport >= `md`. Re-evaluates on resize and
 * orientation change through the matchMedia listener, so crossing the
 * breakpoint re-renders the consumer — mounting the gated subtree on the way up
 * and unmounting it (running its effect cleanup) on the way down.
 */
export function useIsDesktop(): boolean {
  return useSyncExternalStore(subscribe, getClientSnapshot, getServerSnapshot)
}

export { MD_QUERY }
