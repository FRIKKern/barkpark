// WHERE THE BUILD-TIME BROWSE SEED SENDS ITS BEARER — and why that is a
// decision worth its own module.
//
// ─────────────────────────────────────────────────────────────────────────────
//  THE LIVE FINDING (task-eb8cd26d8d8d171c)
// ─────────────────────────────────────────────────────────────────────────────
//  `bp.ts → browseSeed` baked the first-paint browse landing by calling the
//  FLAT search route at the bare origin:
//
//      GET <origin>/v1/data/search/:dataset?q=%20&engine=postgres…
//      authorization: Bearer <public-read token>
//
//  Against the real producer that answers **403**. The flat route is the
//  ANONYMOUS spelling; a public-read token is issued against a workspace and a
//  project, and presenting it off the tenancy prefix is not "a stronger
//  request" — it is a request the route refuses. The scoped spelling of the
//  same route,
//
//      GET <origin>/w/:workspace/p/:project/v1/data/search/:dataset?…
//      authorization: Bearer <public-read token>
//
//  is the one that answers 200.
//
//  THE SECOND HALF OF THE DEFECT, and the worse one: browseSeed caught the
//  non-2xx, `console.warn`ed, and shipped `initialData: null`. The island then
//  paints from its prefix seed and refetches live — so on a developer's screen
//  the site LOOKS right while the build has silently stopped baking the thing
//  it exists to bake. A 403 that degrades into a working page is a 403 nobody
//  ever reads. `browseSearchRequest` therefore reports which auth mode it
//  chose, so the caller can say ANONYMOUS FALLBACK (a documented, expected
//  state on a tokenless build) in different words from AUTHENTICATED READ
//  FAILED (a defect).
//
//  Dep-free on purpose: `bp.ts` imports @barkpark/core and cannot be loaded by
//  `node --test`. The decision this module makes is the whole finding, so the
//  decision lives where a test can reach it.

/** The env fields the browse request derives from — the subset of `bp.ts`'s
 *  `env` that decides a URL and a header, and nothing else. */
export interface BrowseEnv {
  apiUrl: string
  dataset: string
  docType: string
  token?: string | undefined
  workspace?: string | undefined
  project?: string | undefined
}

/**
 * How the request authenticates.
 *
 * `scoped-bearer`  — a token, presented on the tenancy-prefixed route. The only
 *                    combination the producer answers 200 for.
 * `anonymous-flat` — no token, flat route. The published site's own transport
 *                    (FinderIsland's interceptor is flat-anonymous by design),
 *                    and a perfectly good build seed. Expected, not a fault.
 * `unscopable-anonymous` — a token WAS configured but no workspace/project pair
 *                    could be derived, so there is no scoped route to send it
 *                    to. The bearer is DROPPED rather than sent somewhere that
 *                    403s: a flat anonymous read still returns published docs.
 *                    Distinct from `anonymous-flat` because it is a
 *                    MISCONFIGURATION the caller should say out loud.
 */
export type BrowseAuthMode = 'scoped-bearer' | 'anonymous-flat' | 'unscopable-anonymous'

export interface BrowseRequest {
  url: string
  headers: Record<string, string>
  authMode: BrowseAuthMode
}

/** `/w/:workspace/p/:project` already on the configured apiUrl, or null. The
 *  managed dashboard hands out a scoped URL; a self-hosted instance usually
 *  does not, and then the pair arrives as BARKPARK_WORKSPACE/_PROJECT. */
export function scopePrefixOf(apiUrl: string): string | null {
  const path = new URL(apiUrl).pathname.replace(/\/+$/, '')
  return /^(?:.*)\/w\/[^/]+\/p\/[^/]+$/.test(path) ? path : null
}

/** The `?fields=` allowlist — the SCALAR fields the finder's normalizeHit reads.
 *  Mirrors FinderIsland's per-keystroke request so the baked browse and a live
 *  keystroke weigh the same. */
export const HIT_FIELDS =
  'title,name,excerpt,description,bio,slug,publishedAt,status,author,category'

/**
 * The exact request the build should issue for the first-paint browse landing.
 *
 * The route choice, stated as a rule rather than as a list of cases:
 * **a bearer only ever rides a scoped path.** If a scoped path exists (on the
 * apiUrl, or buildable from workspace+project), the token goes there. If none
 * exists, the token is dropped and the read goes out flat and anonymous — the
 * same transport the deployed site uses.
 */
export function browseSearchRequest(env: BrowseEnv): BrowseRequest {
  const params = new URLSearchParams({
    q: ' ',
    engine: 'postgres',
    types: env.docType,
    perspective: 'published',
    limit: '100',
    fields: HIT_FIELDS,
  })
  const tail = `/v1/data/search/${encodeURIComponent(env.dataset)}?${params}`
  const origin = new URL(env.apiUrl).origin
  const token = (env.token || '').trim()

  if (!token) {
    return { url: `${origin}${tail}`, headers: {}, authMode: 'anonymous-flat' }
  }

  const prefix =
    scopePrefixOf(env.apiUrl) ||
    ((env.workspace || '').trim() && (env.project || '').trim()
      ? `/w/${encodeURIComponent((env.workspace as string).trim())}/p/${encodeURIComponent((env.project as string).trim())}`
      : null)

  if (!prefix) {
    return { url: `${origin}${tail}`, headers: {}, authMode: 'unscopable-anonymous' }
  }
  return {
    url: `${origin}${prefix}${tail}`,
    headers: { authorization: `Bearer ${token}` },
    authMode: 'scoped-bearer',
  }
}

/** Does this payload actually carry hits? The build's own answer to "did the
 *  seed bake", so the caller never reports a 200-shaped empty as a success.
 *  Accepts both envelope spellings the search route has shipped. */
export function browseSeedIsNonempty(data: unknown): boolean {
  if (!data || typeof data !== 'object') return false
  const o = data as Record<string, unknown>
  const inner = (o.result && typeof o.result === 'object' ? o.result : o) as Record<string, unknown>
  for (const key of ['documents', 'hits']) {
    const v = inner[key]
    if (Array.isArray(v) && v.length > 0) return true
  }
  return false
}
