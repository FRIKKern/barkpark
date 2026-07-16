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

export default defineConfig({
  entry: { index: 'src/index.ts', server: 'src/server.ts' },
  format: ['cjs', 'esm'],
  dts: true,
  sourcemap: true,
  clean: true,
  splitting: true,
  treeshake: true,
  target: 'es2022',
  outDir: 'dist',
  external: ['react', 'react-dom', '@barkpark/core'],
  outExtension({ format }) {
    return {
      js: format === 'cjs' ? '.cjs' : '.mjs',
    }
  },
  async onSuccess() {
    // Only the client-boundary bundle needs the "use client" banner; the
    // server entry must stay directive-free so Next can treat it as a
    // normal server module under the `react-server` condition.
    await prependUseClient('index.mjs')
    await prependUseClient('index.cjs')

    // Ship the shared paper stylesheet as a consumable asset (see above).
    await copyFile(PAPER_SURFACE_SRC, join('dist', 'paper-surface.css'))
  },
})
