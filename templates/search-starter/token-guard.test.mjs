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
 * So each config verifies the token against the server's own contract
 * (GET /v1/capabilities?perms=1) BEFORE baking it, with these outcomes:
 *   admin (or any privileged tier)    → throw, hard-failing the build
 *   none / absent                     → throw (would join green, find nothing)
 *   read + public-read MEMBERSHIP     → bake it
 *   read WITHOUT a public-read grant  → throw (a FULL read token, not a mint)
 *   read, server does not attest      → drop the token, warn, build on
 *   endpoint unreachable / non-2xx    → drop the token, warn, build on
 *
 * The membership half closed the hole the first edition of this file declared
 * "NOT covered on purpose": the server folds read/admin/public-read into one
 * `auth_tier: "read"` echo (@read_perms, tenancy/auth.ex), so the old
 * tier === 'read' check baked ANY read-capable token. Both guards now require
 * the opt-in ?perms=1 `permissions` attestation to carry "public-read" —
 * membership, never list equality (the public mint path emits an unordered
 * mixed list).
 *
 * This file is the mutation proof for BOTH doors: delete or weaken either
 * guard and these tests red. Run it with
 *
 *   cd templates/search-starter && node --test token-guard.test.mjs
 *
 * CI runs it on any change to either config (astro-search-finder-test.yml).
 */

import { test, describe, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const ORIGIN = 'https://api.example.test'
const TOKEN = 'bp_test_token_value'

// The Next config reads BARKPARK_* at module scope, so the env must be set
// BEFORE it is imported. Every case then varies only the stubbed fetch.
process.env.BARKPARK_API_URL = ORIGIN
process.env.BARKPARK_TOKEN = TOKEN

const realFetch = globalThis.fetch

/**
 * Stub `fetch` with a fixed /v1/capabilities response. `permissions` is the
 * opt-in ?perms=1 attestation: pass an array to attest it, leave it undefined
 * to imitate a server that predates the feature (the key is simply absent).
 */
function stubTier(tier, { ok = true, status = 200, permissions } = {}) {
  globalThis.fetch = async (url) => {
    // Both guards must ASK for the attestation — a bare /v1/capabilities
    // fetch silently gets no `permissions` key and the guard goes dark.
    assert.equal(String(url), `${ORIGIN}/v1/capabilities?perms=1`)
    return {
      ok,
      status,
      json: async () => ({
        ...(tier === undefined ? {} : { auth_tier: tier }),
        ...(permissions === undefined ? {} : { permissions }),
      }),
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

    test('an attested public-read token passes and is baked (membership, not equality)', async () => {
      // The public mint path emits an unordered MIXED list — the guard must
      // assert membership, never `=== ["public-read"]`.
      stubTier('read', { permissions: ['read', 'public-read'] })
      const { token, note } = await door.verify()
      assert.equal(token, TOKEN)
      assert.equal(note, '')

      stubTier('read', { permissions: ['read', 'public-read'] })
      assert.equal(await door.bake(), TOKEN)
    })

    test('a bare ["public-read"] mint passes too', async () => {
      stubTier('read', { permissions: ['public-read'] })
      const { token, note } = await door.verify()
      assert.equal(token, TOKEN)
      assert.equal(note, '')
    })

    test('a plain read token (auth_tier "read", no public-read grant) HARD-FAILS', async () => {
      // THE closed hole: the server folds read/admin/public-read into one
      // "read" tier, so this exact token used to pass and bake into the
      // browser bundle. The attestation now positively identifies it as a
      // full read token — never something to warn past.
      stubTier('read', { permissions: ['read'] })
      await assert.rejects(door.verify(), (err) => {
        assert.match(err.message, /no "public-read" grant/)
        assert.match(err.message, /FULL read token/)
        return true
      })
    })

    test('a server that does not attest permissions drops the token instead of failing', async () => {
      // An older server ignores ?perms=1 entirely — the key is absent, which
      // is NOT the same as []. The tier says "read" but nothing can confirm a
      // public-read mint: cannot determine → dark, not broken.
      stubTier('read')
      const { token, note } = await door.verify()
      assert.equal(token, '', 'an unattested token must never be baked')
      assert.match(note, /does not attest/)

      stubTier('read')
      assert.equal(await door.bake(), '', 'the browser must get nothing')
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
