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

const nextConfig = {
  output: 'standalone',
  ...(base ? { basePath: base, assetPrefix: base } : {}),
  // Inline the base path into the client bundle so `lib/base-path.ts` can prefix
  // the same-origin fetches + public assets Next does NOT auto-prefix.
  env: { NEXT_PUBLIC_BP_BASE_PATH: base },
  outputFileTracingRoot: import.meta.dirname,
  turbopack: {
    root: import.meta.dirname,
  },
}

export default nextConfig
