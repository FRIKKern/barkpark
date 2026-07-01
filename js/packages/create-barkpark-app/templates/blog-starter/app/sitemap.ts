import type { MetadataRoute } from 'next'
import { getDocs } from '../lib/barkpark'

// Public site URL — set NEXT_PUBLIC_SITE_URL in production so the emitted URLs
// are absolute (search engines require it). Falls back to localhost in dev.
const SITE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? 'http://localhost:3000'

interface Post {
  _updatedAt?: string
  slug?: { current: string }
}
interface Author {
  _id: string
  _updatedAt?: string
}
interface Tag {
  _updatedAt?: string
  slug?: { current: string }
}

const when = (iso?: string): Date | undefined => (iso ? new Date(iso) : undefined)

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const [posts, authors, tags] = await Promise.all([
    getDocs<Post>('post'),
    getDocs<Author>('author'),
    getDocs<Tag>('tag'),
  ])

  return [
    { url: SITE_URL, lastModified: new Date() },
    ...posts
      .filter((p) => p.slug?.current)
      .map((p) => ({ url: `${SITE_URL}/posts/${p.slug!.current}`, lastModified: when(p._updatedAt) })),
    ...authors.map((a) => ({ url: `${SITE_URL}/authors/${a._id}`, lastModified: when(a._updatedAt) })),
    ...tags
      .filter((t) => t.slug?.current)
      .map((t) => ({ url: `${SITE_URL}/tags/${t.slug!.current}`, lastModified: when(t._updatedAt) })),
  ]
}
