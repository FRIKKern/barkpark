import 'server-only'
import { BarkparkNotFoundError, makeFilterExpression, type Perspective } from '@barkpark/core'
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

export async function getDocs<T>(
  type: string,
  opts: { limit?: number; offset?: number; perspective?: string; order?: string } = {},
): Promise<T[]> {
  const env = await barkparkFetch<QueryEnvelope<T>>({
    type,
    query: {
      filters: [],
      ...(opts.limit !== undefined ? { limit: opts.limit } : {}),
      ...(opts.offset !== undefined ? { offset: opts.offset } : {}),
      ...(opts.order !== undefined ? { order: opts.order } : {}),
    },
    ...(opts.perspective !== undefined ? { perspective: opts.perspective as Perspective } : {}),
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
export async function getAllDocs<T>(type: string, order?: string): Promise<T[]> {
  const out: T[] = []
  let offset = 0
  while (out.length < SITEMAP_MAX_URLS) {
    const env = await barkparkFetch<QueryEnvelope<T>>({
      type,
      query: { filters: [], limit: 1000, offset, ...(order !== undefined ? { order } : {}) },
    })
    const page = env.result?.documents ?? []
    out.push(...page)
    if (!env.result?.hasMore || page.length === 0) break
    offset += page.length
  }
  return out.slice(0, SITEMAP_MAX_URLS)
}

export async function countDocs(type: string): Promise<number> {
  // The TRUE total-match count. The query envelope's `count` is the size of the
  // PAGE (a `limit: 1` read answers 1); the total arrives only as `total`, and
  // only with `?count=true`. Reading `count` made this return 1 for any
  // non-empty type, so the home rendered one page and no page links — 133 posts
  // showed 5 (stranger walk, 2026-10-01). barkparkFetch's query has no count
  // option; the SDK's docs(type).count() asks `?count=true` and reads `total`.
  return barkparkClient.withConfig({ token: resolveServerToken(process.env) }).docs(type).count()
}

export async function getDocById<T>(type: string, id: string, draft = false): Promise<T | null> {
  try {
    const env = await barkparkFetch<DocEnvelope<T>>({
      type,
      id,
      ...(draft ? { perspective: 'drafts' as Perspective } : {}),
    })
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

export async function getDocBySlug<T>(type: string, slug: string, draft = false): Promise<T | null> {
  // A slug is stored as `{current}` (the seeds) OR a plain string (the Studio's
  // Generate). Filter server-side on each path in turn, then match client-side
  // through slugOf as a safety net so we never return the wrong document.
  for (const path of ['slug.current', 'slug']) {
    const env = await barkparkFetch<QueryEnvelope<T>>({
      type,
      query: { filters: [makeFilterExpression(path, 'eq', slug)] },
      ...(draft ? { perspective: 'drafts' as Perspective } : {}),
    })
    const hit = (env.result?.documents ?? []).find(
      (d) => slugOf((d as { slug?: SlugValue }).slug) === slug,
    )
    if (hit) return hit
  }
  return null
}
