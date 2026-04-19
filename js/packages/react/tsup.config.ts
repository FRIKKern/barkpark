import { defineConfig } from 'tsup'
import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

const USE_CLIENT = '"use client";\n'

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
  },
})
