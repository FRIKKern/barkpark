// The landing graph pane, Astro edition — the master split's right half
// (stw7-backlog-astro-graph-landing-reintegrate). The SAME zero-dependency
// Canvas2D renderer the Next edition drives (public/bp-graph.js, byte-identical
// mirror of templates/search-starter's copy) over the corpus BAKED at build
// into graph.json (already normalized to
// {nodes, edges, rootId, truncated, truncationReason, build} by
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
//
// THE CAPTION says what this pane is actually serving. It had none at all: no
// document count, no note that the server had capped the corpus, and no way to
// tell a graph.json that failed to load from a corpus that is genuinely empty —
// both painted the same empty canvas. Every value in it is READ: the counts and
// the truncation flags from the asset this pane just fetched, the build from
// the two `data-bp-*` attributes Base.astro bakes onto <body> (deliberately not
// from graph.json, so the caption can still name the build when the corpus
// asset is the thing that failed). `lib/provenance` shapes the words and is
// unit-pinned against the Next edition's identical strings.
//
// The caption sits BOTTOM-left, not top-left: the renderer owns top-left for
// its legend, and the overlay-corner contract (mirrored in bp-graph.js and
// documented in the Next edition's graph-landing.tsx) leaves the host exactly
// one free corner — bottom-left. The old top-left placement overlapped the
// legend, and these extra lines would have made that collision worse.
import { useEffect, useRef, useState } from 'react'
import { useGraphMatches, useHoveredDoc } from '../finder/lib/hovered-doc-context'
import type { GraphMatch } from '../finder/lib/hovered-doc-context'
import { withBase } from '../finder/shims/next-link'
import type { BakedCorpus, GraphNode, GraphEdge } from '../lib/graph-normalize'
import { readTruncation } from '../lib/graph-normalize'
import {
  buildIdentityLine,
  corpusProvenanceLine,
  type BuildIdentity,
  type CorpusProvenance,
} from '../lib/provenance'

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

/** No build stamped — the honest reading when the attributes are absent. */
const NO_BUILD: BuildIdentity = { buildId: null, contentRev: null }

/** One upstream message, bounded. A failed asset read can hand back a whole
 * parser dump; the caption is a status line, not a log. */
const REASON_MAX = 140

/** The build that baked this page, from the `data-bp-*` attributes Base.astro
 * writes. Empty attribute = not stamped, which is a STATE, not the value "dev"
 * (the <meta> HEALTH markers carry that sentinel and must keep carrying it). */
function domBuildIdentity(): BuildIdentity {
  const d = document.body?.dataset
  if (!d) return NO_BUILD
  return {
    buildId: (d.bpBuildId ?? '').trim() || null,
    contentRev: (d.bpContentRev ?? '').trim() || null,
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

/** Turn the baked asset into the caption's corpus input. Counts come from the
 * node array the renderer was just handed, so the number on screen and the
 * picture on screen are the same read. */
function corpusOf(corpus: BakedCorpus): CorpusProvenance {
  const nodes = corpus.nodes ?? []
  const docCount = nodes.reduce((n, node) => (node.phantom ? n : n + 1), 0)
  // Re-apply the D67 gate on the CLIENT as well as at bake: a reason emitted
  // without truncated:true is an upstream shape drift, and honouring it here
  // would let the pane announce a cut the server never made.
  const { truncated, truncationReason } = readTruncation(corpus)
  return {
    nodeCount: nodes.length,
    docCount,
    truncated,
    truncationReason,
    upstreamStatus: null,
    upstreamReason: null,
    // Always true on this edition: `src/lib/bp.required('BARKPARK_API_URL')`
    // throws at build, so an unconfigured astro site never produces bytes.
    apiConfigured: true,
  }
}

/** The asset could not be read. NOT an empty corpus — and the caption must not
 * let a visitor mistake one for the other. */
function unreadableCorpus(message: string): CorpusProvenance {
  const flat = message.replace(/\s+/g, ' ').trim()
  const why = flat.length > REASON_MAX ? `${flat.slice(0, REASON_MAX - 1)}…` : flat
  return {
    nodeCount: 0,
    docCount: 0,
    truncated: false,
    truncationReason: null,
    upstreamStatus: 0,
    upstreamReason: `graph.json 0: ${why}`,
    apiConfigured: true,
  }
}

export default function GraphPane() {
  const hostRef = useRef<HTMLDivElement>(null)
  const ctlRef = useRef<GraphController | null>(null)
  const { matches } = useGraphMatches()
  const { hoveredId, setHoveredId } = useHoveredDoc()
  // null until the asset has been read one way or the other — the caption
  // claims nothing it has not yet read.
  const [corpus, setCorpus] = useState<CorpusProvenance | null>(null)
  const [build, setBuild] = useState<BuildIdentity>(NO_BUILD)
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
    // Independent of the corpus read, and therefore still true when it fails.
    setBuild(domBuildIdentity())

    const boot = async () => {
      await loadRendererScript(base)
      const res = await fetch(base + 'graph.json')
      if (!res.ok) throw new Error(`graph.json returned ${res.status}`)
      const baked = (await res.json()) as BakedCorpus
      if (cancelled) return
      // The caption is set even if the host element has gone: the corpus WAS
      // read, and that fact is what the caption reports.
      setCorpus(corpusOf(baked))
      if (!hostRef.current || !window.BarkparkGraphRenderer) return
      const ctl = window.BarkparkGraphRenderer(
        hostRef.current,
        { nodes: baked.nodes ?? [], edges: baked.edges ?? [] },
        {
          // The Obsidian graph canvas is theme-INVARIANT dark, like the original.
          theme: 'dark',
          rootId: baked.rootId ?? null,
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

    boot().catch((e) => {
      console.error('[graph] pane failed to boot:', e)
      // A blank canvas with no explanation is the exact defect this caption
      // exists to remove: say the corpus could not be read, and say why.
      if (!cancelled) setCorpus(unreadableCorpus(e instanceof Error ? e.message : String(e)))
    })
    return () => {
      cancelled = true
      ctlRef.current?.destroy()
      ctlRef.current = null
    }
  }, [])

  const line = corpus ? corpusProvenanceLine(corpus) : null

  return (
    <div className="relative h-full w-full" style={{ background: '#0b0d10' }}>
      <div className="pointer-events-none absolute bottom-5 left-5 z-20 max-w-sm select-none">
        <p className="text-xs font-medium leading-relaxed text-zinc-400">
          The corpus, as a graph. Search on the left to light up matches; click a
          node to open its document.
        </p>
        {line ? (
          <div className="mt-1.5" data-bp-provenance={line.state}>
            <p className="text-[0.7rem] leading-relaxed text-zinc-500">{line.text}</p>
            <p className="mt-0.5 text-[0.7rem] leading-relaxed text-zinc-500">
              {buildIdentityLine(build)}
            </p>
          </div>
        ) : null}
      </div>
      <div ref={hostRef} style={{ position: 'absolute', inset: 0 }} aria-label="Corpus graph" />
    </div>
  )
}
