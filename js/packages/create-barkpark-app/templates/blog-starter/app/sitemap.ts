import type { MetadataRoute } from 'next'
import { getDocs } from '../lib/barkpark'
import { slugOf, type SlugValue } from '../lib/slug'

// Public site URL — set NEXT_PUBLIC_SITE_URL in production so the emitted URLs
// are absolute (search engines require it). Falls back to localhost in dev.
const SITE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? 'http://localhost:3000'

interface Post {
  _updatedAt?: string
  slug?: SlugValue
}
interface Author {
  _id: string
  _updatedAt?: string
}
interface Tag {
  _updatedAt?: string
  slug?: SlugValue
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
// or crawl degrades to a minimal single-entry sitemap (the home route) rather
// than breaking the build or serving a broken page. Mirrors the web demo's
// try/catch degrade-to-static contract.
export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  try {
    const [posts, authors, tags] = await Promise.all([
      getDocs<Post>('post'),
      getDocs<Author>('author'),
      getDocs<Tag>('tag'),
    ])

    return [
      { url: SITE_URL, lastModified: new Date() },
      ...posts
        .filter((p) => slugOf(p.slug))
        .map((p) => ({ url: `${SITE_URL}/posts/${slugOf(p.slug)!}`, lastModified: when(p._updatedAt) })),
      ...authors.map((a) => ({ url: `${SITE_URL}/authors/${a._id}`, lastModified: when(a._updatedAt) })),
      ...tags
        .filter((t) => slugOf(t.slug))
        .map((t) => ({ url: `${SITE_URL}/tags/${slugOf(t.slug)!}`, lastModified: when(t._updatedAt) })),
    ]
  } catch {
    // Upstream unavailable — still emit a valid sitemap of the home route.
    return [{ url: SITE_URL, lastModified: new Date() }]
  }
}
