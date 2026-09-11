#!/usr/bin/env node
// smoke-stub-api.mjs — the deterministic Barkpark the render smoke builds and
// runs against, plus the static file server for `dist/`. ONE origin serves BOTH,
// which is the point: the finder island's fetch interceptor rewrites `/api/find`
// to `<ORIGIN>/v1/data/search/:dataset`, and ORIGIN is derived at BUILD from
// BARKPARK_API_URL. Point that at this server and every call the island makes —
// the seed asset, the search route, the suggestions route — is SAME-ORIGIN, so
// no CORS preflight, no proxy, and no network beyond loopback.
//
// WHY A STUB AND NOT A PROXY TO A REAL INSTANCE (the choice, stated).
// `scripts/parity-check.mjs` is the instrument that must talk to a real server:
// its whole claim is "the two editions read the same corpus off the same route",
// which a canned corpus cannot make. THIS harness makes the opposite claim —
// "the island renders, and keeps rendering across a keystroke" — and for that a
// live instance is pure downside: its corpus drifts, so the assertion "typing
// `bark` yields >=1 row" becomes a statement about today's production content;
// it needs credentials and egress a PR runner should not have; and an instance
// outage reds somebody's diff. A canned corpus makes the gate say exactly one
// thing, about the diff, every time. The cost is honest and named: this harness
// can NEVER catch an API contract drift — only parity-check can.
//
// Node stdlib only. No dependencies, so it also runs inside a fresh checkout
// before `npm ci` has resolved the template's own tree.
import { createServer } from 'node:http'
import { createReadStream, promises as fs } from 'node:fs'
import { extname, join, normalize, sep } from 'node:path'

/** The canned corpus. Every title shares the `barkpark` token on purpose: the
 * smoke types a ONE-character query (`b`) and then a MULTI-character one
 * (`bark`), and both must land on a non-empty result set through BOTH retrieval
 * paths the island can take — the in-browser prefix index built from the baked
 * seed (prefix match on `b`/`bark`) and the HTTP route below. A corpus where
 * only one of the two queries hits could not tell a broken transition from a
 * legitimately empty one. */
export const CORPUS = [
  { _id: 'doc-finder', _type: 'entry', title: 'Barkpark finder island', slug: 'barkpark-finder-island', description: 'The one React island that is the whole landing page.' },
  { _id: 'doc-graph', _type: 'entry', title: 'Barkpark corpus graph', slug: 'barkpark-corpus-graph', description: 'How every document connects to every other one.' },
  { _id: 'doc-search', _type: 'entry', title: 'Barkpark search routes', slug: 'barkpark-search-routes', description: 'The flat anonymous read route the finder calls per keystroke.' },
  { _id: 'doc-deploy', _type: 'entry', title: 'Barkpark deploy engine', slug: 'barkpark-deploy-engine', description: 'Static sites, built aside and swapped in.' },
  { _id: 'doc-tasks', _type: 'entry', title: 'Barkpark task ledger', slug: 'barkpark-task-ledger', description: 'Work is a document like everything else.' },
]

/** Substring match over the fields the finder actually surfaces. A blank or
 * whitespace-only `q` is a BROWSE (the finder's own convention) and returns the
 * whole corpus. */
export function searchCorpus(q) {
  const needle = (q ?? '').trim().toLowerCase()
  if (!needle) return CORPUS
  return CORPUS.filter((d) =>
    `${d.title} ${d.description} ${d.slug}`.toLowerCase().includes(needle),
  )
}

/** The FLAT search route's envelope, verbatim in shape: the island hands the
 * whole body to `shapeFindResponse`, which reads `documents` / `count` /
 * `engineUsed` off the TOP level (not under `result`). Documented in
 * parity-check.mjs: "{ count, query, facets, documents: [{ _id, ... }] }". */
export function searchEnvelope(q, engine) {
  const documents = searchCorpus(q)
  return {
    count: documents.length,
    query: q ?? '',
    facets: null,
    documents,
    // The pipeline's own report of what served. `postgres` is the one engine
    // every instance provisions, so an `engine=indx` request answered here
    // reports the substitution honestly and the finder's `indxUnavailable`
    // branch stays reachable rather than being papered over.
    engineUsed: 'postgres',
    ms: 1,
    searchEventId: null,
    correctedTo: null,
    parsedQuery: { terms: (q ?? '').trim() ? [(q ?? '').trim()] : [], phrases: [], excludes: [], prefixes: [] },
  }
}

/** The corpus graph in the exact alias set `normalizeCorpusGraph` reads. The
 * root is deliberately NOT named `barkpark` — that literal short-circuits
 * `computeRootId`, and letting the degree walk actually run is free coverage. */
export function graphEnvelope() {
  return {
    nodes: CORPUS.map((d) => ({ id: d._id, doc_id: d._id, type: d._type, title: d.title })),
    edges: CORPUS.slice(1).map((d) => ({ from_id: 'doc-finder', to_id: d._id, kind: 'reference' })),
    truncated: false,
  }
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.webp': 'image/webp',
  '.woff2': 'font/woff2',
  '.ico': 'image/x-icon',
  '.map': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
}

function sendJson(res, body, status = 200) {
  const payload = JSON.stringify(body)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    // The island's per-keystroke fetch is `cache: 'no-store'` already; say it
    // from this side too so a rerun can never read a stale transition.
    'cache-control': 'no-store',
  })
  res.end(payload)
}

/**
 * Resolve a URL path to a file inside `distDir`, refusing anything that escapes
 * it. `..` in a URL is not a hypothetical here — the smoke drives a real
 * browser, and a traversal bug in a fixture server is still a traversal bug.
 */
async function resolveStatic(distDir, pathname) {
  let rel = decodeURIComponent(pathname)
  if (rel.endsWith('/')) rel += 'index.html'
  const abs = normalize(join(distDir, rel))
  if (abs !== distDir && !abs.startsWith(distDir + sep)) return null
  try {
    const st = await fs.stat(abs)
    if (st.isDirectory()) return resolveStatic(distDir, rel.replace(/\/?$/, '/'))
    return abs
  } catch {
    // Astro's `build.format: 'directory'` default writes `/a/b/index.html`; a
    // request for the extensionless `/a/b` must still find it.
    if (!extname(abs)) {
      try {
        const idx = join(abs, 'index.html')
        await fs.stat(idx)
        return idx
      } catch {
        return null
      }
    }
    return null
  }
}

/**
 * The server. `unknown` collects every `/v1/...` path this stub did not
 * recognise — a route the template starts calling and this fixture does not
 * answer is a silent hole in the gate, so the smoke PRINTS them and the caller
 * decides. Never a hidden 404.
 */
export function createStubServer({ distDir, onUnknown = () => {} }) {
  return createServer(async (req, res) => {
    let url
    try {
      url = new URL(req.url, 'http://127.0.0.1')
    } catch {
      res.writeHead(400).end()
      return
    }
    // STRIP THE TENANCY PREFIX. @barkpark/core prefixes every scoped read with
    // `/w/:workspace/p/:project` while the finder's own browser-direct calls use
    // the FLAT path — the same route reached two ways, which is the template's
    // whole design (src/finder/lib/config.ts SCOPE). A stub that only matched
    // the flat spelling answered the build's corpus walk with a 404 page and
    // @barkpark/core reported it as "unexpected non-JSON response": a build
    // failure two layers away from its cause.
    const p = url.pathname.replace(/^\/w\/[^/]+\/p\/[^/]+/, '')

    // Drain a POST body (the finder's best-effort click/correction feedback).
    if (req.method === 'POST') req.resume()

    if (p.startsWith('/v1/')) {
      // `/v1/capabilities` — the token guard in astro.config.mjs. The smoke
      // never passes a token, so this is answered for completeness only.
      if (p === '/v1/capabilities') return sendJson(res, { auth_tier: 'read' })

      // `/v1/data/search/:dataset/suggestions`
      if (/^\/v1\/data\/search\/[^/]+\/suggestions$/.test(p)) {
        return sendJson(res, { result: { popular: [], nohits: [] } })
      }
      // `/v1/data/search/:dataset/{correction,interaction}` — fire-and-forget.
      if (/^\/v1\/data\/search\/[^/]+\/(correction|interaction)$/.test(p)) {
        return sendJson(res, { ok: true })
      }
      // `/v1/data/search/:dataset` — THE per-keystroke route.
      if (/^\/v1\/data\/search\/[^/]+$/.test(p)) {
        return sendJson(
          res,
          searchEnvelope(url.searchParams.get('q'), url.searchParams.get('engine')),
        )
      }
      // `/v1/graph` — baked into dist/graph.json at build. A non-2xx here HARD
      // FAILS the build by design (src/lib/bp.ts graphCorpus), so it must answer.
      if (p === '/v1/graph') return sendJson(res, graphEnvelope())

      // Everything else under /v1 is a document READ: the corpus walk
      // (`allDocs`), the single-doc read (`getDoc`), and the index page's
      // bp-doc-id health probe all land here. One permissive envelope carries
      // both readers' shapes — `result.documents` (the query route) and a bare
      // array — so a client-library path change does not silently empty the
      // corpus. Every unrecognised path is REPORTED, never quietly answered.
      onUnknown(`${req.method} ${p}`)
      const single = /\/([^/]+)$/.exec(p)?.[1]
      const one = CORPUS.find((d) => d._id === single || d.slug === single)
      if (one) {
        return sendJson(res, {
          result: { documents: [one], document: one, ...one },
          documents: [one],
          document: one,
          ...one,
        })
      }
      const offset = Number(url.searchParams.get('offset') || '0')
      const documents = offset > 0 ? [] : CORPUS
      return sendJson(res, {
        result: { documents, count: documents.length },
        documents,
        count: documents.length,
      })
    }

    const file = await resolveStatic(distDir, p)
    if (!file) {
      res.writeHead(404, { 'content-type': 'text/plain' }).end('not found')
      return
    }
    res.writeHead(200, {
      'content-type': MIME[extname(file)] || 'application/octet-stream',
      'cache-control': 'no-store',
    })
    createReadStream(file).pipe(res)
  })
}

/** Start it on `port` and resolve once it is accepting. */
export function listen(server, port, host = '127.0.0.1') {
  return new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(port, host, () => resolve(server))
  })
}

// ── standalone ──────────────────────────────────────────────────────────────
// `node scripts/smoke-stub-api.mjs --port 4320 [--dist dist]` runs the fixture
// on its own, which is how the query-parity CONTROL gets a server to sweep
// without a live instance or a credential. Guarded on being the entry module so
// importing this file (render-smoke.mjs does) never starts a listener.
if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  let port = 4320
  let dist = 'dist'
  for (let i = 2; i < process.argv.length; i++) {
    if (process.argv[i] === '--port') port = Number(process.argv[++i])
    else if (process.argv[i] === '--dist') dist = process.argv[++i]
  }
  const server = createStubServer({ distDir: dist })
  await listen(server, port)
  console.log(`smoke-stub-api: listening on http://127.0.0.1:${port} (dist=${dist})`)
}
