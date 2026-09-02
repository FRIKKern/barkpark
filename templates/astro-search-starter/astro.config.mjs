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
 * `auth_tier` contract (GET /v1/capabilities → "admin" | "read" | "none")
 * rather than by sniffing the string, which has no reliable shape.
 *
 * Two outcomes, deliberately different:
 *   - Positively privileged (any tier other than `read`) → HARD FAIL the build.
 *     This is never a transient condition and never something to warn past.
 *   - Cannot determine (API unreachable, non-2xx, malformed) → DO NOT fail the
 *     build; drop the token so the live path goes dark, and say so loudly. An
 *     offline or degraded build should lose a feature, never ship an unverified
 *     credential — and never break a deploy over a network blip.
 */
async function verifyPublicReadToken(t, origin) {
  if (!t) return { token: '', note: '' }
  if (!origin) {
    return { token: '', note: 'no BARKPARK_API_URL to verify against — live search disabled' }
  }
  let tier
  try {
    const res = await fetch(origin + '/v1/capabilities', {
      headers: { authorization: `Bearer ${t}` },
      signal: AbortSignal.timeout(15_000),
    })
    if (!res.ok) {
      return { token: '', note: `capabilities returned ${res.status} — live search disabled` }
    }
    tier = (await res.json())?.auth_tier
  } catch (e) {
    return { token: '', note: `capabilities unreachable (${e?.name || 'error'}) — live search disabled` }
  }

  if (tier === 'read') return { token: t, note: '' }

  // `none` is a DIFFERENT failure from a privileged token: the value does not
  // authenticate at all. Not a security problem — but baking it ships a browser
  // bundle whose live-search path is dead on arrival (the socket handshake
  // itself is refused), which is worse than no live search at all, so it is
  // still a hard stop.
  if (tier === 'none' || tier == null) {
    throw new Error(
      `BARKPARK_TOKEN does not authenticate against ${origin} (auth_tier ` +
        `"${tier ?? 'absent'}").\n\n` +
        `Baking it would ship a token the socket REFUSES: UserSocket.connect/3 ` +
        `verifies it and returns :error, so the WebSocket never opens, the LIVE ` +
        `badge never lights, and every keystroke silently falls back to the HTTP ` +
        `route anyway. Fix the token, or leave BARKPARK_TOKEN empty: both search ` +
        `engines still work over the flat anonymous route, only the WebSocket ` +
        `upgrade stays dark.`,
    )
  }

  throw new Error(
    `BARKPARK_TOKEN is an "${tier}" token, and this build would inline it into ` +
      `the browser bundle as NEXT_PUBLIC_BARKPARK_WS_TOKEN — i.e. hand it to ` +
      `every visitor.\n\n` +
      `Only a public-read token (auth_tier "read") may be used here. Mint one with:\n` +
      `  POST <api>/v1/tokens  {"label":"<site> live search","permissions":["public-read"]}\n\n` +
      `Or leave BARKPARK_TOKEN empty — both search engines still work over the ` +
      `flat anonymous route and only the live WebSocket goes dark, but the build ` +
      `then needs a graph route that is readable anonymously (\`/v1/graph\` answers ` +
      `401 without a token, which fails the corpus bake).`,
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
