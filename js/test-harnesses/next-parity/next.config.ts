import { fileURLToPath } from 'node:url'
import type { NextConfig } from 'next'

// Absolute path to the `js/` monorepo root (two levels up from this package).
// It MUST be the workspace root, not the package dir: pnpm hoists `next` into
// `js/node_modules/.pnpm/**`, which sits OUTSIDE the package — pinning the root to
// the package makes Turbopack refuse to compile `next` ("files outside the project
// directory will not be compiled"). `import.meta.dirname` can be undefined
// depending on how Next loads the TS config, so derive the path from the module URL.
const ROOT = fileURLToPath(new URL('../../', import.meta.url))

/**
 * Wave-3 render-path-unification parity surface (charter D25-D32).
 *
 * A FRESH config authored from scratch — every existing Next config in the repo
 * (`web/`, the starter templates) is export-incompatible (`standalone` /
 * `serverActions` / `remotePatterns`), so none is copied (D27).
 *
 * - `output: 'export'` — a real Next STATIC export. Every route + asset URL is
 *   baked to on-disk HTML under `out/**`, which the vitest harness reads and
 *   parses (the parity surface, D27). Dynamic routes therefore REQUIRE
 *   `generateStaticParams` (the post routes provide it).
 * - `basePath` + `assetPrefix` `'/blog'` — sub-path hosting (issue #3382). Static
 *   export bakes the `/blog` prefix into every emitted asset ref, which the
 *   parity test asserts is PRESENT while a bare `/_next` is ABSENT (D29 inversion).
 * - `images.unoptimized` — mandatory for `output:'export'` (no image optimizer at
 *   runtime); the parity fixtures render `<img>` markup statically anyway.
 *
 * Note: Next export ships hydration JS by design — there is deliberately NO
 * zero-JS assertion here (D30); the W2 zero-JS proof does not transfer.
 */
const nextConfig: NextConfig = {
  output: 'export',
  basePath: '/blog',
  assetPrefix: '/blog',
  images: { unoptimized: true },
  // This package is one of several workspace lockfiles under `js/`; pin the
  // tracing/turbopack root to the workspace root so `next build` resolves the
  // hoisted `next` package and does not mis-infer the monorepo root.
  turbopack: { root: ROOT },
  outputFileTracingRoot: ROOT,
}

export default nextConfig
