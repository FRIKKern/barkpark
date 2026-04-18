import 'server-only'
import { createBarkparkServer } from '@barkpark/nextjs/server'
import { barkparkClient } from '../barkpark.config'

export const barkpark = createBarkparkServer({
  client: barkparkClient,
  serverToken: process.env.BARKPARK_SERVER_TOKEN ?? 'barkpark-dev-token',
})

const BASE = barkparkClient.config.projectUrl.replace(/\/+$/, '')
const DATASET = barkparkClient.config.dataset

export interface DocEnvelope<T> {
  result: T | null
}

export interface QueryEnvelope<T> {
  result: T[]
}

async function fetchJson<T>(path: string, tags: string[], draft = false): Promise<T> {
  const headers: Record<string, string> = { Accept: 'application/json' }
  if (draft) {
    headers.Authorization = `Bearer ${process.env.BARKPARK_SERVER_TOKEN ?? 'barkpark-dev-token'}`
  }
  const res = await fetch(`${BASE}${path}`, {
    headers,
    next: draft ? { revalidate: 0 } : { tags, revalidate: 60 },
  })
  if (!res.ok) {
    throw new Error(`barkpark fetch ${path} failed: ${res.status}`)
  }
  return (await res.json()) as T
}

export async function getDocs<T>(
  type: string,
  opts: { limit?: number; offset?: number; perspective?: string } = {},
): Promise<T[]> {
  const qs = new URLSearchParams()
  if (opts.limit !== undefined) qs.set('limit', String(opts.limit))
  if (opts.offset !== undefined) qs.set('offset', String(opts.offset))
  if (opts.perspective !== undefined) qs.set('perspective', opts.perspective)
  const suffix = qs.toString() ? `?${qs.toString()}` : ''
  const env = await fetchJson<QueryEnvelope<T>>(
    `/v1/data/query/${DATASET}/${encodeURIComponent(type)}${suffix}`,
    [`bp:ds:${DATASET}:type:${type}`],
    opts.perspective === 'drafts' || opts.perspective === 'raw',
  )
  return env.result ?? []
}

export async function countDocs(type: string): Promise<number> {
  const docs = await getDocs<{ _id: string }>(type)
  return docs.length
}

export async function getDocById<T>(type: string, id: string, draft = false): Promise<T | null> {
  const path = `/v1/data/doc/${DATASET}/${encodeURIComponent(type)}/${encodeURIComponent(id)}${draft ? '?perspective=drafts' : ''}`
  const env = await fetchJson<DocEnvelope<T>>(
    path,
    [`bp:ds:${DATASET}:doc:${id}`, `bp:ds:${DATASET}:type:${type}`],
    draft,
  )
  return env.result
}

export async function getDocBySlug<T>(type: string, slug: string, draft = false): Promise<T | null> {
  const suffix = draft ? '&perspective=drafts' : ''
  const env = await fetchJson<QueryEnvelope<T>>(
    `/v1/data/query/${DATASET}/${encodeURIComponent(type)}?slug=${encodeURIComponent(slug)}${suffix}`,
    [`bp:ds:${DATASET}:type:${type}`],
    draft,
  )
  return env.result?.[0] ?? null
}
