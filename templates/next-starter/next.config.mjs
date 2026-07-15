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
 * @type {import('next').NextConfig}
 */
const nextConfig = {
  output: 'standalone',
  outputFileTracingRoot: import.meta.dirname,
  turbopack: {
    root: import.meta.dirname,
  },
}

export default nextConfig
