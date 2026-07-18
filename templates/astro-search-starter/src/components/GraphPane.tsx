// The landing graph pane, Astro edition — the master split's right half
// (stw7-backlog-astro-graph-landing-reintegrate). The SAME zero-dependency
// Canvas2D renderer the Next edition drives (public/bp-graph.js, byte-identical
// mirror of templates/search-starter's copy) over the corpus BAKED at build
// into graph.json (already normalized to {nodes, edges, rootId} by
// lib/graph-normalize — the static twin of the Next edition's lib/graph.ts).
//
// The finder↔graph bridge is the point: this pane lives in the SAME React root
// as the Finder (one island — two islands would be two roots with two separate
// contexts and no bridge), so
//   • useGraphMatches().matches → ctl.setMatches — per keystroke the finder
//     publishes its weighted result set and the graph lights those nodes by
//     rank and dims the rest;
//   • useHoveredDoc() two-way — hovering a finder row focuses the node
//     (ctl.setHovered), hovering a node highlights the finder row.
//
// One deliberate divergence from the Next GraphLanding: node clicks navigate
// with a REAL page load (window.location) instead of router.push — the astro
// next-navigation shim's push is a pushState (in-island URL state), and a
// static site's /d/<type>/<slug> pages are separate prerendered documents. The
// live finder query string is carried onto the href the same way the result
// rows do it. Renders in the always-dark Obsidian aesthetic the original
// landing pins (theme-invariant by design).
import { useEffect, useRef } from 'react'
import { useGraphMatches, useHoveredDoc } from '../finder/lib/hovered-doc-context'
import type { GraphMatch } from '../finder/lib/hovered-doc-context'
import { withBase } from '../finder/shims/next-link'
import type { CorpusGraph, GraphNode, GraphEdge } from '../lib/graph-normalize'

/** The controller `window.BarkparkGraphRenderer(...)` returns (subset we use —
 * mirrors templates/search-starter/components/graph-view.tsx). */
interface GraphController {
  update: (nodes: GraphNode[], edges: GraphEdge[], opts?: { rootId?: string | null }) => void
  setMatches: (matches: GraphMatch[] | null) => void
  setHovered: (docId: string | null) => void
  destroy: () => void
}

type GraphRendererFactory = (
  container: HTMLElement,
  data: { nodes: GraphNode[]; edges: GraphEdge[] },
  opts?: Record<string, unknown>,
) => GraphController

declare global {
  interface Window {
    BarkparkGraphRenderer?: GraphRendererFactory
  }
}

function loadRendererScript(base: string): Promise<void> {
  if (window.BarkparkGraphRenderer) return Promise.resolve()
  return new Promise((resolve, reject) => {
    const s = document.createElement('script')
    s.src = base + 'bp-graph.js'
    s.onload = () => resolve()
    s.onerror = () => reject(new Error('bp-graph.js failed to load'))
    document.head.appendChild(s)
  })
}

export default function GraphPane() {
  const hostRef = useRef<HTMLDivElement>(null)
  const ctlRef = useRef<GraphController | null>(null)
  const { matches } = useGraphMatches()
  const { hoveredId, setHoveredId } = useHoveredDoc()
  // Latest matches/hover in refs so init (which resolves async) can stamp the
  // current state the moment the controller exists — and so the renderer's
  // long-lived callbacks never close over stale setters.
  const matchesRef = useRef<GraphMatch[] | null>(matches)
  const setHoveredIdRef = useRef(setHoveredId)

  useEffect(() => {
    matchesRef.current = matches
    ctlRef.current?.setMatches(matches)
  }, [matches])

  useEffect(() => {
    setHoveredIdRef.current = setHoveredId
  }, [setHoveredId])

  // List → graph half of the hover bridge.
  useEffect(() => {
    ctlRef.current?.setHovered(hoveredId)
  }, [hoveredId])

  useEffect(() => {
    let cancelled = false
    const base = (import.meta.env.BASE_URL || '/').replace(/\/?$/, '/')

    const boot = async () => {
      await loadRendererScript(base)
      const corpus = (await fetch(base + 'graph.json').then((r) => r.json())) as CorpusGraph
      if (cancelled || !hostRef.current || !window.BarkparkGraphRenderer) return
      const ctl = window.BarkparkGraphRenderer(
        hostRef.current,
        { nodes: corpus.nodes ?? [], edges: corpus.edges ?? [] },
        {
          // The Obsidian graph canvas is theme-INVARIANT dark, like the original.
          theme: 'dark',
          rootId: corpus.rootId ?? null,
          // The finder owns search; suppress the renderer's in-canvas box.
          externalSearch: true,
          onNodeClick: (node: GraphNode) => {
            // Phantoms are referenced-but-absent — nothing to open.
            if (node.phantom || !node.doc_id || !node.type) return
            const qs = window.location.search
            window.location.assign(withBase(`/d/${node.type}/${node.doc_id}`) + qs)
          },
          onNodeHover: (node: GraphNode | null) => {
            setHoveredIdRef.current(node && !node.phantom && node.doc_id ? node.doc_id : null)
          },
        },
      )
      ctlRef.current = ctl
      if (matchesRef.current) ctl.setMatches(matchesRef.current)
    }

    boot().catch((e) => console.error('[graph] pane failed to boot:', e))
    return () => {
      cancelled = true
      ctlRef.current?.destroy()
      ctlRef.current = null
    }
  }, [])

  return (
    <div className="relative h-full w-full" style={{ background: '#0b0d10' }}>
      <div className="pointer-events-none absolute left-5 top-5 z-20 max-w-xs select-none">
        <p className="text-xs font-medium leading-relaxed text-zinc-400">
          The corpus, as a graph. Search on the left to light up matches; click a
          node to open its document.
        </p>
      </div>
      <div ref={hostRef} style={{ position: 'absolute', inset: 0 }} aria-label="Corpus graph" />
    </div>
  )
}
