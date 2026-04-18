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

async function get<T>(path: string, tags: string[]): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
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
  return env.result ?? []
}

export async function getDoc<T>(type: string, id: string): Promise<T | null> {
  const env = await get<DocEnvelope<T>>(
    `/v1/data/doc/${DATASET}/${encodeURIComponent(type)}/${encodeURIComponent(id)}`,
    [`bp:ds:${DATASET}:doc:${id}`, `bp:ds:${DATASET}:type:${type}`],
  )
  return env.result
}

export async function getDocBySlug<T>(type: string, slug: string): Promise<T | null> {
  const env = await get<QueryEnvelope<T>>(
    `/v1/data/query/${DATASET}/${encodeURIComponent(type)}?slug=${encodeURIComponent(slug)}`,
    [`bp:ds:${DATASET}:type:${type}`],
  )
  return env.result?.[0] ?? null
}
