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

/** One indexable document — the minimum the finder row + prefix index need.
 * Mirrors `templates/search-starter/lib/prefix-seed.ts` SeedDoc so the finder
 * island can build its in-browser prefix index from this static asset. */
export interface SeedDoc {
  id: string
  title: string
  slug: string
  type: string
}

/** What the build bakes into `dist/search-seed.json` for the finder island's
 * first paint. `initialData` is the raw browse `/v1/data/search` FindResponse
 * (the same payload a per-keystroke browse yields — `documents`, `count`,
 * `highlights`, …); `initialSeed` is the ranked corpus the island turns into
 * an in-browser prefix index. Both degrade gracefully if the island can't
 * fetch the asset — this is a head-start, never the authoritative search. */
export interface BrowseSeed {
  initialData: unknown
  initialSeed: SeedDoc[]
}

/**
 * The finder's first-paint browse landing + prefix seed, baked at build into a
 * static JSON the island fetches (the static-site edition of the Next finder's
 * `force-dynamic` layout seed). A static Astro host has no per-request SSR, so
 * this is the one place the ranked browse gets computed.
 *
 * `initialSeed` comes from `allDocs()` (`.order('_updatedAt:desc')`) — D40
 * proved ranked-browse order (`engine=indx q=' '`) is byte-identical to
 * `_updatedAt:desc` listing order (concordance 1.0000), so one listing call is
 * the source, no engine dependency. `initialData` is a build-time
 * flat-anonymous browse search so the island paints the exact browse hits with
 * engine relevance/highlights on first frame.
 */
export async function browseSeed(): Promise<BrowseSeed> {
  const docs = await allDocs()
  const initialSeed: SeedDoc[] = docs.map((d) => ({
    id: d._id,
    title: (d.title || '') as string,
    slug: (d.slug || '') as string,
    type: d._type,
  }))

  // The browse FindResponse. `/v1/data/search/:dataset` is a FLAT route — same
  // origin-derivation as graphCorpus (a scoped apiUrl + flat route 404s). A
  // missing/failed browse must NOT fail the build: the island falls back to the
  // seed's prefix index and its own live fetch. Empty q (' ') = ranked browse.
  // engine=postgres: the one engine every instance actually provisions (the
  // indx claim is retired); the served engine rides back as `engineUsed`.
  const params = new URLSearchParams({
    q: ' ',
    engine: 'postgres',
    types: env.docType,
    perspective: 'published',
    limit: '100',
    // Same ?fields= allowlist the island requests per keystroke — the baked
    // browse must not weigh megabytes (papers' body_html is 97% of a full hit).
    fields:
      'title,name,excerpt,description,bio,slug,publishedAt,status,author,category',
  })
  const url = `${new URL(env.apiUrl).origin}/v1/data/search/${encodeURIComponent(env.dataset)}?${params}`
  let initialData: unknown = null
  try {
    const res = await fetch(url, {
      headers: env.token ? { authorization: `Bearer ${env.token}` } : {},
    })
    if (res.ok) initialData = await res.json()
    else console.warn(`browse seed search returned ${res.status}; shipping seed-only landing`)
  } catch (err) {
    console.warn(`browse seed search failed (${(err as Error).message}); shipping seed-only landing`)
  }

  return { initialData, initialSeed }
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
