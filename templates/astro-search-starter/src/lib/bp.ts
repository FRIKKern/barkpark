// Build-time Barkpark content link (static target: every read happens at
// `astro build`; the deployed site carries NO token). Same env contract as
// every adapter (templates/DEPLOYING.md).
import type { BuildIdentity } from './provenance.ts'
import { createClient, type BarkparkClient } from '@barkpark/core'
import { collectCorpus } from './paginate'
import { browseSearchRequest, browseSeedIsNonempty, type BrowseAuthMode } from './browse-request'

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

/**
 * The SAME two build markers `env` reads above, but with UNSET reported as
 * `null` instead of collapsed onto the "dev"/"unknown" sentinels.
 *
 * Two readers, two contracts, and they genuinely differ. The deploy gate greps
 * `content="…"` out of the served HTML (Base.astro emits `env.buildId` /
 * `env.contentRev`) and asserts NON-EMPTY, so those must always carry a string.
 * A HUMAN reading the page needs the opposite: a caption that says `build dev`
 * reads as a build NAMED dev. This is that distinction, baked into graph.json
 * (src/pages/graph.json.ts) and rendered by `lib/provenance.buildIdentityLine`.
 *
 * Deliberately NOT a change to `env`: those values are an interface the deploy
 * engine reads back with `sed`.
 */
export const buildIdentity: BuildIdentity = {
  buildId: (process.env.BARKPARK_BUILD_ID || '').trim() || null,
  contentRev: (process.env.BARKPARK_CONTENT_REV || '').trim() || null,
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

/** How a failed browse seed should be NAMED in the build log.
 *
 * The live finding this exists for: a public-read bearer on the flat route was
 * answered 403, browseSeed warned once in prose indistinguishable from an
 * offline instance, and the island's live refetch made the page look correct —
 * so the build silently stopped baking the thing it exists to bake. An
 * anonymous read is an EXPECTED configuration; an authenticated one that fails
 * is a DEFECT; a token with nowhere scoped to send it is a MISCONFIGURATION.
 * Three states, three sentences, one grep each. */
function seedFailurePrefix(mode: BrowseAuthMode): string {
  switch (mode) {
    case 'scoped-bearer':
      return 'browse seed AUTHENTICATED read FAILED —'
    case 'unscopable-anonymous':
      return 'browse seed ANONYMOUS FALLBACK (BARKPARK_TOKEN set but no workspace/project scope to send it to) —'
    default:
      return 'browse seed ANONYMOUS FALLBACK (no BARKPARK_TOKEN — the deployed site uses this transport too) —'
  }
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
 * browse search — SCOPED-authenticated when a token is configured, flat and
 * anonymous otherwise (`./browse-request`) — so the island paints those hits with
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

  // The browse FindResponse. WHERE THE BEARER GOES is the whole subtlety here
  // and it lives in `./browse-request` (dep-free, unit- AND producer-pinned):
  // a public-read token presented on the FLAT route is answered 403 by the real
  // producer, so a token only ever rides the SCOPED `/w/:ws/p/:p` spelling and
  // a tokenless build goes out flat and anonymous — the deployed site's own
  // transport. Empty q (' ') = ranked browse; engine=postgres is the one engine
  // every instance provisions (the indx claim is retired) and the served engine
  // rides back as `engineUsed`.
  const req = browseSearchRequest(env)
  let initialData: unknown = null
  try {
    const res = await fetch(req.url, { headers: req.headers })
    if (res.ok) initialData = await res.json()
    else console.warn(`${seedFailurePrefix(req.authMode)} search returned ${res.status}; shipping seed-only landing`)
  } catch (err) {
    console.warn(
      `${seedFailurePrefix(req.authMode)} search failed (${(err as Error).message}); shipping seed-only landing`,
    )
  }
  // A 200 that carries no hits is not a baked seed. Say so in the SAME words
  // the non-2xx path uses, because the island cannot tell the two apart and a
  // build log that only reports the loud failure reports half of them.
  if (initialData !== null && !browseSeedIsNonempty(initialData)) {
    console.warn(`${seedFailurePrefix(req.authMode)} search returned no hits; shipping seed-only landing`)
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
