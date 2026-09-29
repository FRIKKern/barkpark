/**
 * BUILD-GUARD CONTRACT — both search-starter editions must REFUSE to bake a
 * non-public-read BARKPARK_TOKEN into browser JavaScript.
 *
 * Both templates inline BARKPARK_TOKEN into the CLIENT bundle as
 * NEXT_PUBLIC_BARKPARK_WS_TOKEN so live keystroke search can join the WebSocket
 * from the browser (charter D38). That is safe for a `public-read` token and a
 * credential leak for anything else — and BARKPARK_TOKEN is the SAME variable
 * name this template's own `lib/bp-env.ts` documents as strictly server-side, so
 * reaching for an admin token is the natural mistake. It was made for real: an
 * admin token once landed in five files under `dist/` and in a visible `wss://`
 * URL during the astro parity work.
 *
 * So each config verifies the token against the server's own `auth_tier`
 * contract (GET /v1/capabilities) BEFORE baking it, with three outcomes:
 *   admin (or any privileged tier) → throw, hard-failing the build
 *   none / absent                  → throw (would join green, find nothing)
 *   read                           → bake it
 *   endpoint unreachable / non-2xx → drop the token, warn, build on
 *
 * This file is the mutation proof for BOTH doors: delete or weaken either
 * guard and these tests red. Run it with
 *
 *   cd templates/search-starter && node --test token-guard.test.mjs
 *
 * CI runs it on any change to either config (astro-search-finder-test.yml).
 *
 * NOT covered on purpose: the `read` tier is coarser than "public-read" — a
 * read-scoped token that is not a public-read mint still passes. That hole is
 * backlogged as `astro-guard-read-vs-publicread-tier`; this file pins only the
 * admin/none/read behaviour both configs implement today.
 */

import { test, describe, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ORIGIN = 'https://api.example.test'
const TOKEN = 'bp_test_token_value'

// The Next config reads BARKPARK_* at module scope, so the env must be set
// BEFORE it is imported. Every case then varies only the stubbed fetch.
process.env.BARKPARK_API_URL = ORIGIN
process.env.BARKPARK_TOKEN = TOKEN

const realFetch = globalThis.fetch

/** Stub `fetch` with a fixed /v1/capabilities response. */
function stubTier(tier, { ok = true, status = 200 } = {}) {
  globalThis.fetch = async (url) => {
    assert.equal(String(url), `${ORIGIN}/v1/capabilities`)
    return {
      ok,
      status,
      json: async () => (tier === undefined ? {} : { auth_tier: tier }),
    }
  }
}

/** Stub `fetch` to fail the way an offline or firewalled build machine does. */
function stubUnreachable() {
  globalThis.fetch = async () => {
    throw Object.assign(new Error('connect ECONNREFUSED'), { name: 'TypeError' })
  }
}

afterEach(() => {
  globalThis.fetch = realFetch
})

// ── The two guards under test ───────────────────────────────────────────────
// Next: imported for real — the config's default export is an async factory, so
// importing it has no side effects and calling it exercises the shipped path
// end to end (verification AND the value that lands in the client bundle).
const nextConfigModule = await import('./next.config.mjs')

// Astro: `astro.config.mjs` cannot be imported here — it pulls in `astro/config`
// and `@astrojs/react` (a different package's node_modules) and runs its guard
// at module scope via top-level await. So its guard is EXTRACTED from source and
// evaluated in isolation. That keeps the proof honest in the direction that
// matters: if the function is deleted, renamed, or stops being the thing that
// gates the bake, extraction or the call-site assertion below fails.
const astroConfigPath = fileURLToPath(
  new URL('../astro-search-starter/astro.config.mjs', import.meta.url),
)
const astroSource = readFileSync(astroConfigPath, 'utf8')

/** Slice one top-level `async function <name>(...) { … }` out of a source file. */
function extractFunction(source, name, where) {
  const start = source.indexOf(`async function ${name}(`)
  assert.notEqual(
    start,
    -1,
    `${where} no longer declares \`async function ${name}\` — the build guard ` +
      `that keeps a privileged token out of browser JS is GONE or renamed.`,
  )
  const bodyStart = source.indexOf('{', start)
  let depth = 0
  for (let i = bodyStart; i < source.length; i++) {
    if (source[i] === '{') depth++
    else if (source[i] === '}' && --depth === 0) {
      return source.slice(start, i + 1)
    }
  }
  throw new Error(`unbalanced braces while extracting ${name} from ${where}`)
}

const astroGuard = (
  await import(
    'data:text/javascript;base64,' +
      Buffer.from(
        extractFunction(astroSource, 'verifyPublicReadToken', 'astro.config.mjs') +
          '\nexport { verifyPublicReadToken }\n',
      ).toString('base64')
  )
).verifyPublicReadToken

/**
 * Both doors, driven through their own entry point:
 *   `verify` → { token, note } or throws
 *   `bake`   → the value that actually reaches the browser bundle
 */
const doors = [
  {
    name: 'next.config.mjs (Next edition)',
    verify: () => nextConfigModule.verifyPublicReadToken(TOKEN, ORIGIN),
    bake: async () => {
      const config = await nextConfigModule.default()
      return config.env.NEXT_PUBLIC_BARKPARK_WS_TOKEN
    },
  },
  {
    name: 'astro.config.mjs (Astro edition)',
    verify: () => astroGuard(TOKEN, ORIGIN),
    bake: async () => (await astroGuard(TOKEN, ORIGIN)).token,
  },
]

for (const door of doors) {
  describe(door.name, () => {
    test('an admin token HARD-FAILS the build', async () => {
      stubTier('admin')
      await assert.rejects(door.verify(), (err) => {
        assert.match(err.message, /admin/)
        assert.match(err.message, /NEXT_PUBLIC_BARKPARK_WS_TOKEN|every visitor/)
        return true
      })
    })

    test('a token the server does not know (auth_tier "none") hard-fails too', async () => {
      stubTier('none')
      await assert.rejects(door.verify(), /does not authenticate/)
    })

    test('a capabilities response with no auth_tier at all hard-fails', async () => {
      stubTier(undefined)
      await assert.rejects(door.verify(), /does not authenticate/)
    })

    test('a public-read token (auth_tier "read") passes and is baked', async () => {
      stubTier('read')
      const { token, note } = await door.verify()
      assert.equal(token, TOKEN)
      assert.equal(note, '')

      stubTier('read')
      assert.equal(await door.bake(), TOKEN)
    })

    test('an unreachable capabilities endpoint drops the token instead of failing', async () => {
      stubUnreachable()
      const { token, note } = await door.verify()
      assert.equal(token, '', 'an unverified token must never be baked')
      assert.match(note, /unreachable/)

      stubUnreachable()
      assert.equal(await door.bake(), '', 'the browser must get nothing')
    })

    test('a non-2xx capabilities response drops the token instead of failing', async () => {
      stubTier('read', { ok: false, status: 503 })
      const { token, note } = await door.verify()
      assert.equal(token, '')
      assert.match(note, /503/)
    })

    test('an empty BARKPARK_TOKEN is a no-op — the live path just stays dark', async () => {
      globalThis.fetch = async () => assert.fail('must not call the API for an empty token')
      const verify = door.name.startsWith('next')
        ? nextConfigModule.verifyPublicReadToken
        : astroGuard
      const { token, note } = await verify('', ORIGIN)
      assert.equal(token, '')
      assert.equal(note, '')
    })
  })
}

describe('the guards are WIRED, not merely present', () => {
  test('astro.config.mjs bakes the VERIFIED token, not the raw env value', () => {
    assert.match(
      astroSource,
      /await verifyPublicReadToken\(\s*rawToken\s*,\s*apiOrigin\s*\)/,
      'astro.config.mjs no longer calls its guard before baking',
    )
    assert.match(
      astroSource,
      /'process\.env\.NEXT_PUBLIC_BARKPARK_WS_TOKEN':\s*envStr\(token\)/,
      'astro.config.mjs bakes something other than the verified token',
    )
  })

  test('next.config.mjs bakes the VERIFIED token, not the raw env value', () => {
    const nextSource = readFileSync(fileURLToPath(new URL('./next.config.mjs', import.meta.url)), 'utf8')
    assert.match(
      nextSource,
      /await verifyPublicReadToken\(\s*rawToken\s*,\s*apiOrigin\s*\)/,
      'next.config.mjs no longer calls its guard before baking',
    )
    assert.doesNotMatch(
      nextSource,
      /NEXT_PUBLIC_BARKPARK_WS_TOKEN:\s*\(process\.env\.BARKPARK_TOKEN/,
      'next.config.mjs is back to baking the raw BARKPARK_TOKEN unverified',
    )
  })
})

/**
 * THE SECOND DOOR THE PUBLIC-READ CONTRACT IMPLIES.
 *
 * Everything above pins that the token BAKED into the browser is public-read.
 * The corollary nobody enforced: if `BARKPARK_TOKEN` must be public-read, then
 * NOTHING in this template may spend it on a privileged mutation — a public-read
 * bearer is refused on every non-GET of the API's `:require_token` pipeline
 * (`PublicRead` since 051112568) and `reindex` additionally demands write/admin
 * (`RequireWriteForMutation` since 051d7008a). Measured against a live CMS box
 * 2026-09-09: public-read bearer -> `403 {"code":"forbidden"}` on
 * `POST /v1/data/search/:dataset/reindex`, 200 on an allowed GET, 401 anonymous.
 *
 * `app/api/admin/reindex/route.ts` did exactly that. It POSTed the upstream
 * reindex with `Authorization: Bearer ${READ_TOKEN}` from a handler declared
 * `export async function POST(): Promise<NextResponse>` — no `request`
 * parameter, so there was nowhere an authorization check could live either. So
 * every site spawned from this template shipped an admin control that could only
 * ever 403, reachable by any anonymous internet caller, and the only env that
 * would have made it "work" is a write credential the build then inlines into
 * the browser. It had zero callers in this template. It was deleted; `web/`
 * deleted its identical copy first (`web/__tests__/privileged-proxy-authz.test.ts`).
 *
 * These tests are the mutation proof: restore the route file, re-reference it,
 * build another credential-bearing `/reindex` handler, or delete the README
 * paragraph that says none of this is possible — any one of them reds here.
 */
describe('no control in this template spends the public-read token on a privileged mutation', () => {
  const TEMPLATE_ROOT = fileURLToPath(new URL('.', import.meta.url))
  const SELF = fileURLToPath(import.meta.url)
  const PRUNE = new Set(['node_modules', '.next', '.git', 'vendor', 'dist', '.turbo'])

  /** Every committed source file under the template, pruned AT THE EDGE. */
  function walk(dir) {
    const out = []
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (PRUNE.has(entry.name)) continue
      const full = path.join(dir, entry.name)
      if (entry.isDirectory()) out.push(...walk(full))
      else if (entry.isFile()) out.push(full)
    }
    return out
  }

  const sources = walk(TEMPLATE_ROOT).filter(
    (f) => /\.(ts|tsx|mjs|js|json|md)$/.test(f) && f !== SELF,
  )
  // The referrer scan is over CODE only. README.md names the deleted route on
  // purpose — the honesty paragraph pinned below IS that mention — so a doc
  // file naming it is the fix, not the defect.
  const code = sources.filter((f) => /\.(ts|tsx|mjs|js|json)$/.test(f))

  test('the scan is not vacuous — it really parsed this template', () => {
    // A pruned or broken walk reports the same clean `[]` as a walk that looked
    // everywhere. Pin a floor so an empty scan cannot pass the two tests below.
    assert.ok(
      sources.length >= 50 && code.length >= 20,
      `the template scan collapsed: ${sources.length} source files / ${code.length} code files ` +
        `found ` +
        `under ${TEMPLATE_ROOT}. An empty scan passes the referrer tests vacuously.`,
    )
    // And prove the walk reaches the directory the deleted route lived in.
    assert.ok(
      existsSync(path.join(TEMPLATE_ROOT, 'app', 'api')) &&
        code.some((f) => f.includes(`${path.sep}app${path.sep}api${path.sep}`)),
      'the walk never reached app/api — the referrer scan is blind to route handlers',
    )
  })

  test('app/api/admin/reindex/route.ts stays deleted', () => {
    const route = path.join(TEMPLATE_ROOT, 'app', 'api', 'admin', 'reindex', 'route.ts')
    assert.equal(
      existsSync(route),
      false,
      'app/api/admin/reindex/route.ts is back — it POSTs an upstream index ' +
        'rebuild under the public-read BARKPARK_TOKEN, so it 403s by construction ' +
        'and is reachable by any anonymous caller',
    )
    assert.equal(
      existsSync(path.join(TEMPLATE_ROOT, 'app', 'api', 'admin')),
      false,
      'app/api/admin/ is back in a template whose only token is public-read',
    )
  })

  test('nothing in the template references admin/reindex, and no handler builds a /reindex URL', () => {
    const referrers = code
      .filter((f) => readFileSync(f, 'utf8').includes('admin/reindex'))
      .map((f) => path.relative(TEMPLATE_ROOT, f))
    assert.deepEqual(
      referrers,
      [],
      'these files reference admin/reindex: ' + referrers.join(', '),
    )

    // The CLASS, not just the one path: any route handler that builds an
    // upstream reindex URL is the same defect under a different filename.
    const builders = code
      .filter((f) => f.endsWith('route.ts') || f.endsWith('route.tsx'))
      .filter((f) => /\/reindex/.test(readFileSync(f, 'utf8')))
      .map((f) => path.relative(TEMPLATE_ROOT, f))
    assert.deepEqual(
      builders,
      [],
      'a route handler builds an upstream .../reindex URL: ' + builders.join(', '),
    )
  })

  test('the README says the token cannot trigger a rebuild', () => {
    const readme = readFileSync(path.join(TEMPLATE_ROOT, 'README.md'), 'utf8')
    assert.match(
      readme,
      /cannot trigger an index rebuild/,
      'README.md no longer states that a public-read token cannot trigger a rebuild',
    )
    assert.match(
      readme,
      /`app\/api\/admin\/\*` route here/,
      'README.md no longer states that the template ships no admin route',
    )
  })

  test('the README table still marks the browser-bound token public-read', () => {
    // The row the row-filer cited (README.md:110). It is CORRECT — the token
    // must be public-read — and this keeps the honesty paragraph above from
    // being "fixed" by loosening the constraint it explains.
    const readme = readFileSync(path.join(TEMPLATE_ROOT, 'README.md'), 'utf8')
    assert.match(
      readme,
      /`NEXT_PUBLIC_BARKPARK_WS_TOKEN`\s*\|\s*`BARKPARK_TOKEN`\s*\|[^|]*public-read/,
      'the WS-token row no longer requires a public-read token',
    )
  })
})
