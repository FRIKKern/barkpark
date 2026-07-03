import 'server-only'
import { makeFilterExpression } from '@barkpark/core'
import { createBarkparkServer } from '@barkpark/nextjs/server'
import { barkparkClient } from '../barkpark.config'

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
  serverToken: process.env.BARKPARK_SERVER_TOKEN ?? 'barkpark-dev-token',
})

export async function getDocs<T>(type: string): Promise<T[]> {
  const env = await barkparkFetch<QueryEnvelope<T>>({ type })
  return env.result?.documents ?? []
}

export async function getDoc<T>(type: string, id: string): Promise<T | null> {
  const env = await barkparkFetch<DocEnvelope<T>>({ type, id })
  return env.result
}

export async function getDocBySlug<T>(type: string, slug: string): Promise<T | null> {
  // Filter server-side on the nested `slug.current` path, then match client-side
  // as a safety net so we never return the wrong document.
  const env = await barkparkFetch<QueryEnvelope<T>>({
    type,
    query: { filters: [makeFilterExpression('slug.current', 'eq', slug)] },
  })
  const docs = env.result?.documents ?? []
  return docs.find((d) => (d as { slug?: { current?: string } }).slug?.current === slug) ?? null
}
