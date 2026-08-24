// Bake the corpus graph at BUILD into a static asset the island fetches —
// instant landing, zero runtime tokens (the static-site edition of /v1/graph).
// NORMALIZED at bake (lib/graph-normalize — the static twin of the Next
// edition's lib/graph.ts): the shipped bytes are already the exact
// {nodes, edges, rootId} shape `public/bp-graph.js` renders, alias-tolerant of
// upstream drift and with the root (highest degree, "barkpark" preferred)
// chosen once here rather than per visitor.
//
// PLUS the two facts a static site has no other way to learn at runtime:
//
//   truncated / truncationReason — whether the SERVER cut this corpus, carried
//     verbatim out of the upstream payload. It stopped at the normalizer
//     before, so these bytes could not carry it and GraphPane could only ever
//     present a capped count as if it were the corpus size. There is no runtime
//     fix for that: the asset is the only thing the island ever reads.
//   build — which build baked these bytes (src/lib/bp.buildIdentity, with the
//     HEALTH sentinels resolved to null so an undeployed build reads as a state
//     rather than as a build named "dev"). The deployed site has no server to
//     ask, so a stale asset is invisible unless it says which build made it.
//
// No extra network call is added for either: both ride the corpus read that
// already happens here.
import type { APIRoute } from 'astro'
import { buildIdentity, env, graphCorpus } from '../lib/bp'
import { normalizeCorpusGraph, markNonNavigable } from '../lib/graph-normalize'
import type { BakedCorpus } from '../lib/graph-normalize'

export const GET: APIRoute = async () => {
  // Non-built types become phantom (visible context, never navigable) — the
  // static site prerenders detail pages only for env.docType, and a click onto
  // a page that does not exist is worse than a non-clickable node.
  const corpus = markNonNavigable(normalizeCorpusGraph(await graphCorpus()), [env.docType])
  const baked: BakedCorpus = { ...corpus, build: buildIdentity }
  return new Response(JSON.stringify(baked), {
    headers: { 'content-type': 'application/json' },
  })
}
