#!/usr/bin/env node
// smoke-stub-api.mjs — the deterministic Barkpark that `scripts/graph-smoke.mjs`
// builds and runs this template against.
//
// API ONLY. Unlike the Astro edition's twin (which also hosts `dist/`), this
// starter ships its OWN server: `output: 'standalone'` traces a long-running
// Node SSR process, and that process serves the HTML, the client chunks and
// `public/bp-graph.js`. So there are two loopback origins here on purpose —
// this stub answers `/v1/...`, the Next server answers everything the browser
// asks for — and the split is what makes the graph-delivery claim measurable:
// a request for `/bp-graph.js` is a request to the SITE, and its presence or
// absence is read off the browser's own network log.
//
// WHY A STUB AND NOT A LIVE INSTANCE: the same reason the Astro edition gives.
// This harness's claim is "the desktop graph renders and the phone is never
// sent one". A canned corpus makes it say exactly that, about the diff, every
// time — no credentials, no egress, no red in somebody's PR because an instance
// was down. The cost is named: this harness can never catch an API contract
// drift; `scripts/gen-seed.mjs` and the live journey harness own that claim.
//
// Node stdlib only — no dependencies, so it runs before `npm ci` has resolved
// this template's tree.
import { createServer } from 'node:http'

/** The canned corpus. Five real documents and one edge fan from `doc-finder`,
 * which is enough for `lib/graph.ts` `computeRootId` to actually run its degree
 * walk (the root is deliberately not named `barkpark`, which short-circuits it)
 * and enough for the finder rail to have rows to draw. */
export const CORPUS = [
  { _id: 'doc-finder', _type: 'entry', title: 'Barkpark finder island', slug: 'barkpark-finder-island', description: 'The one React island that is the whole landing page.' },
  { _id: 'doc-graph', _type: 'entry', title: 'Barkpark corpus graph', slug: 'barkpark-corpus-graph', description: 'How every document connects to every other one.' },
  { _id: 'doc-search', _type: 'entry', title: 'Barkpark search routes', slug: 'barkpark-search-routes', description: 'The flat anonymous read route the finder calls per keystroke.' },
  { _id: 'doc-deploy', _type: 'entry', title: 'Barkpark deploy engine', slug: 'barkpark-deploy-engine', description: 'Static sites, built aside and swapped in.' },
  { _id: 'doc-tasks', _type: 'entry', title: 'Barkpark task ledger', slug: 'barkpark-task-ledger', description: 'Work is a document like everything else.' },
]

/** Substring match over the fields the finder surfaces. A blank `q` is a BROWSE
 * (the finder's own convention) and returns the whole corpus. */
export function searchCorpus(q) {
  const needle = (q ?? '').trim().toLowerCase()
  if (!needle) return CORPUS
  return CORPUS.filter((d) =>
    `${d.title} ${d.description} ${d.slug}`.toLowerCase().includes(needle),
  )
}

/** The flat `/v1/data/search/:dataset` envelope, in the shape `lib/find-search`
 * reads: `documents` / `count` / `engineUsed` at the TOP level. */
export function searchEnvelope(q) {
  const documents = searchCorpus(q)
  return {
    count: documents.length,
    query: q ?? '',
    facets: null,
    documents,
    engineUsed: 'postgres',
    ms: 1,
    searchEventId: null,
    correctedTo: null,
    parsedQuery: { terms: (q ?? '').trim() ? [(q ?? '').trim()] : [], phrases: [], excludes: [], prefixes: [] },
  }
}

/** `/v1/graph` in the alias set `lib/graph.ts` `normalizeNode`/`normalizeEdge`
 * read. THIS is the payload the desktop graph is drawn from: empty it and the
 * landing's `bp-doc-id` marker goes empty, which is the fail-closed contract
 * `app/(finder)/page.tsx` documents. */
export function graphEnvelope() {
  return {
    nodes: CORPUS.map((d) => ({ id: d._id, doc_id: d._id, type: d._type, title: d.title })),
    edges: CORPUS.slice(1).map((d) => ({ from_id: 'doc-finder', to_id: d._id, kind: 'reference' })),
    truncated: false,
  }
}

function sendJson(res, body, status = 200) {
  const payload = JSON.stringify(body)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    'cache-control': 'no-store',
  })
  res.end(payload)
}

/**
 * The stub. `onUnknown` receives every `/v1/...` path it did not recognise — a
 * route this template starts calling and this fixture does not answer is a
 * silent hole in the gate, so the caller PRINTS them. Never a hidden 404.
 */
export function createStubServer({ onUnknown = () => {} } = {}) {
  return createServer(async (req, res) => {
    let url
    try {
      url = new URL(req.url, 'http://127.0.0.1')
    } catch {
      res.writeHead(400).end()
      return
    }
    // Strip the tenancy prefix: @barkpark/core prefixes scoped reads with
    // `/w/:ws/p/:proj` while `lib/graph.ts` derives the BARE ORIGIN for its one
    // flat `/v1/graph` call. The same fixture must answer both spellings.
    const p = url.pathname.replace(/^\/w\/[^/]+\/p\/[^/]+/, '')

    if (req.method === 'POST') req.resume()

    if (!p.startsWith('/v1/')) {
      onUnknown(`${req.method} ${p}`)
      res.writeHead(404, { 'content-type': 'text/plain' }).end('not found')
      return
    }

    // The pre-bake token guard in next.config.mjs. The smoke passes no token,
    // so this is answered for completeness (and so a future tokened run of this
    // harness does not hard-fail on an unverifiable credential).
    if (p === '/v1/capabilities') return sendJson(res, { auth_tier: 'read' })

    if (/^\/v1\/data\/search\/[^/]+\/suggestions$/.test(p)) {
      return sendJson(res, { result: { popular: [], nohits: [] } })
    }
    if (/^\/v1\/data\/search\/[^/]+\/(correction|interaction)$/.test(p)) {
      return sendJson(res, { ok: true })
    }
    if (/^\/v1\/data\/search\/[^/]+$/.test(p)) {
      return sendJson(res, searchEnvelope(url.searchParams.get('q')))
    }
    if (p === '/v1/graph') return sendJson(res, graphEnvelope())

    // Every other /v1 path is a document read. One permissive envelope carries
    // both reader shapes (`result.documents` and a bare array) so a client
    // library path change does not silently empty the corpus — and the path is
    // REPORTED either way.
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
  })
}

/** Start it on `port` and resolve once it is accepting. */
export function listen(server, port, host = '127.0.0.1') {
  return new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(port, host, () => resolve(server))
  })
}

// `node scripts/smoke-stub-api.mjs --port 4420` runs the fixture on its own.
// Guarded on being the entry module so importing this file never listens.
if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  let port = 4420
  for (let i = 2; i < process.argv.length; i++) {
    if (process.argv[i] === '--port') port = Number(process.argv[++i])
  }
  const server = createStubServer({ onUnknown: (r) => console.log(`  unknown: ${r}`) })
  await listen(server, port)
  console.log(`smoke-stub-api: listening on http://127.0.0.1:${port}`)
}
