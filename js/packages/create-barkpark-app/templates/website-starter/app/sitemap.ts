import type { MetadataRoute } from 'next'
import { getDocs } from '../lib/barkpark'

// Public site URL — set NEXT_PUBLIC_SITE_URL in production so the emitted URLs
// are absolute (search engines require it). Falls back to localhost in dev.
const SITE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? 'http://localhost:3000'

interface Post {
  _updatedAt?: string
  slug?: { current: string }
}

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const posts = await getDocs<Post>('post')

  const staticRoutes = ['', '/about', '/pricing', '/contact'].map((path) => ({
    url: `${SITE_URL}${path}`,
    lastModified: new Date(),
  }))

  const postRoutes = posts
    .filter((p) => p.slug?.current)
    .map((p) => ({
      url: `${SITE_URL}/posts/${p.slug!.current}`,
      lastModified: p._updatedAt ? new Date(p._updatedAt) : undefined,
    }))

  return [...staticRoutes, ...postRoutes]
}
