// Build-time Barkpark content link (static target: every read happens at
// `astro build`; the deployed site carries NO token). Same env contract as
// every adapter (templates/DEPLOYING.md).
import { createClient, type BarkparkClient } from '@barkpark/core'
import { collectCorpus } from './paginate'

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

/** Every published doc of the featured type — the corpus the site is built
 * from, walked page by page.
 *
 * PAGINATED (task-669e7706cb86cb3a): this was ONE `.limit(500).find()` call
 * with no offset loop, so a corpus past 500 docs of the featured type was
 * silently truncated — the finder's baked seed missed those docs AND
 * `getStaticPaths` generated no page for them, a live 404 under a green build.
 * The walk itself lives in `./paginate.ts` so the real loop is under test
 * (that module imports nothing; this one cannot be imported dep-free). */
export async function allDocs(): Promise<DocRow[]> {
  const { rows } = await collectCorpus<DocRow>(async (limit, offset) => {
    const batch = await bp()
      .docs(env.docType)
      .order('_updatedAt:desc')
      .limit(limit)
      .offset(offset)
      .find()
    return (batch || []) as DocRow[]
  })
  return rows
}

/** Pull a human message out of an API `{error: string | {message,code}}` body,
 * else fall back to the HTTP reason phrase — mirrors the Next edition's
 * `humanUpstreamMessage` so both templates say the SAME thing about the same
 * upstream answer. */
function upstreamMessage(body: string, res: Response): string {
  let parsed: unknown
  try {
    parsed = JSON.parse(body)
  } catch {
    parsed = null
  }
  if (parsed && typeof parsed === 'object' && 'error' in parsed) {
    const e = (parsed as { error: unknown }).error
    if (typeof e === 'string' && e.trim() !== '') return e.trim()
    if (e && typeof e === 'object') {
      const o = e as { message?: unknown; code?: unknown }
      if (typeof o.message === 'string' && o.message.trim() !== '') return o.message.trim()
      if (typeof o.code === 'string' && o.code.trim() !== '') return o.code.trim()
    }
  }
  return res.statusText || 'corpus fetch failed'
}

/** The graph corpus, baked at build into a static JSON the island fetches.
 *
 * THROWS on a bad upstream answer, on purpose: a static build with no corpus is
 * a failed build, not a degraded page. The message shape is `graph <status>:
 * <message>` — IDENTICAL to the Next edition's `CorpusUnavailableError` /
 * `bp-corpus-status` marker, so one deploy-log classifier sees ONE class of
 * failure across both flagship templates instead of two dialects of it. */
export async function graphCorpus(): Promise<unknown> {
  // /v1/graph is a FLAT route — derive the bare origin (the managed path may
  // hand us a SCOPED apiUrl, and scoped+flat 404s; same live-caught class as
  // the Next edition's graph.ts).
  const res = await fetch(`${new URL(env.apiUrl).origin}/v1/graph?dataset=${encodeURIComponent(env.dataset)}`, {
    headers: env.token ? { authorization: `Bearer ${env.token}` } : {},
  })
  if (!res.ok) {
    const body = await res.text().catch(() => '')
    throw new Error(`graph ${res.status}: ${upstreamMessage(body, res)}`)
  }
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
