// @ts-check

/**
 * Next.js config for the Barkpark node-slot runtime target.
 *
 * `output: 'standalone'` is the whole point of the container adapter: Next
 * traces the minimal server + node_modules into `.next/standalone/`, whose
 * generated `server.js` is a self-contained long-running Node SSR process. The
 * site-spawner deploy engine boots it per blue/green slot with
 *
 *   PORT=<slot-port> HOSTNAME=127.0.0.1 BUILD_ID=<id> CONTENT_REV=<rev> \
 *     node .next/standalone/server.js
 *
 * and Caddy reverse-proxies the live upstream to that slot's port. This is the
 * container analog of the astro-starter's static `dist/` — a running PROCESS
 * with a port + lifecycle instead of plain files.
 *
 * This file is authored as ESM (`.mjs`, `export default`) on purpose: Next 16's
 * Turbopack build hard-fails a CommonJS config against an ESM source tree
 * (`"type": "module"`), so the config MUST be ESM too.
 *
 * Root pinning: `output: 'standalone'` traces its file base from the detected
 * workspace root. Pinned to this template's own directory so the generated
 * server lands at `.next/standalone/server.js` (not nested under a parent
 * monorepo path) both when built in-repo and when the Provisioner materializes
 * the template standalone on the box.
 *
 * Sub-path hosting (`assetPrefix`): the site is served at
 * `https://<instance>/sites/<slug>/`, and Caddy `handle_path /sites/<slug>/*`
 * STRIPS that prefix before proxying to the node (so the SSR app itself routes
 * at ROOT — health probes and the page render at `/`). But Next emits its
 * static-chunk URLs (`/_next/static/…`) ROOT-relative, so the browser fetches
 * them at the domain root, Caddy has no route there, and they 404 (the blank
 * un-hydrated page + red chunk 404s). `assetPrefix` fixes exactly that: it
 * PREFIXES the referenced asset URLs with the site base (`/sites/<slug>/_next/…`)
 * while Next still SERVES them at `/_next/…` — so the browser's prefixed request
 * hits `handle_path`, gets stripped back to `/_next/…`, and the node serves it.
 * NO basePath: keeping the app at root means no Caddy/health-probe rework, and a
 * single-page content blog does no client-side RSC navigation. (Full multi-route
 * apps under a sub-path would need basePath + a non-stripping Caddy handle — see
 * the PortableDoc-blog rendering paper.) `BARKPARK_SITE_BASE` is `/sites/<slug>/`
 * with both slashes; assetPrefix wants NO trailing slash.
 *
 * @type {import('next').NextConfig}
 */
const rawBase = (process.env.BARKPARK_SITE_BASE || '').trim()
const assetPrefix = rawBase && rawBase !== '/' ? '/' + rawBase.replace(/^\/+|\/+$/g, '') : ''

const nextConfig = {
  output: 'standalone',
  ...(assetPrefix ? { assetPrefix } : {}),
  outputFileTracingRoot: import.meta.dirname,
  turbopack: {
    root: import.meta.dirname,
  },
}

export default nextConfig
