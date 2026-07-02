import 'server-only'
import { scopePrefix } from '@barkpark/core'
import { createBarkparkServer } from '@barkpark/nextjs/server'
import { barkparkClient } from '../barkpark.config'

export const barkpark = createBarkparkServer({
  client: barkparkClient,
  serverToken: process.env.BARKPARK_SERVER_TOKEN ?? 'barkpark-dev-token',
})

const BASE = barkparkClient.config.projectUrl.replace(/\/+$/, '')
const DATASET = barkparkClient.config.dataset
// '/w/<workspace>/p/<project>' when both are set on the client, else '' (flat /v1).
const SCOPE = scopePrefix(barkparkClient.config)

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

async function get<T>(path: string, tags: string[]): Promise<T> {
  const res = await fetch(`${BASE}${SCOPE}${path}`, {
    headers: { Accept: 'application/json' },
    next: { tags, revalidate: 60 },
  })
  if (!res.ok) {
    throw new Error(`barkpark fetch ${path} failed: ${res.status}`)
  }
  return (await res.json()) as T
}

export async function getDocs<T>(type: string): Promise<T[]> {
  const env = await get<QueryEnvelope<T>>(
    `/v1/data/query/${DATASET}/${encodeURIComponent(type)}`,
    [`bp:ds:${DATASET}:type:${type}`],
  )
  return env.result?.documents ?? []
}

export async function getDoc<T>(type: string, id: string): Promise<T | null> {
  const env = await get<DocEnvelope<T>>(
    `/v1/data/doc/${DATASET}/${encodeURIComponent(type)}/${encodeURIComponent(id)}`,
    [`bp:ds:${DATASET}:doc:${id}`, `bp:ds:${DATASET}:type:${type}`],
  )
  return env.result
}

export async function getDocBySlug<T>(type: string, slug: string): Promise<T | null> {
  // Filter server-side on the nested `slug.current` path (the query API reads the
  // `filter=field=value` param, NOT a bare `?slug=`), then match client-side as a
  // safety net so we never return the wrong document.
  const env = await get<QueryEnvelope<T>>(
    `/v1/data/query/${DATASET}/${encodeURIComponent(type)}?filter=slug.current=${encodeURIComponent(slug)}`,
    [`bp:ds:${DATASET}:type:${type}`],
  )
  const docs = env.result?.documents ?? []
  return docs.find((d) => (d as { slug?: { current?: string } }).slug?.current === slug) ?? null
}
