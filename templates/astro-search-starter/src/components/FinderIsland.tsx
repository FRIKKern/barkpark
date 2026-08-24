// THE finder, mounted as ONE React `client:only` island (charter D37-D47).
//
// The finder tree (finder.tsx + 13 lib modules) is copied VERBATIM from
// templates/search-starter — it was written for Next.js and still expects three
// same-origin Next route handlers (`/api/find`, `/api/find-event`,
// `/api/admin/reindex`). On the STATIC Astro target there is no server, so this
// island installs a `window.fetch` INTERCEPTOR (D39) that translates those
// routes to the browser-direct, FLAT-ANONYMOUS Barkpark search API (D37, NO
// token) and shapes every reply through the SAME `shapeFindResponse` the Next
// route used — so the finder cannot tell the transports apart.
//
// Dual-engine parity: BOTH `engine=indx` (typo-tolerant retrieval) and
// `engine=postgres` (FTS) flow through the one flat `/v1/data/search/:dataset`
// route; when a public-read WS token is provisioned the finder's own
// use-live-search flips to the persistent Phoenix channel per keystroke (that
// channel carries both engines too — D39). No separate Postgres transport.
import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { Finder } from '../finder/finder'
import { FinderErrorBoundary } from './FinderErrorBoundary'
import GraphPane from './GraphPane'
import { useIsDesktop } from './use-is-desktop'
import { HoveredDocProvider } from '../finder/lib/hovered-doc-context'
import { FinderNavProvider } from '../finder/lib/finder-nav-context'
import { shapeFindResponse, emptyParsed } from '../finder/lib/find-shape'
import type { FindResponse, SearchEngine, PopularQuery } from '../finder/lib/find'
import { DOC_TYPES } from '../finder/lib/find'
import { DATASET } from '../finder/lib/config'
import { shapeSeed } from '../lib/shape-seed'
import type { SeedState, RawSeed } from '../lib/shape-seed'

// Barkpark API ORIGIN — the flat/anonymous search routes live at the bare
// origin (a SCOPED apiUrl 404s the flat route, same class the graph handles).
// Derived from the WS URL define (`<origin>/socket`, D38) so there is exactly
// one origin source of truth baked at build.
const WS_URL = process.env.NEXT_PUBLIC_BARKPARK_WS_URL || ''
const ORIGIN = (() => {
  try {
    return WS_URL ? new URL(WS_URL).origin : ''
  } catch {
    return ''
  }
})()
// The type allowlist the finder scopes to — D45 pins it to the single built type.
const TYPES = DOC_TYPES.map((t) => t.type).join(',')
const MAX_HITS = 100
// The SCALAR fields normalizeHit/derive* consume (find.ts) — requested via the
// route's ?fields= allowlist so a hit ships ~600B, not ~38KB. Live-caught
// twice: papers' body_html (37KB/hit, never read by the finder) and then their
// PortableDoc source under body/blocks/content (~120KB/hit) made a limit=100
// keystroke 12-15MB of JSON. Deliberately NO body/blocks/content: snippets
// degrade to description + the server's own highlights (deriveBody's fallback),
// which is the price of a ~40ms keystroke — the engine already matched the
// body server-side. System keys (_id/_type/_draft/…) always ride along.
const HIT_FIELDS =
  'title,name,excerpt,description,bio,slug,publishedAt,status,author,category'

function jsonResponse(data: unknown): Response {
  return new Response(JSON.stringify(data), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
}

function errorEnvelope(engine: SearchEngine, q: string, error: string): FindResponse {
  return {
    mode: q ? 'search' : 'browse',
    hits: [],
    total: 0,
    engine,
    engineUsed: engine,
    indxUnavailable: false,
    parsedQuery: q ? emptyParsed() : null,
    recovery: null,
    facets: null,
    truncation: null,
    ms: null,
    cache: false,
    upstreamMs: null,
    searchEventId: null,
    correctedTo: null,
    error,
  }
}

/** GET /api/find[?suggest=1] → GET <origin>/v1/data/search/:dataset(/suggestions). */
async function handleFind(reqUrl: URL): Promise<Response> {
  if (reqUrl.searchParams.get('suggest') === '1') {
    try {
      const r = await fetch(
        `${ORIGIN}/v1/data/search/${DATASET}/suggestions?q=&limit=8`,
      )
      const j = (await r.json()) as {
        result?: { popular?: PopularQuery[]; nohits?: PopularQuery[] }
      }
      return jsonResponse({
        popular: j.result?.popular ?? [],
        nohits: j.result?.nohits ?? [],
      })
    } catch {
      return jsonResponse({ popular: [], nohits: [] })
    }
  }

  const q = (reqUrl.searchParams.get('q') ?? '').trim()
  // Same unbiased reader as the Next editions: explicit `engine=indx` opts in,
  // anything else is postgres (the engine every instance actually provisions).
  const engine: SearchEngine =
    reqUrl.searchParams.get('engine') === 'indx' ? 'indx' : 'postgres'
  const sid = reqUrl.searchParams.get('sid')
  const browse = !q

  const params = new URLSearchParams({
    q: browse ? ' ' : q,
    engine,
    types: TYPES,
    perspective: 'published',
    limit: String(MAX_HITS),
    fields: HIT_FIELDS,
  })
  const headers: Record<string, string> = {}
  // Attribute the query to this browser session (anti-gaming key) — NO token.
  if (sid) headers['X-BP-SEARCH-CLIENT'] = sid
  if (sid && q) headers['X-BP-SEARCH-RECORD'] = '1'

  const t0 = performance.now()
  try {
    const r = await fetch(`${ORIGIN}/v1/data/search/${DATASET}?${params.toString()}`, {
      headers,
      cache: 'no-store',
    })
    const json = await r.json()
    const upstreamMs = Math.round(performance.now() - t0)
    // Shape identically to the Next route. `engineUsed: engine` is only the
    // fallback — the server-reported `engineUsed` in the payload wins in the
    // shaper (the pipeline is the only place that knows what actually served).
    return jsonResponse(
      shapeFindResponse(json, {
        engine,
        engineUsed: engine,
        browse,
        cache: false,
        upstreamMs,
      }),
    )
  } catch (e) {
    return jsonResponse(errorEnvelope(engine, q, (e as Error).message))
  }
}

/** POST /api/find-event → POST <origin>/v1/data/search/:dataset/{correction|interaction}. */
async function handleFindEvent(init?: RequestInit): Promise<Response> {
  let body: {
    kind?: 'correction' | 'click'
    from?: string
    to?: string
    queryEventId?: string
    objectId?: string
    position?: number
    sid?: string
  } = {}
  try {
    if (typeof init?.body === 'string') body = JSON.parse(init.body)
  } catch {
    return jsonResponse({ ok: true })
  }

  const { kind, from, to, queryEventId, objectId, position, sid } = body
  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  if (sid) headers['X-BP-SEARCH-CLIENT'] = sid // NO token (D37)

  try {
    if (kind === 'correction' && from && to) {
      await fetch(`${ORIGIN}/v1/data/search/${DATASET}/correction`, {
        method: 'POST',
        headers,
        cache: 'no-store',
        keepalive: true,
        body: JSON.stringify({ from, to }),
      })
    } else if (kind === 'click' && queryEventId && objectId) {
      await fetch(`${ORIGIN}/v1/data/search/${DATASET}/interaction`, {
        method: 'POST',
        headers,
        cache: 'no-store',
        keepalive: true,
        body: JSON.stringify({ queryEventId, objectId, position }),
      })
    }
  } catch {
    /* best-effort feedback — a dropped signal never breaks search UX */
  }
  return jsonResponse({ ok: true })
}

/** Patch window.fetch ONCE, at module load — before the finder's effects run. */
function installInterceptor(): void {
  if (typeof window === 'undefined') return
  const w = window as Window & { __bpFinderFetchPatched?: boolean }
  if (w.__bpFinderFetchPatched) return
  w.__bpFinderFetchPatched = true

  const original = window.fetch.bind(window)
  window.fetch = (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    try {
      const urlStr =
        typeof input === 'string'
          ? input
          : input instanceof URL
            ? input.href
            : (input as Request).url
      const path = new URL(urlStr, window.location.href).pathname
      if (path.endsWith('/api/find-event')) {
        return handleFindEvent(
          init ?? (input instanceof Request ? { body: undefined } : undefined),
        )
      }
      if (path.endsWith('/api/find')) {
        return handleFind(new URL(urlStr, window.location.href))
      }
      if (path.endsWith('/api/admin/reindex')) {
        // No admin surface on a static deploy — degrade honestly.
        return Promise.resolve(
          jsonResponse({ ok: false, error: 'Reindex is unavailable on a static site.' }),
        )
      }
    } catch {
      /* fall through to the real fetch on any parse hiccup */
    }
    return original(input as RequestInfo | URL, init)
  }
}

installInterceptor()

// `shapeSeed` + its `RawSeed`/`SeedState` types moved to `../lib/shape-seed` —
// a React-free module unit-tested by `shape-seed.test.ts` so the seed-shape
// contract (baked `SeedDoc[]` → built `PrefixSeed`) can't silently regress.

/** Shared by both compositions so the rail is the SAME object on every page —
 * identical widths and border to the Next edition's `(finder)/layout.tsx`
 * aside. Below `md` the landing rail is the whole screen; on a document page it
 * hides, because the document owns the small screen there (the Next edition
 * reaches the same end state by mounting the detail as a `fixed inset-0`
 * overlay ON TOP of the rail). */
const RAIL_CLASS =
  'shrink-0 overflow-y-auto border-r border-zinc-200 md:w-[480px] lg:w-[640px] xl:w-[860px] 2xl:w-[1080px] dark:border-zinc-800'

/** The id of the page-owned node the corpus graph is PORTALLED into. Only the
 * landing renders one; a document page does not, which is exactly how the graph
 * disappears when a document opens without this island ever unmounting. */
const GRAPH_SLOT_ID = 'bp-graph-slot'

/**
 * Track the graph slot across client-side navigations.
 *
 * THE PROBLEM THIS SOLVES. The island is `transition:persist`ed, so ClientRouter
 * REUSES it across pages — that is what keeps the finder's query, results and
 * scroll alive (the whole point). But persistence means the island's own markup
 * cannot change per page, while the graph must appear on the landing and vanish
 * on a document page.
 *
 * A React PORTAL is the resolution: the graph stays inside THIS React tree — so
 * the finder↔graph context bridge (`useGraphMatches` / `useHoveredDoc`) is fully
 * intact, which is the constraint that forced one island in the first place —
 * while its DOM lands in a node the PAGE owns and ClientRouter swaps. Landing
 * renders the slot, document pages don't, so the graph follows the page without
 * the island ever unmounting.
 *
 * `astro:page-load` fires after every swap (and on the initial load), which is
 * when the new page's DOM — and therefore the presence or absence of the slot —
 * is finally readable.
 */
function useGraphSlot(): HTMLElement | null {
  const [slot, setSlot] = useState<HTMLElement | null>(null)

  useEffect(() => {
    const read = () => setSlot(document.getElementById(GRAPH_SLOT_ID))
    read()
    document.addEventListener('astro:page-load', read)
    return () => document.removeEventListener('astro:page-load', read)
  }, [])

  return slot
}

export default function FinderIsland() {
  const slot = useGraphSlot()
  // D79 — the slot says WHICH PAGE this is; the width says whether the graph
  // may MOUNT. Two separate facts, deliberately kept apart: `railClass` below
  // still reads `slot` alone, because on a phone the landing rail must stay
  // `w-full` (gating the rail on width would hide the finder itself, which is
  // the entire page). Only the PORTAL is width-gated.
  const isDesktop = useIsDesktop()
  // The 0ms head-start seed + first-paint browse are baked into a static
  // `search-seed.json` by the seed slice; fetch it at runtime and degrade
  // gracefully when it is absent (D40) — the finder still works, just without
  // the pre-warmed first result set.
  const [seed, setSeed] = useState<SeedState>({ initialData: null, initialSeed: null })
  useEffect(() => {
    const base = (import.meta.env.BASE_URL || '/').replace(/\/?$/, '/')
    let alive = true
    fetch(`${base}search-seed.json`)
      .then((r) => (r.ok ? r.json() : null))
      .then((j: RawSeed | null) => {
        if (alive && j) setSeed(shapeSeed(j))
      })
      .catch(() => {
        /* absent seed is fine — the finder fetches its own browse on mount */
      })
    return () => {
      alive = false
    }
  }, [])

  // Wrap the whole tree: a throw anywhere below degrades to the on-brand
  // fallback instead of blanking the page (the island IS the page here).
  //
  // The MASTER SPLIT (stw7-backlog-astro-graph-landing-reintegrate): the same
  // composition as the Next edition's (finder)/layout.tsx — the finder as the
  // left rail at variant="master" (which switches ON its graph-matches
  // publishing), the corpus graph filling the right pane. Both live in this ONE
  // island because the finder→graph bridge is React context (GraphMatches +
  // HoveredDoc) — two Astro islands would be two roots with no shared state.
  // On mobile the rail is full-width and the graph hides (the original's
  // `hidden md:flex` welcome-pane behaviour); rail widths mirror the original.
  const finder = (
    <Finder
      variant="master"
      initialData={seed.initialData}
      initialSeed={seed.initialSeed}
      initialEngine="postgres"
    />
  )

  // ONE composition on EVERY page — required, not tidiness: a persisted island
  // is REUSED across navigations, so its own markup can never be per-page. The
  // rail is always this aside; the graph rides a portal into whatever slot the
  // current page provides (landing: yes, document: no).
  //
  // `hidden md:block` on a document page vs full-width on the landing is the one
  // per-page difference, and it is driven by the SLOT, not by a prop: with a
  // graph slot present the rail shares the screen (`w-full` under `md`, where
  // the graph is hidden anyway); with no slot the document owns the small screen
  // and the rail steps aside — the end state the Next edition reaches by
  // mounting its detail as a `fixed inset-0 md:static` overlay.
  const railClass = slot ? `w-full ${RAIL_CLASS}` : `hidden md:block ${RAIL_CLASS}`

  return (
    <FinderErrorBoundary>
      <HoveredDocProvider>
        <FinderNavProvider>
          <aside className={`h-screen ${railClass}`}>{finder}</aside>
          {/* The graph: same React tree (bridge intact), page-owned DOM —
              and, below `md`, NOT MOUNTED AT ALL. index.astro hides the slot
              with `hidden md:block`, but CSS `display: none` does not stop
              GraphPane's mount effect from appending <script src=bp-graph.js>
              (140 KB) and fetching graph.json (437 KB): measured at 390x844,
              576,990 B arrived for a pane whose computed display was `none`.
              Not mounting it is what stops the download. On a resize across
              768px the gate mounts/unmounts and GraphPane's own cleanup tears
              the renderer down. */}
          {slot && isDesktop ? createPortal(<GraphPane />, slot) : null}
        </FinderNavProvider>
      </HoveredDocProvider>
    </FinderErrorBoundary>
  )
}
