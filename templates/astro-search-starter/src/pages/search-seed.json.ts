// Bake the finder's first-paint browse landing + prefix seed at BUILD into a
// static asset the island fetches — instant browse on first frame, zero runtime
// tokens (the static-site edition of the Next finder's force-dynamic layout
// seed). A static Astro host has no per-request SSR, so this is where it lives.
import type { APIRoute } from 'astro'
import { browseSeed } from '../lib/bp'

export const GET: APIRoute = async () => {
  const seed = await browseSeed()
  return new Response(JSON.stringify(seed), {
    headers: { 'content-type': 'application/json' },
  })
}
