import type { MetadataRoute } from 'next'
import { getDocs } from '../lib/barkpark'

// Public site URL — set NEXT_PUBLIC_SITE_URL in production so the emitted URLs
// are absolute (search engines require it). Falls back to localhost in dev.
const SITE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? 'http://localhost:3000'

interface Post {
  _updatedAt?: string
  slug?: { current: string }
}

// Parse an ISO timestamp into a Date, or undefined when absent OR unparseable.
// A malformed `_updatedAt` would otherwise yield an Invalid Date, which Next
// serializes via `.toISOString()` — a RangeError that crashes the whole route.
const when = (iso?: string): Date | undefined => {
  if (!iso) return undefined
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? undefined : d
}

// Sitemap generation NEVER throws: an API 500 / network / timeout during build
// or crawl degrades to the static routes rather than breaking the build or
// serving a broken page. Mirrors the web demo's try/catch degrade-to-static
// contract.
export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const staticRoutes = ['', '/about', '/pricing', '/contact'].map((path) => ({
    url: `${SITE_URL}${path}`,
    lastModified: new Date(),
  }))

  try {
    const posts = await getDocs<Post>('post')

    const postRoutes = posts
      .filter((p) => p.slug?.current)
      .map((p) => ({
        url: `${SITE_URL}/posts/${p.slug!.current}`,
        lastModified: when(p._updatedAt),
      }))

    return [...staticRoutes, ...postRoutes]
  } catch {
    // Upstream unavailable — still emit a valid sitemap of the static routes.
    return staticRoutes
  }
}
