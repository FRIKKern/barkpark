import { defineConfig } from 'tsup'
import { copyFile, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

const USE_CLIENT = '"use client";\n'

// Source of truth for the shared paper stylesheet lives in the Phoenix app
// (`Render.Stylesheet.css/0` is compiled from this exact file). We ship a
// byte-for-byte COPY as `dist/paper-surface.css` so JS consumers can
// `import "@barkpark/react/paper-surface.css"` and skin `PortableDoc` output
// identically to Phoenix — one source, one stylesheet, every surface.
//
// It is COPIED, never `import`ed as a JS string: the file gzips to ~15.9KB and
// inlining it would blow the bundle size-limit budgets (D11). Because the source
// lives outside `js/`'s turbo+pnpm workspace, turbo's cache hash can't see edits
// to it — `tests/paper-surface-asset.test.ts` is the real drift guard (D12).
const PAPER_SURFACE_SRC = join('..', '..', '..', 'api', 'assets', 'paper-surface', 'paper-surface.css')

async function prependUseClient(file: string) {
  const full = join('dist', file)
  const body = await readFile(full, 'utf8')
  if (body.startsWith('"use client"') || body.startsWith("'use client'")) return
  await writeFile(full, USE_CLIENT + body)
}

// The `image` entry is only a re-export shim (`export { BarkparkImage } from
// './chunk-XXX'`) — esbuild parks the actual client code (the `useEffect` call)
// in a hashed chunk that BOTH `image.*` and `server.*` re-export from. Bannering
// only the shim would leave that chunk directive-free, so a Server Component
// importing `BarkparkImage` via `server.mjs` would still drag `useEffect` into
// the RSC graph. So resolve the chunk each client entry re-exports from and
// banner IT too. The hook-free renderer chunk is never referenced by a client
// entry, so it is never bannered and stays server-evaluable.
async function bannerClientChunksOf(entryFile: string) {
  await prependUseClient(entryFile)
  const body = await readFile(join('dist', entryFile), 'utf8')
  const chunks = new Set<string>()
  for (const m of body.matchAll(/from\s*['"]\.\/(chunk-[A-Za-z0-9]+\.(?:mjs|cjs))['"]/g)) {
    chunks.add(m[1])
  }
  for (const chunk of chunks) await prependUseClient(chunk)
}

export default defineConfig({
  // `image` is a build-only entry (NOT a package.json `exports` subpath): it
  // exists solely to force esbuild's code-splitting to isolate the ONE client
  // module — `BarkparkImage` (`'use client'`, calls `useEffect`) — into its own
  // chunk. Without it, `Image.tsx` is imported by BOTH `index` and `server`, so
  // splitting co-bundles it into the single shared renderer chunk, whose head
  // becomes `import { …, useEffect } from 'react'`. `server.mjs` re-exports the
  // hook-free `PortableDoc`/`renderPortableDocument` from that same chunk, so a
  // Next Server Component that imports `PortableDoc` under the `react-server`
  // condition drags `useEffect` into the server graph and `next build` fails.
  // Making `Image.tsx` its own entry pins it to `dist/image.*`; the shared
  // renderer chunk (what `server.mjs` re-exports the renderers from) stays
  // hook-free, and the client surface lands in its own `'use client'`-bannered
  // chunk. Guarded by `tests/rsc-chunk-hook-free.test.ts`.
  // `client` is the framework-free media-hydration entry (`hydratePortableDoc`).
  // It shares NO code with the renderer (imports only the two `external`,
  // dynamic-imported media libs), so it lands in a standalone `dist/client.*`
  // and never perturbs the hook-free renderer chunk `server.mjs` re-exports —
  // guarded by `tests/rsc-chunk-hook-free.test.ts` (chunk stays hook-free) and
  // by the media-parity package's byte-identity md5 check on `server.mjs`.
  // `portable-text` / `portable-doc` are subpath entries (rpu-backlog-
  // subpath-split-portabletext): each re-exports ONE surface so a consumer can
  // opt into tree-shaking free of the other. Code stays in the shared split
  // chunks — the entries are thin re-export shims, so neither duplicates the
  // renderer nor perturbs the hook-free chunk `server.mjs` re-exports.
  entry: {
    index: 'src/index.ts',
    server: 'src/server.ts',
    image: 'src/Image.tsx',
    client: 'src/client.ts',
    'portable-text': 'src/portable-text.ts',
    'portable-doc': 'src/portable-doc.ts',
  },
  format: ['cjs', 'esm'],
  dts: true,
  sourcemap: true,
  clean: true,
  splitting: true,
  treeshake: true,
  target: 'es2022',
  outDir: 'dist',
  // `mermaid` + `asciinema-player` (and its CSS asset) are dynamic-imported by
  // `client.ts` and MUST stay external — they are the consuming app's peers, not
  // bundled into `dist/client.mjs` (which would blow the size budget and force a
  // version on the consumer). Guarded by `.size-limit.json`'s `ignore` list.
  external: [
    'react',
    'react-dom',
    '@barkpark/core',
    'mermaid',
    /^asciinema-player($|\/)/,
  ],
  outExtension({ format }) {
    return {
      js: format === 'cjs' ? '.cjs' : '.mjs',
    }
  },
  async onSuccess() {
    // Only the client-boundary bundles need the "use client" banner; the
    // server entry must stay directive-free so Next can treat it as a
    // normal server module under the `react-server` condition.
    await prependUseClient('index.mjs')
    await prependUseClient('index.cjs')
    // The legacy PortableText shim is a client component (its source carries
    // 'use client'); its subpath entry gets the same banner treatment as index.
    // `portable-doc.*` stays UNbannered on purpose — it re-exports the hook-free
    // renderer chunk, which must remain server-evaluable (rsc-chunk guard).
    await prependUseClient('portable-text.mjs')
    await prependUseClient('portable-text.cjs')

    // The isolated client-surface entry (`BarkparkImage`, which calls
    // `useEffect`) plus the hashed chunk it re-exports from. Bannering the
    // real code chunk makes any bundler treat `BarkparkImage` as a client
    // boundary — a client reference, NOT server-evaluated — so `server.mjs`
    // re-exporting it never drags a hook into the RSC server graph. The
    // hook-free renderer chunk is re-exported by `index.*` too but never by a
    // client *entry*, so it is never bannered and stays server-evaluable.
    await bannerClientChunksOf('image.mjs')
    await bannerClientChunksOf('image.cjs')

    // Ship the shared paper stylesheet as a consumable asset (see above).
    await copyFile(PAPER_SURFACE_SRC, join('dist', 'paper-surface.css'))
  },
})
