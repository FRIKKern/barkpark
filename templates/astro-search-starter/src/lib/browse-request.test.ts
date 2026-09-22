// The build-time browse seed's ROUTE AND BEARER, pinned — `node --test`.
//
// Two arms, and they catch the same defect from opposite sides:
//
//   UNIT ARM      — the decision `browseSearchRequest` makes, per env shape.
//   PRODUCER ARM  — a loopback server that REPRODUCES THE MEASURED PRODUCER
//                   BEHAVIOUR (flat route + Authorization => 403; scoped route
//                   + Authorization => 200; flat route with NO Authorization
//                   => 200) and then drives the real request object through it,
//                   asserting a NONEMPTY seed comes back.
//
// Why the producer arm exists at all when the unit arm already asserts the URL:
// a URL assertion is a claim about a string. The 403 that shipped was a claim
// about a SERVER. `templates/astro-search-starter/scripts/smoke-stub-api.mjs`
// cannot make it either — it STRIPS `/w/:ws/p/:p` off every path before
// matching, so the flat and scoped spellings are indistinguishable to it and a
// gate built on it would pass on the broken code. This fixture keeps them
// distinct on purpose; that difference IS the test.
//
// Honest about its own standing: this fixture is not the producer, it is the
// producer's measured rule written down (live verification 2026-09-05, PR16077
// against localhost:5173 — the flat route answered 403 to a public-read
// bearer). If the producer's rule changes, this file is where it is restated.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import {
  browseSearchRequest,
  browseSeedIsNonempty,
  scopePrefixOf,
  type BrowseEnv,
} from './browse-request.ts'

const ORIGIN = 'https://api.example.test'

function env(over: Partial<BrowseEnv> = {}): BrowseEnv {
  return { apiUrl: ORIGIN, dataset: 'production', docType: 'entry', ...over }
}

// ── UNIT ARM ────────────────────────────────────────────────────────────────

test('a token on a flat apiUrl rides the workspace/project scoped path', () => {
  const r = browseSearchRequest(env({ token: 'pk_read', workspace: 'acme', project: 'site' }))
  assert.equal(r.authMode, 'scoped-bearer')
  assert.equal(
    new URL(r.url).pathname,
    '/w/acme/p/site/v1/data/search/production',
    'the bearer must be presented on the tenancy prefix — the flat spelling 403s',
  )
  assert.equal(r.headers.authorization, 'Bearer pk_read')
})

test('an ALREADY-scoped apiUrl is used as the prefix, not re-scoped', () => {
  const r = browseSearchRequest(
    env({ apiUrl: `${ORIGIN}/w/acme/p/site`, token: 'pk_read', workspace: 'ignored', project: 'ignored' }),
  )
  assert.equal(r.authMode, 'scoped-bearer')
  assert.equal(new URL(r.url).pathname, '/w/acme/p/site/v1/data/search/production')
})

test('no token => flat anonymous, and NO authorization header is invented', () => {
  const r = browseSearchRequest(env())
  assert.equal(r.authMode, 'anonymous-flat')
  assert.equal(new URL(r.url).pathname, '/v1/data/search/production')
  assert.deepEqual(r.headers, {})
})

test('a token with no derivable scope is DROPPED rather than sent to a 403', () => {
  const r = browseSearchRequest(env({ token: 'pk_read' }))
  assert.equal(r.authMode, 'unscopable-anonymous')
  assert.equal(new URL(r.url).pathname, '/v1/data/search/production')
  assert.equal(
    r.headers.authorization,
    undefined,
    'a bearer with nowhere scoped to go must not ride the flat route',
  )
})

test('the browse query is a ranked browse, field-limited, published-only', () => {
  const p = new URL(browseSearchRequest(env()).url).searchParams
  assert.equal(p.get('q'), ' ')
  assert.equal(p.get('engine'), 'postgres')
  assert.equal(p.get('perspective'), 'published')
  assert.equal(p.get('types'), 'entry')
  assert.ok((p.get('fields') || '').includes('title'))
  assert.ok(!(p.get('fields') || '').includes('body'), 'body_html is 97% of a hit and unread')
})

test('scopePrefixOf reads the prefix off the path, trailing slash or not', () => {
  assert.equal(scopePrefixOf(`${ORIGIN}/w/a/p/b`), '/w/a/p/b')
  assert.equal(scopePrefixOf(`${ORIGIN}/w/a/p/b/`), '/w/a/p/b')
  assert.equal(scopePrefixOf(ORIGIN), null)
  assert.equal(scopePrefixOf(`${ORIGIN}/w/a`), null)
})

test('browseSeedIsNonempty tells a baked seed from a 200-shaped empty', () => {
  assert.equal(browseSeedIsNonempty({ result: { documents: [{ _id: 'x' }] } }), true)
  assert.equal(browseSeedIsNonempty({ documents: [{ _id: 'x' }] }), true)
  assert.equal(browseSeedIsNonempty({ hits: [{ _id: 'x' }] }), true)
  assert.equal(browseSeedIsNonempty({ result: { documents: [] } }), false)
  assert.equal(browseSeedIsNonempty(null), false)
})

// ── PRODUCER ARM ────────────────────────────────────────────────────────────

/** The producer's measured rule. Flat + bearer is the ONLY refusal. */
function startProducer(): Promise<{ origin: string; seen: string[]; close: () => Promise<void> }> {
  const seen: string[] = []
  const server = createServer((req, res) => {
    const url = new URL(req.url || '/', 'http://127.0.0.1')
    const scoped = /^\/w\/[^/]+\/p\/[^/]+\/v1\/data\/search\/[^/]+$/.test(url.pathname)
    const flat = /^\/v1\/data\/search\/[^/]+$/.test(url.pathname)
    const bearer = !!req.headers.authorization
    seen.push(`${url.pathname} auth=${bearer ? 'yes' : 'no'}`)
    const json = (code: number, body: unknown) => {
      res.writeHead(code, { 'content-type': 'application/json' })
      res.end(JSON.stringify(body))
    }
    if (flat && bearer) {
      return json(403, { error: { code: 'forbidden', message: 'token is not valid for this scope' } })
    }
    if (scoped && !bearer) return json(401, { error: 'missing token' })
    if (!scoped && !flat) return json(404, { error: 'no route' })
    return json(200, { result: { documents: [{ _id: 'e1', _type: 'entry', title: 'One' }], count: 1 } })
  })
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address() as AddressInfo
      resolve({
        origin: `http://127.0.0.1:${port}`,
        seen,
        close: () => new Promise<void>((r) => server.close(() => r())),
      })
    })
  })
}

test('PRODUCER: a public-read token yields a NONEMPTY seed', async () => {
  const p = await startProducer()
  try {
    const req = browseSearchRequest(
      env({ apiUrl: p.origin, token: 'pk_read', workspace: 'acme', project: 'site' }),
    )
    const res = await fetch(req.url, { headers: req.headers })
    assert.equal(res.status, 200, `the producer refused ${new URL(req.url).pathname}`)
    assert.equal(browseSeedIsNonempty(await res.json()), true, 'initialData must carry hits')
    assert.equal(req.authMode, 'scoped-bearer')
  } finally {
    await p.close()
  }
})

test('PRODUCER CONTROL: the flat route + the same bearer really is a 403', async () => {
  // Without this arm the test above could pass against a fixture that answers
  // 200 to everything — it would be a green with no subject. This is the arm
  // that proves the fixture can still refuse, and that the refusal is the one
  // measured live.
  const p = await startProducer()
  try {
    const res = await fetch(`${p.origin}/v1/data/search/production?q=%20`, {
      headers: { authorization: 'Bearer pk_read' },
    })
    assert.equal(res.status, 403)
  } finally {
    await p.close()
  }
})

test('PRODUCER: the documented ANONYMOUS FALLBACK is a separate, working path', async () => {
  // Stated separately on purpose: a tokenless build is not a degraded build,
  // it is the deployed site's own transport. It must bake a nonempty seed too,
  // and it must not be confused with the 403 case in any report.
  const p = await startProducer()
  try {
    const req = browseSearchRequest(env({ apiUrl: p.origin }))
    assert.equal(req.authMode, 'anonymous-flat')
    const res = await fetch(req.url, { headers: req.headers })
    assert.equal(res.status, 200)
    assert.equal(browseSeedIsNonempty(await res.json()), true)
    assert.ok(
      p.seen.every((s) => s.endsWith('auth=no')),
      `the anonymous path must send no bearer at all — saw ${p.seen.join(', ')}`,
    )
  } finally {
    await p.close()
  }
})
