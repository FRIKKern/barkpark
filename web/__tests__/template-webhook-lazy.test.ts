// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Proves the create-barkpark-app webhook route ships a LAZY, FAIL-CLOSED
// handler: an unset BARKPARK_WEBHOOK_SECRET must NOT throw at module import
// (which would break `next build` — Next imports every route during
// "Collecting page data" even with dynamic='force-dynamic'), and must serve a
// request-time 503 instead of falling open.
//
// Self-contained by design: the shipped route.ts imports `@barkpark/nextjs`,
// whose bare specifiers do not resolve from web/ under `node --test`. So the
// test (a) reproduces the exact guard pattern the route uses, driven by a
// FAITHFUL mock of createWebhookHandler that mirrors the SDK's
// validateConfig throw-on-unset contract (js/packages/nextjs/src/webhook/
// index.ts), and (b) reads the two shipped route.ts files from disk and
// asserts they carry that guard and no longer make the unsafe module-scope
// call — binding the behavioural proof to the bytes that actually ship.

import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import test from 'node:test'

// ── Faithful mock of @barkpark/nextjs's createWebhookHandler ────────────────
// Mirrors validateConfig: throws TypeError synchronously on an unset/empty
// secret (the real behaviour that breaks the build at module scope).
interface MockConfig {
  secret: string
  onMutation: (payload: unknown) => void | Promise<void>
}
interface MockHandlers {
  POST: (req: Request) => Promise<Response>
  GET: (req: Request) => Promise<Response>
}
function createWebhookHandlerMock(cfg: MockConfig): MockHandlers {
  if (typeof cfg.secret !== 'string' || cfg.secret.length === 0) {
    throw new TypeError('createWebhookHandler: secret must be a non-empty string')
  }
  if (typeof cfg.onMutation !== 'function') {
    throw new TypeError('createWebhookHandler: onMutation must be a function')
  }
  return {
    POST: async () => new Response(JSON.stringify({ ok: true }), { status: 200 }),
    GET: async () => new Response(JSON.stringify({ error: 'method_not_allowed' }), { status: 405 }),
  }
}

// ── The guard pattern the shipped route.ts uses, parameterised on the secret
// and the (mocked) factory so both branches are exercisable in-process. This
// is a faithful mirror of the shipped bytes; the STRUCTURAL tests below assert
// the shipped files really carry it. ───────────────────────────────────────
function buildRoute(
  envSecret: string | undefined,
  factory: (cfg: MockConfig) => MockHandlers,
): { POST: (req: Request) => Promise<Response>; GET: (req: Request) => Promise<Response>; built: () => boolean } {
  const secret = envSecret
  let handlers: MockHandlers | null = null
  let constructed = false

  function getHandlers(): MockHandlers | null {
    if (!secret) return null
    if (handlers === null) {
      handlers = factory({ secret, onMutation: () => {} })
      constructed = true
    }
    return handlers
  }
  function unavailable(): Response {
    return new Response(JSON.stringify({ error: 'webhook_not_configured' }), {
      status: 503,
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
    })
  }
  return {
    POST: async (req) => {
      const h = getHandlers()
      return h ? h.POST(req) : unavailable()
    },
    GET: async (req) => {
      const h = getHandlers()
      return h ? h.GET(req) : unavailable()
    },
    built: () => constructed,
  }
}

const REQ = () => new Request('http://localhost/api/barkpark/webhook', { method: 'POST' })

// ── BEHAVIOUR ───────────────────────────────────────────────────────────────

test('BEFORE (repro): the old module-scope call throws when the secret is unset', () => {
  // The pre-fix route did:
  //   export const { POST } = createWebhookHandler({ secret: process.env.…! , … })
  // With the env var unset that evaluates the factory with an empty secret at
  // MODULE IMPORT — which throws, aborting `next build`.
  assert.throws(
    () => createWebhookHandlerMock({ secret: undefined as unknown as string, onMutation: () => {} }),
    /secret must be a non-empty string/,
    'unset secret must throw synchronously (this is the build break we are fixing)',
  )
})

test('AFTER: with the secret UNSET, building the route does NOT throw at module init', () => {
  let route: ReturnType<typeof buildRoute> | undefined
  assert.doesNotThrow(() => {
    route = buildRoute(undefined, createWebhookHandlerMock)
  }, 'the lazy guard must not evaluate the factory at import time')
  assert.equal(route!.built(), false, 'the real handler must not be constructed when the secret is unset')
})

test('AFTER: with the secret UNSET, POST returns a fail-closed 503 (never fail-open)', async () => {
  const route = buildRoute(undefined, createWebhookHandlerMock)
  const res = await route.POST(REQ())
  assert.equal(res.status, 503, 'an unconfigured webhook must be UNAVAILABLE')
  const body = await res.json()
  assert.equal(body.error, 'webhook_not_configured')
  // Fail-CLOSED: it must not have run onMutation / returned a 200 ok.
  assert.notEqual(res.status, 200)
})

test('AFTER: with the secret UNSET, GET also returns 503 (route offline, not a 405 from a live handler)', async () => {
  const route = buildRoute(undefined, createWebhookHandlerMock)
  const res = await route.GET(REQ())
  assert.equal(res.status, 503)
})

test('AFTER: with the secret SET, the handler constructs lazily and serves', async () => {
  const route = buildRoute('s3cr3t', createWebhookHandlerMock)
  assert.equal(route.built(), false, 'construction is deferred until first request (lazy)')
  const res = await route.POST(REQ())
  assert.equal(route.built(), true, 'first request constructs the real handler')
  assert.equal(res.status, 200)
})

test('AFTER: with the secret SET, the handler is memoized (built at most once)', async () => {
  let factoryCalls = 0
  const counting = (cfg: MockConfig) => {
    factoryCalls++
    return createWebhookHandlerMock(cfg)
  }
  const route = buildRoute('s3cr3t', counting)
  await route.POST(REQ())
  await route.POST(REQ())
  await route.GET(REQ())
  assert.equal(factoryCalls, 1, 'createWebhookHandler must run at most once across requests')
})

// ── STRUCTURAL: bind the proof to the bytes that ship ────────────────────────

// The two starters no longer carry a route.ts each: the scaffold-boilerplate
// dedup collapsed them into ONE generator-owned shared source, copied into each
// generated app at generation time. So this list is one entry, and the
// drift test below changed shape accordingly — see its comment.
const TEMPLATE_ROUTES = [
  '../../js/packages/create-barkpark-app/templates/_shared/app/api/barkpark/webhook/route.ts',
].map((p) => fileURLToPath(new URL(p, import.meta.url)))

for (const path of TEMPLATE_ROUTES) {
  const label = '_shared'

  test(`SHIPPED (${label}): no unsafe module-scope createWebhookHandler with a non-null-asserted env secret`, () => {
    const src = readFileSync(path, 'utf8')
    // The dangerous pre-fix shape: destructuring the factory result at module
    // scope with `process.env.BARKPARK_WEBHOOK_SECRET!`.
    assert.doesNotMatch(
      src,
      /export const \{[^}]*\}\s*=\s*createWebhookHandler/,
      'route must not destructure createWebhookHandler at module scope',
    )
    assert.doesNotMatch(
      src,
      /BARKPARK_WEBHOOK_SECRET!/,
      'route must not non-null-assert the secret (that is what throws at build)',
    )
  })

  test(`SHIPPED (${label}): carries the fail-closed 503 guard and lazy construction`, () => {
    const src = readFileSync(path, 'utf8')
    assert.match(src, /503/, 'must serve a 503 when unconfigured')
    assert.match(src, /webhook_not_configured/, 'fail-closed 503 body')
    assert.match(src, /createWebhookHandler\(/, 'must still construct the real handler when configured')
    // Construction happens inside a function (lazy), not at module top-level.
    assert.match(src, /function getHandlers\(\)/, 'lazy accessor present')
    assert.match(src, /runtime = 'nodejs'/, 'runtime must stay nodejs')
  })
}

// WAS: 'both template route.ts files are byte-identical'. That test existed to
// catch drift between two hand-maintained copies. The dedup removed the second
// copy, so comparing the list to itself would pass vacuously and prove nothing.
// The invariant it protected — one webhook route, no per-starter fork — is now
// structural, so assert THAT: neither starter may reintroduce its own copy.
// If one ever does, the shared source stops being the only thing that ships and
// the drift this file guards against becomes possible again.
test('SHIPPED: the webhook route has exactly one source — no per-starter copy', () => {
  const forks = ['blog-starter', 'website-starter'].filter((starter) =>
    existsSync(
      fileURLToPath(
        new URL(
          `../../js/packages/create-barkpark-app/templates/${starter}/app/api/barkpark/webhook/route.ts`,
          import.meta.url,
        ),
      ),
    ),
  )
  assert.deepEqual(
    forks,
    [],
    `these starters reintroduced their own webhook route.ts (${forks.join(', ')}) — ` +
      'the shared source under templates/_shared must stay the only one',
  )
})
