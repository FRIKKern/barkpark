import { defineConfig } from 'tsup'
import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

const USE_CLIENT = '"use client";\n'

// tsup/esbuild strips module-level `'use client'` directives when bundling
// (see the "Module level directives cause errors when bundled ... was ignored"
// warning). Next 15's bundler needs that banner on any chunk that imports
// client-only React APIs (useState, useOptimistic, useTransition, createContext,
// etc.) so it can tag the module as a client component. We re-prepend it here.
//
// IMPORTANT: the server entry (`dist/server.{mjs,cjs}`) must remain
// directive-free — it's consumed under the `react-server` condition and adding
// `"use client"` there would re-break the RSC boundary fixed in subtask 1.
async function prependUseClient(file: string) {
  const full = join('dist', file)
  const body = await readFile(full, 'utf8')
  if (body.startsWith('"use client"') || body.startsWith("'use client'")) return
  await writeFile(full, USE_CLIENT + body)
}

// Chunks that import client-only React hooks/APIs. Discovered via:
//   grep -E "from 'react'" dist/*.{mjs,cjs}
// - client.*  → createContext, useContext, useEffect  (BarkparkLive / Provider)
// - actions.* → useState, useOptimistic, useTransition (useOptimisticDocument)
// preload.*  imports only `cache` from react (RSC-safe) — MUST NOT be banned.
const CLIENT_CHUNKS = [
  'client.mjs',
  'client.cjs',
  'actions.mjs',
  'actions.cjs',
]

export default defineConfig({
  entry: {
    index: 'src/index.ts',
    server: 'src/server/index.ts',
    client: 'src/client/index.ts',
    actions: 'src/actions/index.ts',
    webhook: 'src/webhook/index.ts',
    'draft-mode': 'src/draft-mode/index.ts',
    revalidate: 'src/revalidate/index.ts',
    preload: 'src/preload/index.ts',
  },
  format: ['cjs', 'esm'],
  dts: true,
  sourcemap: true,
  clean: true,
  splitting: true,
  treeshake: true,
  target: 'es2022',
  outDir: 'dist',
  external: [
    'react',
    'react-dom',
    'next',
    'next/cache',
    'next/headers',
    'next/server',
    'server-only',
    '@barkpark/core',
  ],
  outExtension({ format }) {
    return {
      js: format === 'cjs' ? '.cjs' : '.mjs',
    }
  },
  async onSuccess() {
    for (const f of CLIENT_CHUNKS) {
      await prependUseClient(f)
    }
  },
})
