// Bake the corpus graph at BUILD into a static asset the island fetches —
// instant landing, zero runtime tokens (the static-site edition of /v1/graph).
// NORMALIZED at bake (lib/graph-normalize — the static twin of the Next
// edition's lib/graph.ts): the shipped bytes are already the exact
// {nodes, edges, rootId} shape `public/bp-graph.js` renders, alias-tolerant of
// upstream drift and with the root (highest degree, "barkpark" preferred)
// chosen once here rather than per visitor.
import type { APIRoute } from 'astro'
import { env, graphCorpus } from '../lib/bp'
import { normalizeCorpusGraph, markNonNavigable } from '../lib/graph-normalize'

export const GET: APIRoute = async () => {
  // Non-built types become phantom (visible context, never navigable) — the
  // static site prerenders detail pages only for env.docType, and a click onto
  // a page that does not exist is worse than a non-clickable node.
  const corpus = markNonNavigable(normalizeCorpusGraph(await graphCorpus()), [env.docType])
  return new Response(JSON.stringify(corpus), {
    headers: { 'content-type': 'application/json' },
  })
}
