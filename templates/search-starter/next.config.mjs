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
 *
 * @type {import('next').NextConfig}
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
//   WS_TOKEN  = BARKPARK_TOKEN. It reaches the browser by design (D38/D13): the
//               public-read clamp is proven live — write 403, admin 403 — so it
//               grants nothing beyond the published reads the site already
//               serves anonymously. Empty → the whole live path stays DARK and
//               every keystroke rides the same-origin HTTP route (no crash).
//   DATASET   = BARKPARK_DATASET — THE TRAP. The channel topic is
//               `search:<ws>:<proj>:<dataset>`. Without a browser-visible
//               dataset the client falls back to the `"docs"` default and joins
//               `search:default:default:docs`, which JOINS GREEN and then
//               returns count=0 forever. A two-var fix lights the LIVE badge
//               while the finder finds nothing — so the dataset ships with the
//               URL and the token, or not at all.
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

const nextConfig = {
  output: 'standalone',
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
    NEXT_PUBLIC_BARKPARK_WS_TOKEN: (process.env.BARKPARK_TOKEN || '').trim(),
    NEXT_PUBLIC_BARKPARK_DATASET: (process.env.BARKPARK_DATASET || '').trim(),
    NEXT_PUBLIC_BARKPARK_WORKSPACE: (process.env.BARKPARK_WORKSPACE || '').trim(),
    NEXT_PUBLIC_BARKPARK_PROJECT: (process.env.BARKPARK_PROJECT || '').trim(),
  },
  outputFileTracingRoot: import.meta.dirname,
  turbopack: {
    root: import.meta.dirname,
  },
}

export default nextConfig
