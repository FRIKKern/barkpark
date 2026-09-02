// @ts-check

/**
 * Next.js config for the standalone search-starter (node-slot runtime target).
 *
 * `output: 'standalone'` is the container adapter: Next traces the minimal
 * server + node_modules into `.next/standalone/`, whose generated `server.js` is
 * a self-contained long-running Node SSR process. The site-deploy engine boots
 * it per blue/green slot with
 *
 *   PORT=<slot-port> HOSTNAME=127.0.0.1 BARKPARK_BUILD_ID=<id> \
 *     BARKPARK_CONTENT_REV=<rev> node .next/standalone/server.js
 *
 * and Caddy reverse-proxies the live upstream to that slot's port.
 *
 * SUB-PATH HOSTING — basePath AND assetPrefix (charter D6). Unlike the
 * single-page next-starter (assetPrefix ALONE), the finder is MULTI-route:
 * `/d/[type]/[slug]`, graph-node clicks, home links — all root-absolute — plus
 * client-side RSC navigation. assetPrefix fixes the static-chunk URLs but leaves
 * `<Link>`/`router.push`/`usePathname`/RSC-fetch escaping to the domain root and
 * 404-ing. `basePath` auto-prefixes ALL of those, so ZERO href edits are needed
 * in the vendored finder. (Hand-written `fetch("/api/…")` and the `public/`
 * `bp-graph.js` are NOT auto-prefixed — those go through `lib/base-path.ts`.)
 *
 * A basePath site requires a NON-stripping Caddy `handle /sites/<slug>/*` branch
 * and a basePath-aware health probe path (`BARKPARK_SITE_HEALTH_PATH`) — both
 * wired by the provisioner/caddy slice.
 *
 * `BARKPARK_SITE_BASE` is `/sites/<slug>/` (both slashes); basePath + assetPrefix
 * want NO trailing slash and MUST be empty (disabled) at the domain root.
 */
const rawBase = (process.env.BARKPARK_SITE_BASE || '').trim()
const base = rawBase && rawBase !== '/' ? '/' + rawBase.replace(/^\/+|\/+$/g, '') : ''

// ── LIVE KEYSTROKE SEARCH — the three-var derive (charter D52) ──────────────
// The websocket path is browser-side, so its config must be INLINED into the
// client bundle at build time. But the managed deploy path cannot carry
// `NEXT_PUBLIC_*` names at all: all three layers of the engine allowlist are
// closed over `BARKPARK_*` (charter D47 — no allowlist change here). So the
// browser vars are DERIVED from the already-allowlisted server vars, exactly as
// `templates/astro-search-starter/astro.config.mjs` derives them for its static
// target. Same three names, same values, two build systems.
//
// Three variables, and all three are load-bearing:
//
//   WS_URL    = origin(BARKPARK_API_URL) + '/socket'. `origin` STRIPS the scoped
//               `/w/:ws/p/:proj` path the control plane hands out — the Phoenix
//               socket lives at the bare origin, so a naive concat would join a
//               URL that 404s.
//   WS_TOKEN  = BARKPARK_TOKEN, but only after `verifyPublicReadToken` below has
//               confirmed the server calls it `read`. It reaches the browser by
//               design (D38/D13): the public-read clamp is proven live — write
//               403, admin 403 — so a public-read token grants nothing beyond
//               the published reads the site already serves anonymously. Any
//               OTHER token is a leak, so the build refuses it. Empty → the
//               whole live path stays DARK and every keystroke rides the
//               same-origin HTTP route (no crash).
//   DATASET   = BARKPARK_DATASET — THE TRAP. The channel topic is
//               `search:<ws>:<proj>:<dataset>`. Without a browser-visible
//               dataset the client falls back to the `"docs"` default and asks
//               for `search:default:default:docs`, which the server REFUSES —
//               `SearchChannel.join/3` validates the dataset leaf against the
//               resolved project and replies `{reason: "unknown_dataset"}`. So
//               a two-var fix buys a LIVE badge that never lights and a
//               permanent fallback to the HTTP route — the dataset ships with
//               the URL and the token, or not at all.
//
// WORKSPACE/PROJECT ride along for portability: their `"default"` fallbacks
// happen to coincide with the truth today, and the topic must not depend on
// that coincidence.
const apiUrl = (process.env.BARKPARK_API_URL || '').trim()
/** Bare origin of the (possibly scope-suffixed) API base; '' when unset/invalid. */
const apiOrigin = (() => {
  try {
    // `new URL('')` throws — derive only when the var is actually set.
    return apiUrl ? new URL(apiUrl).origin : ''
  } catch {
    return ''
  }
})()
const wsUrl = apiOrigin ? apiOrigin + '/socket' : ''
const rawToken = (process.env.BARKPARK_TOKEN || '').trim()

/**
 * VERIFY BEFORE BAKING — the twin of `templates/astro-search-starter/
 * astro.config.mjs` `verifyPublicReadToken`, ported here verbatim in behaviour.
 *
 * BARKPARK_TOKEN is inlined into the CLIENT bundle below (Next's `env` inlines
 * `NEXT_PUBLIC_*` as string literals into the client chunks). That is safe for a
 * `public-read` token by design (D38/D13) — and a loaded gun for any other kind.
 * The trap is sharp because this very template's `lib/bp-env.ts` documents
 * BARKPARK_TOKEN as a STRICTLY SERVER-SIDE value that is "never NEXT_PUBLIC":
 * anyone reaching for the admin token they already have publishes it to every
 * visitor. So the token is VERIFIED against the server's own `auth_tier`
 * contract (GET /v1/capabilities → "admin" | "read" | "none") rather than by
 * sniffing the string, which has no reliable shape.
 *
 * Two outcomes, deliberately different:
 *   - Positively privileged (any tier other than `read`) → HARD FAIL the build.
 *     This is never a transient condition and never something to warn past.
 *   - Cannot determine (API unreachable, non-2xx, malformed) → DO NOT fail the
 *     build; drop the token so the live path goes dark, and say so loudly. An
 *     offline or degraded build should lose a feature, never ship an unverified
 *     credential — and never break a deploy over a network blip.
 *
 * Exported so `token-guard.test.mjs` can exercise it directly; the config
 * factory below is the only production caller.
 */
export async function verifyPublicReadToken(t, origin) {
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
        `route anyway. Fix the token, or leave BARKPARK_TOKEN empty: search still ` +
        `works over the flat same-origin route, only the WebSocket upgrade stays ` +
        `dark.`,
    )
  }

  throw new Error(
    `BARKPARK_TOKEN is an "${tier}" token, and this build would inline it into ` +
      `the browser bundle as NEXT_PUBLIC_BARKPARK_WS_TOKEN — i.e. hand it to ` +
      `every visitor.\n\n` +
      `Only a public-read token (auth_tier "read") may be used here. Mint one with:\n` +
      `  POST <api>/v1/tokens  {"label":"<site> live search","permissions":["public-read"]}\n\n` +
      `Or leave BARKPARK_TOKEN empty — the site still builds and search still ` +
      `works over the flat same-origin route; only the live WebSocket upgrade ` +
      `stays dark.`,
  )
}

/**
 * Assemble the config around an ALREADY-VERIFIED browser token.
 *
 * @type {(wsToken: string) => import('next').NextConfig}
 */
const nextConfig = (wsToken) => ({
  output: 'standalone',
  // undici powers the server-side keep-alive pool (lib/bp-fetch.ts). Next
  // special-cases undici as a server-external (it vendors its own copy) and the
  // standalone output tracer then SKIPS copying it — the staged release throws
  // MODULE_NOT_FOUND at first SSR render, the landing loses its bp-doc-id meta,
  // and the deploy HEALTH gate fails closed (live-caught on search-ember build
  // bddce2a05bf1f09f). Naming it here forces the tracer to copy the real package
  // into .next/standalone/node_modules. Local `next start` masks the gap (it
  // resolves from the full node_modules), so keep this in sync with any new
  // runtime-required server dep.
  serverExternalPackages: ['undici'],
  ...(base ? { basePath: base, assetPrefix: base } : {}),
  // Inline the base path into the client bundle so `lib/base-path.ts` can prefix
  // the same-origin fetches + public assets Next does NOT auto-prefix.
  // NEXT_PUBLIC_BARKPARK_THEME: the DEPLOY-pinned default palette (evergreen |
  // ember | fjord | charple) — the engine passes BARKPARK_THEME at build (W2
  // theme dimension); the root layout bakes it as the data-bp-theme fallback.
  env: {
    NEXT_PUBLIC_BP_BASE_PATH: base,
    NEXT_PUBLIC_BARKPARK_THEME: (process.env.BARKPARK_THEME || '').trim(),
    // Derived above — see the D52 block. Every value is a plain string (Next's
    // `env` inlines these as string literals wherever `process.env.<NAME>` is
    // read, on the server AND in the client chunks).
    NEXT_PUBLIC_BARKPARK_WS_URL: wsUrl,
    NEXT_PUBLIC_BARKPARK_WS_TOKEN: wsToken,
    NEXT_PUBLIC_BARKPARK_DATASET: (process.env.BARKPARK_DATASET || '').trim(),
    NEXT_PUBLIC_BARKPARK_WORKSPACE: (process.env.BARKPARK_WORKSPACE || '').trim(),
    NEXT_PUBLIC_BARKPARK_PROJECT: (process.env.BARKPARK_PROJECT || '').trim(),
  },
  outputFileTracingRoot: import.meta.dirname,
  turbopack: {
    root: import.meta.dirname,
  },
})

// Next accepts an async factory as the default export and awaits it before the
// build starts — which is what makes the pre-bake token verification possible at
// all. Keep this async: a synchronous default export cannot ask the server what
// tier the token carries, and an unverified token would ship to the browser.
export default async () => {
  const { token, note } = await verifyPublicReadToken(rawToken, apiOrigin)
  if (note) {
    console.warn(`[barkpark] BARKPARK_TOKEN not verified: ${note}`)
  }
  return nextConfig(token)
}
