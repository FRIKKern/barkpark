import 'server-only'
import { BarkparkNotFoundError, makeFilterExpression } from '@barkpark/core'
import { createBarkparkServer } from '@barkpark/nextjs/server'
import { barkparkClient } from '../barkpark.config'
import { resolveServerToken } from './resolve-server-token'
import { slugOf, type SlugValue } from './slug'

// Envelope shapes returned by the /v1/data endpoints. `result.count` is the
// number of documents IN THIS PAGE, not the corpus total — the total comes
// back as `result.total`, and only when the query asks `?count=true`.
export interface QueryResult<T> {
  count: number
  offset: number
  limit: number
  perspective: string
  documents: T[]
  /** The server's own truncation answer: true when rows exist past this page. */
  hasMore?: boolean
}

export interface DocEnvelope<T> {
  result: T | null
  schemaHash?: string
  etag?: string
  ms?: number
  syncTags?: string[]
}

export interface QueryEnvelope<T> {
  result: QueryResult<T>
  schemaHash?: string
  etag?: string
  ms?: number
  syncTags?: string[]
}

// One server instance for the whole app. `barkparkFetch` owns URL building,
// the cache tags (derived from the SDK's shared `formatTagPrefix`, so the tags
// we READ with are the exact ones the webhook `revalidateBarkpark` WRITES —
// including the scoped `bp:ws:…:p:…:ds:…` grammar when a workspace+project are
// configured), and the draft path (`cache: 'no-store'` whenever Next.js
// `draftMode()` is on). Every helper below delegates to it — do NOT hand-roll
// `fetch` here or the read/write cache tags drift and revalidation silently
// no-ops (permanent stale content).
const { barkparkFetch } = createBarkparkServer({
  client: barkparkClient,
  serverToken: resolveServerToken(process.env),
})

export async function getDocs<T>(type: string, opts: { order?: string } = {}): Promise<T[]> {
  const env = await barkparkFetch<QueryEnvelope<T>>({
    type,
    ...(opts.order !== undefined ? { query: { filters: [], order: opts.order } } : {}),
  })
  return env.result?.documents ?? []
}

// "Latest posts" order: newest publishedAt first, creation time as the tie-break
// so offset paging is stable. Without an explicit order the query route answers
// `_updatedAt desc`, so fixing a typo in an old post moved it to the top of the
// home page. Postgres sorts DESC with NULLS FIRST, so a post with no publishedAt
// yet leads the list instead of disappearing from it.
export const POST_ORDER = 'publishedAt:desc,_createdAt:desc'

// The sitemap protocol's per-file URL cap.
export const SITEMAP_MAX_URLS = 50_000

/**
 * EVERY document of a type, page by page — for the sitemap. `getDocs` reads one
 * page (the query route's default is 100 rows) and its envelope's `hasMore` was
 * never read, so a site with 101+ posts published a sitemap that silently left
 * the rest out. This follows `hasMore` with the route's largest page (1000)
 * until the type is exhausted or the sitemap cap is reached.
 */
export async function getAllDocs<T>(type: string): Promise<T[]> {
  const out: T[] = []
  let offset = 0
  while (out.length < SITEMAP_MAX_URLS) {
    const env = await barkparkFetch<QueryEnvelope<T>>({
      type,
      query: { filters: [], limit: 1000, offset },
    })
    const page = env.result?.documents ?? []
    out.push(...page)
    if (!env.result?.hasMore || page.length === 0) break
    offset += page.length
  }
  return out.slice(0, SITEMAP_MAX_URLS)
}

export async function getDoc<T>(type: string, id: string): Promise<T | null> {
  try {
    const env = await barkparkFetch<DocEnvelope<T>>({ type, id })
    return env.result
  } catch (err) {
    // A by-id miss is a 404, not a 500. `barkparkFetch` throws
    // BarkparkNotFoundError on a 404, but that error carries no NEXT_NOT_FOUND
    // digest, so an uncaught throw makes App Router render error.tsx (500) —
    // leaving every `if (!doc) notFound()` guard downstream dead code. Swallow
    // to null so the caller's not-found path fires (404). Symmetric with
    // getDocBySlug (a filtered miss returns null) and the SDK's client.doc
    // 404→null convention (@barkpark/core doc.ts). Rethrow everything else.
    if (err instanceof BarkparkNotFoundError) return null
    throw err
  }
}

export async function getDocBySlug<T>(type: string, slug: string): Promise<T | null> {
  // A slug is stored as `{current}` (the seeds) OR a plain string (the Studio's
  // Generate). Filter server-side on each path in turn, then match client-side
  // through slugOf as a safety net so we never return the wrong document.
  for (const path of ['slug.current', 'slug']) {
    const env = await barkparkFetch<QueryEnvelope<T>>({
      type,
      query: { filters: [makeFilterExpression(path, 'eq', slug)] },
    })
    const hit = (env.result?.documents ?? []).find(
      (d) => slugOf((d as { slug?: SlugValue }).slug) === slug,
    )
    if (hit) return hit
  }
  // A document with NO slug is linked by its _id (every list page renders
  // `slugOf(doc.slug) ?? doc._id`), so resolve that key by id. A slugged
  // document is NOT resolved this way: it keeps exactly one URL, and an id can
  // never shadow another document's slug (task-4446ac10d3e23182).
  const byId = await getDoc<T>(type, slug)
  return byId && slugOf((byId as { slug?: SlugValue }).slug) === undefined ? byId : null
}
