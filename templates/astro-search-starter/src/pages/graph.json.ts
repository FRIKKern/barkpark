// Bake the corpus graph at BUILD into a static asset the island fetches —
// instant landing, zero runtime tokens (the static-site edition of /v1/graph).
// NORMALIZED at bake (lib/graph-normalize — the static twin of the Next
// edition's lib/graph.ts): the shipped bytes are already the exact
// {nodes, edges, rootId} shape `public/bp-graph.js` renders, alias-tolerant of
// upstream drift and with the root (highest degree, "barkpark" preferred)
// chosen once here rather than per visitor.
import type { APIRoute } from 'astro'
import { graphCorpus } from '../lib/bp'
import { normalizeCorpusGraph } from '../lib/graph-normalize'

export const GET: APIRoute = async () => {
  const corpus = normalizeCorpusGraph(await graphCorpus())
  return new Response(JSON.stringify(corpus), {
    headers: { 'content-type': 'application/json' },
  })
}
