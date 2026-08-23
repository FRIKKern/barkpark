import 'server-only'
import { BarkparkNotFoundError, makeFilterExpression, type Perspective } from '@barkpark/core'
import { createBarkparkServer } from '@barkpark/nextjs/server'
import { barkparkClient } from '../barkpark.config'
import { resolveServerToken } from './resolve-server-token'

// Envelope shapes returned by the /v1/data endpoints. `result.count` is the
// TOTAL number of matching documents (not just the page you fetched).
export interface QueryResult<T> {
  count: number
  offset: number
  limit: number
  perspective: string
  documents: T[]
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
  opts: { limit?: number; offset?: number; perspective?: string } = {},
): Promise<T[]> {
  const env = await barkparkFetch<QueryEnvelope<T>>({
    type,
    query: { filters: [], ...(opts.limit !== undefined ? { limit: opts.limit } : {}), ...(opts.offset !== undefined ? { offset: opts.offset } : {}) },
    ...(opts.perspective !== undefined ? { perspective: opts.perspective as Perspective } : {}),
  })
  return env.result?.documents ?? []
}

export async function countDocs(type: string): Promise<number> {
  // Read the envelope's TRUE total-match count — a single small fetch — instead
  // of counting one page of documents (which caps at the page size).
  const env = await barkparkFetch<QueryEnvelope<{ _id: string }>>({
    type,
    query: { filters: [], limit: 1 },
  })
  return env.result?.count ?? 0
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
  // Filter server-side on the nested `slug.current` path, then match client-side
  // as a safety net so we never return the wrong document.
  const env = await barkparkFetch<QueryEnvelope<T>>({
    type,
    query: { filters: [makeFilterExpression('slug.current', 'eq', slug)] },
    ...(draft ? { perspective: 'drafts' as Perspective } : {}),
  })
  const docs = env.result?.documents ?? []
  return docs.find((d) => (d as { slug?: { current?: string } }).slug?.current === slug) ?? null
}
