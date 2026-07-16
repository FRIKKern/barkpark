// Bake the corpus graph at BUILD into a static asset the island fetches —
// instant landing, zero runtime tokens (the static-site edition of /v1/graph).
import type { APIRoute } from 'astro'
import { graphCorpus } from '../lib/bp'

export const GET: APIRoute = async () => {
  const corpus = await graphCorpus()
  return new Response(JSON.stringify(corpus), {
    headers: { 'content-type': 'application/json' },
  })
}
