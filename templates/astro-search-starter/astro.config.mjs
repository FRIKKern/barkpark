// @ts-check
import { defineConfig } from 'astro/config'
import react from '@astrojs/react'
import tailwindcss from '@tailwindcss/vite'
import { fileURLToPath } from 'node:url'

// ── SUB-PATH HOSTING ────────────────────────────────────────────────────────
// The deploy engine serves the site under /sites/<slug>/ via a stripping Caddy
// handle_path — Astro's native `base` bakes that prefix into every href/asset
// URL, and the strip composes with it. The finder's <Link> + router shims read
// `import.meta.env.BASE_URL` (this `base`) so client navigation stays inside the
// sub-path too.
const rawBase = (process.env.BARKPARK_SITE_BASE || '').trim()
const base = rawBase && rawBase !== '/' ? '/' + rawBase.replace(/^\/+|\/+$/g, '') + '/' : '/'

const src = (p) => fileURLToPath(new URL(p, import.meta.url))

// ── THE FINDER, vendored VERBATIM from templates/search-starter ──────────────
// It is Next.js code. On this STATIC target we re-point its four Next module
// specifiers with Vite aliases + inline its 11 module-scope `process.env` reads
// with `define`, so ZERO vendored source is edited (charter D43). Live search's
// WebSocket URL/token are DERIVED here (D38) — WS_URL is always the API origin +
// /socket; the token gates the live path (empty → the finder rides the flat
// HTTP interceptor, both engines still work).
const apiUrl = (process.env.BARKPARK_API_URL || '').trim()
const apiOrigin = (() => {
  try {
    return apiUrl ? new URL(apiUrl).origin : ''
  } catch {
    return ''
  }
})()
const wsUrl = apiOrigin ? apiOrigin + '/socket' : ''
const rawToken = (process.env.BARKPARK_TOKEN || '').trim()
const docType = (process.env.BARKPARK_DOC_TYPE || '').trim()

/**
 * BARKPARK_TOKEN is inlined into the CLIENT bundle below (as
 * NEXT_PUBLIC_BARKPARK_WS_TOKEN) so the live-search WebSocket can join from the
 * browser. That is safe for a `public-read` token by design (D38) — and a
 * loaded gun for any other kind.
 *
 * The trap is sharp: BARKPARK_TOKEN is the SAME variable name the Next edition
 * uses for STRICTLY SERVER-SIDE reads, where its own `lib/bp-env.ts` documents
 * it as "NEVER NEXT_PUBLIC". Anyone carrying a working .env across templates —
 * or reaching for the admin token they already have — publishes it to every
 * visitor. Live-caught exactly that way during the parity work: an admin token
 * landed in five files under dist/ and in a visible wss:// URL.
 *
 * So the token is VERIFIED before it is baked, against the server's own
 * contract (GET /v1/capabilities?perms=1) rather than by sniffing the string,
 * which has no reliable shape. TWO server facts, both required: `auth_tier`
 * must be "read" (rules out admin/write and does-not-authenticate), AND the
 * opt-in `permissions` attestation must carry a "public-read" MEMBERSHIP — the
 * tier alone is too coarse, because the server folds read/admin/public-read
 * into one "read" echo, so a FULL read token used to pass this guard and bake.
 * Membership, never list equality: the public mint path emits an unordered
 * mixed list (e.g. ["public-read", "read"]).
 *
 * Three outcomes, deliberately different:
 *   - Positively privileged (any tier other than `read`, or a `read` tier
 *     whose attested permissions carry no `public-read` grant) → HARD FAIL the
 *     build. This is never a transient condition and never something to warn
 *     past.
 *   - Cannot determine (API unreachable, non-2xx, malformed, or a server that
 *     predates the ?perms=1 attestation) → DO NOT fail the build; drop the
 *     token so the live path goes dark, and say so loudly. An offline or
 *     degraded build should lose a feature, never ship an unverified
 *     credential — and never break a deploy over a network blip.
 *   - Attested public-read → bake it.
 */
async function verifyPublicReadToken(t, origin) {
  if (!t) return { token: '', note: '' }
  if (!origin) {
    return { token: '', note: 'no BARKPARK_API_URL to verify against — live search disabled' }
  }
  let tier
  let perms
  try {
    const res = await fetch(origin + '/v1/capabilities?perms=1', {
      headers: { authorization: `Bearer ${t}` },
      signal: AbortSignal.timeout(15_000),
    })
    if (!res.ok) {
      return { token: '', note: `capabilities returned ${res.status} — live search disabled` }
    }
    const body = await res.json()
    tier = body?.auth_tier
    perms = body?.permissions
  } catch (e) {
    return { token: '', note: `capabilities unreachable (${e?.name || 'error'}) — live search disabled` }
  }

  // `none` is a DIFFERENT failure from a privileged token: the value does not
  // authenticate at all. Not a security problem — but baking it produces the
  // silent count=0-forever trap (the channel joins green and finds nothing),
  // which is worse than no live search, so it is still a hard stop.
  if (tier === 'none' || tier == null) {
    throw new Error(
      `BARKPARK_TOKEN does not authenticate against ${origin} (auth_tier ` +
        `"${tier ?? 'absent'}").\n\n` +
        `Baking it would join the live-search channel GREEN and then return ` +
        `count=0 forever — a working-looking search that finds nothing. Fix the ` +
        `token, or leave BARKPARK_TOKEN empty: both search engines still work ` +
        `over the flat anonymous route, only the WebSocket upgrade stays dark.`,
    )
  }

  if (tier !== 'read') {
    throw new Error(
      `BARKPARK_TOKEN is an "${tier}" token, and this build would inline it into ` +
        `the browser bundle as NEXT_PUBLIC_BARKPARK_WS_TOKEN — i.e. hand it to ` +
        `every visitor.\n\n` +
        `Only a public-read token may be used here. Mint one with:\n` +
        `  POST <api>/v1/tokens  {"label":"<site> live search","permissions":["public-read"]}\n\n` +
        `Or leave BARKPARK_TOKEN empty — the site still builds and both search ` +
        `engines still work over the flat anonymous route; only the live WebSocket ` +
        `upgrade stays dark.`,
    )
  }

  // tier === 'read': require the positive public-read attestation.
  if (Array.isArray(perms) && perms.includes('public-read')) {
    return { token: t, note: '' }
  }

  if (!Array.isArray(perms)) {
    // The server ignored ?perms=1 (predates the attestation) or returned a
    // malformed key — the tier says `read` but nothing can confirm the token
    // is a public-read mint rather than a full read token. Cannot determine →
    // dark, not broken.
    return {
      token: '',
      note:
        'server does not attest token permissions (?perms=1 unsupported) — ' +
        'cannot confirm a public-read mint; live search disabled',
    }
  }

  throw new Error(
    `BARKPARK_TOKEN authenticates as auth_tier "read", but the server's ` +
      `permission attestation ${JSON.stringify(perms)} carries no "public-read" ` +
      `grant — this is a FULL read token, not a public-read mint, and this ` +
      `build would inline it into the browser bundle as ` +
      `NEXT_PUBLIC_BARKPARK_WS_TOKEN — i.e. hand it to every visitor.\n\n` +
      `Only a public-read token may be baked. Mint one with:\n` +
      `  POST <api>/v1/tokens  {"label":"<site> live search","permissions":["public-read"]}\n\n` +
      `Or leave BARKPARK_TOKEN empty — the site still builds and both search ` +
      `engines still work over the flat anonymous route; only the live WebSocket ` +
      `upgrade stays dark.`,
  )
}

const { token, note: tokenNote } = await verifyPublicReadToken(rawToken, apiOrigin)
if (tokenNote) {
  console.warn(`[barkpark] BARKPARK_TOKEN not verified: ${tokenNote}`)
}

/** Inline a module-scope `process.env.X` read as a build-time string literal. */
const envStr = (v) => JSON.stringify(v ?? '')

export default defineConfig({
  output: 'static',
  base,
  integrations: [react()],
  vite: {
    plugins: [tailwindcss()],
    resolve: {
      // Order matters: the longer `@/lib` prefix is listed first.
      alias: [
        { find: '@/lib', replacement: src('./src/finder/lib') },
        { find: '@', replacement: src('./src/finder') },
        { find: 'next/link', replacement: src('./src/finder/shims/next-link.tsx') },
        { find: 'next/navigation', replacement: src('./src/finder/shims/next-navigation.tsx') },
      ],
    },
    define: {
      // 4 server-side BARKPARK_* names (config.ts / find.ts resolve their own
      // defaults over the raw value).
      'process.env.BARKPARK_DATASET': envStr(process.env.BARKPARK_DATASET),
      'process.env.BARKPARK_WORKSPACE': envStr(process.env.BARKPARK_WORKSPACE),
      'process.env.BARKPARK_PROJECT': envStr(process.env.BARKPARK_PROJECT),
      'process.env.BARKPARK_DOC_TYPE': envStr(docType),
      // 7 NEXT_PUBLIC_* names, derived to the static/browser-direct model.
      'process.env.NEXT_PUBLIC_BARKPARK_DOC_TYPES': envStr(docType), // D45: pin to built type
      'process.env.NEXT_PUBLIC_BARKPARK_WS_URL': envStr(wsUrl), // D38
      'process.env.NEXT_PUBLIC_BARKPARK_WS_TOKEN': envStr(token), // D38 (public-read; '' → dark)
      'process.env.NEXT_PUBLIC_BP_BASE_PATH': envStr(''), // interceptor matches bare /api/find
      'process.env.NEXT_PUBLIC_SITE_EYEBROW': envStr(
        process.env.NEXT_PUBLIC_SITE_EYEBROW || process.env.BARKPARK_SITE_EYEBROW,
      ),
      'process.env.NEXT_PUBLIC_SITE_TITLE': envStr(
        process.env.NEXT_PUBLIC_SITE_TITLE || process.env.BARKPARK_SITE_TITLE,
      ),
      'process.env.NEXT_PUBLIC_SITE_TAGLINE': envStr(
        process.env.NEXT_PUBLIC_SITE_TAGLINE || process.env.BARKPARK_SITE_TAGLINE,
      ),
      // Theme identity default (used by future themed variants; harmless now).
      'process.env.NEXT_PUBLIC_BARKPARK_THEME': envStr(process.env.BARKPARK_THEME),
    },
  },
})
