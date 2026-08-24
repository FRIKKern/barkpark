// Corpus-graph normalization — the PURE half of the Next edition's `lib/graph.ts`
// (templates/search-starter), ported for the static bake: `graph.json.ts` runs
// this at BUILD so the shipped asset is already the exact
// `{nodes, edges, rootId, truncated, truncationReason}` shape `public/bp-graph.js`
// renders and `GraphPane` captions — the island does zero client-side massaging
// and inherits the same alias tolerance (id/node_id, doc_id/document_id, …) and
// the same root selection (highest degree, "barkpark" preferred) as the original
// landing. Keep the two in lockstep. React-free + dep-free: unit-tested by
// `graph-normalize.test.ts` via `node --test`.
import type { BuildIdentity } from './provenance.ts'

/** A graph node, exactly as `window.BarkparkGraphRenderer` expects it. */
export interface GraphNode {
  id: string
  /** Document id the node links to (used to build the reader href). */
  doc_id: string
  /** Document type (post | paper | sheet | …) — drives Full-color + the href. */
  type: string
  title: string
  /** A referenced-but-absent node (no document of its own) — never navigable. */
  phantom?: boolean
}

/** A graph edge, exactly as `window.BarkparkGraphRenderer` expects it. */
export interface GraphEdge {
  from_id: string
  to_id: string
  kind?: string
  weight?: number
}

/** The landing's full payload: nodes, edges, the chosen accent root, and
 * whether the server cut the corpus on its way here. */
export interface CorpusGraph {
  nodes: GraphNode[]
  edges: GraphEdge[]
  rootId: string | null
  /**
   * The server cut the corpus at a ceiling — the graph shown is a SUBSET, and
   * any caption must say so. Covers both server ceilings (the whole-graph node
   * budget and the 1000-docs-per-type cap), so `false` really means "complete".
   *
   * This field used to stop at the normalizer: `CorpusGraph` was
   * `{nodes, edges, rootId}` and `normalizeCorpusGraph` destructured only
   * `{nodes, edges}`, so the flag never reached the baked `graph.json` bytes —
   * which made a runtime fix impossible without re-baking, and left the static
   * edition presenting a capped count as if it were the corpus size. It is
   * carried end to end now: normalizer → `src/pages/graph.json.ts` → the asset
   * → `GraphPane`'s caption.
   */
  truncated: boolean
  /** Upstream `truncation_reason` ("node_budget", "per_type_cap",
   * "per_type_cap+node_budget"), null when the server named none. */
  truncationReason: string | null
}

/** The exact JSON `src/pages/graph.json.ts` bakes and `GraphPane` fetches: the
 * corpus plus the identity of the build that baked it, so the pane can state
 * which build produced what it is drawing without a second request. */
export interface BakedCorpus extends CorpusGraph {
  build: BuildIdentity
}

const PREFERRED_ROOT = 'barkpark'

function str(v: unknown): string | undefined {
  return typeof v === 'string' && v.length > 0 ? v : undefined
}

function num(v: unknown): number | undefined {
  return typeof v === 'number' && Number.isFinite(v) ? v : undefined
}

/** Normalise one raw upstream node — tolerant of field aliases so the landing
 * survives a minor API shape drift (id/node_id, doc_id/document_id, type/_type). */
export function normalizeNode(raw: unknown): GraphNode | null {
  if (!raw || typeof raw !== 'object') return null
  const n = raw as Record<string, unknown>
  const id = str(n.id) ?? str(n.node_id)
  if (!id) return null
  const docId = str(n.doc_id) ?? str(n.document_id) ?? str(n._id) ?? id
  const type = str(n.type) ?? str(n._type) ?? '_unknown'
  const title = str(n.title) ?? str(n.name) ?? id
  const phantom = n.phantom === true || n.phantom === 'true' || n.is_phantom === true
  return phantom
    ? { id, doc_id: docId, type, title, phantom: true }
    : { id, doc_id: docId, type, title }
}

/** Normalise one raw upstream edge — tolerant of from/from_id/source aliases. */
export function normalizeEdge(raw: unknown): GraphEdge | null {
  if (!raw || typeof raw !== 'object') return null
  const e = raw as Record<string, unknown>
  const from = str(e.from_id) ?? str(e.from) ?? str(e.source)
  const to = str(e.to_id) ?? str(e.to) ?? str(e.target)
  if (!from || !to) return null
  const kind = str(e.kind) ?? str(e.type)
  const weight = num(e.weight)
  const out: GraphEdge = { from_id: from, to_id: to }
  if (kind) out.kind = kind
  if (weight !== undefined) out.weight = weight
  return out
}

/** Root selection: highest total degree (in + out), PREFERRED_ROOT winning
 * outright when present. Degree comes from edges, never upstream ordering. */
export function computeRootId(nodes: GraphNode[], edges: GraphEdge[]): string | null {
  if (nodes.length === 0) return null
  const present = new Set(nodes.map((n) => n.id))
  if (present.has(PREFERRED_ROOT)) return PREFERRED_ROOT

  const degree = new Map<string, number>()
  for (const n of nodes) degree.set(n.id, 0)
  for (const e of edges) {
    if (present.has(e.from_id)) degree.set(e.from_id, (degree.get(e.from_id) ?? 0) + 1)
    if (present.has(e.to_id)) degree.set(e.to_id, (degree.get(e.to_id) ?? 0) + 1)
  }

  let best = nodes[0].id
  let bestDeg = degree.get(best) ?? 0
  for (const n of nodes) {
    const d = degree.get(n.id) ?? 0
    if (d > bestDeg) {
      best = n.id
      bestDeg = d
    }
  }
  return best
}

/**
 * The D67 gate, in one place: a `truncation_reason` is only a reason if the
 * server also said `truncated: true`. A reason on its own is an upstream shape
 * drift, and honouring it would let the pane announce a cut that never
 * happened. Strictly `=== true` so a drifted/absent flag degrades to the safe
 * "no claim" state rather than to a truthy string.
 */
export function readTruncation(raw: unknown): {
  truncated: boolean
  truncationReason: string | null
} {
  const u = (raw && typeof raw === 'object' ? raw : {}) as {
    truncated?: unknown
    truncation_reason?: unknown
    truncationReason?: unknown
  }
  const truncated = u.truncated === true
  if (!truncated) return { truncated: false, truncationReason: null }
  return {
    truncated: true,
    truncationReason: str(u.truncation_reason) ?? str(u.truncationReason) ?? null,
  }
}

/** Normalise a raw `/v1/graph` upstream payload into the renderer-ready shape. */
export function normalizeCorpusGraph(raw: unknown): CorpusGraph {
  const u = (raw && typeof raw === 'object' ? raw : {}) as {
    nodes?: unknown[]
    edges?: unknown[]
  }
  const nodes = (u.nodes ?? []).map(normalizeNode).filter((n): n is GraphNode => n !== null)
  const present = new Set(nodes.map((n) => n.id))
  // Drop edges whose endpoints are absent — the renderer draws them into nowhere.
  const edges = (u.edges ?? [])
    .map(normalizeEdge)
    .filter((e): e is GraphEdge => e !== null && present.has(e.from_id) && present.has(e.to_id))
  return { nodes, edges, rootId: computeRootId(nodes, edges), ...readTruncation(raw) }
}

/**
 * Mark nodes whose type is NOT prerendered as phantom — the STATIC edition's
 * navigability truth. The Next edition's `/d/[type]/[slug]` is a dynamic route
 * (any type renders on demand); this static site prerenders detail pages only
 * for the built doc type, so a click on any other type's node lands on a
 * missing page (live-caught: 999 task nodes 503'd). Phantom is exactly the
 * renderer's "referenced-but-absent — never navigable" semantics: the node
 * stays visible as corpus context (edges intact, phantom styling) but neither
 * `bp-graph.js` nor GraphPane will navigate it. The root is re-chosen from the
 * still-navigable nodes so the accent anchor is always a clickable document.
 *
 * Truncation rides through untouched: phantoming is a LOCAL navigability
 * decision and says nothing about whether the server cut the corpus, so
 * dropping the flag here would silently turn a capped graph into one the pane
 * reports as complete.
 */
export function markNonNavigable(g: CorpusGraph, navigableTypes: string[]): CorpusGraph {
  const ok = new Set(navigableTypes)
  const nodes = g.nodes.map((n) => (ok.has(n.type) || n.phantom ? n : { ...n, phantom: true }))
  const navigable = nodes.filter((n) => !n.phantom)
  const rootId =
    navigable.length > 0 ? computeRootId(navigable, g.edges) : computeRootId(nodes, g.edges)
  return {
    nodes,
    edges: g.edges,
    rootId,
    truncated: g.truncated,
    truncationReason: g.truncationReason,
  }
}
