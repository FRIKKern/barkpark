// Build-time Barkpark content link (static target: every read happens at
// `astro build`; the deployed site carries NO token). Same env contract as
// every adapter (templates/DEPLOYING.md).
import { createClient, type BarkparkClient } from '@barkpark/core'

const API_VERSION = '2026-04-01'

function required(name: string): string {
  const v = (process.env[name] || '').trim()
  if (!v) throw new Error(`Missing required env var ${name} — see .env.example.`)
  return v
}

export const env = {
  apiUrl: required('BARKPARK_API_URL'),
  dataset: required('BARKPARK_DATASET'),
  token: (process.env.BARKPARK_TOKEN || '').trim() || undefined,
  workspace: (process.env.BARKPARK_WORKSPACE || '').trim() || undefined,
  project: (process.env.BARKPARK_PROJECT || '').trim() || undefined,
  docType: (process.env.BARKPARK_DOC_TYPE || '').trim() || 'entry',
  theme: (process.env.BARKPARK_THEME || '').trim() || 'evergreen',
  buildId: (process.env.BARKPARK_BUILD_ID || '').trim() || 'dev',
  contentRev: (process.env.BARKPARK_CONTENT_REV || '').trim() || 'unknown',
  siteBase: (process.env.BARKPARK_SITE_BASE || '').trim() || '/',
}

export function bp(): BarkparkClient {
  const scoped = /\/w\/[^/]+\/p\/[^/]+\/?$/.test(new URL(env.apiUrl).pathname)
  return createClient({
    projectUrl: env.apiUrl,
    dataset: env.dataset,
    apiVersion: API_VERSION,
    perspective: 'published',
    ...(env.token ? { token: env.token } : {}),
    ...(!scoped && env.workspace ? { workspace: env.workspace } : {}),
    ...(!scoped && env.project ? { project: env.project } : {}),
  })
}

export interface DocRow {
  _id: string
  _type: string
  title?: string
  slug?: string
  body?: unknown
  [k: string]: unknown
}

/** Every published doc of the featured type — the corpus the site is built from. */
export async function allDocs(): Promise<DocRow[]> {
  const rows = await bp().docs(env.docType).order('_updatedAt:desc').limit(500).find()
  return (rows || []) as DocRow[]
}

/** The graph corpus, baked at build into a static JSON the island fetches. */
export async function graphCorpus(): Promise<unknown> {
  // /v1/graph is a FLAT route — derive the bare origin (the managed path may
  // hand us a SCOPED apiUrl, and scoped+flat 404s; same live-caught class as
  // the Next edition's graph.ts).
  const res = await fetch(`${new URL(env.apiUrl).origin}/v1/graph?dataset=${encodeURIComponent(env.dataset)}`, {
    headers: env.token ? { authorization: `Bearer ${env.token}` } : {},
  })
  if (!res.ok) throw new Error(`graph corpus fetch failed: ${res.status}`)
  return res.json()
}

/** Full document read — the LIST projection is summary-only (no blocks). */
export async function getDoc(type: string, id: string): Promise<DocRow | null> {
  const doc = await bp().doc(type, id)
  return (doc || null) as DocRow | null
}

/** The PortableDoc block array of a full doc, wherever this type stores it. */
export function docBlocks(doc: DocRow | null): unknown[] {
  if (!doc) return []
  if (Array.isArray(doc.blocks)) return doc.blocks
  const body = doc.body as { blocks?: unknown[] } | unknown[] | undefined
  if (Array.isArray(body)) return body
  if (body && Array.isArray(body.blocks)) return body.blocks
  return []
}
