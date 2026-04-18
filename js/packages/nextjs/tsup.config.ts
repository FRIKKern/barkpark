import { defineConfig } from 'tsup'

export default defineConfig({
  entry: {
    index: 'src/index.ts',
    server: 'src/server/index.ts',
    client: 'src/client/index.ts',
    actions: 'src/actions/index.ts',
    webhook: 'src/webhook/index.ts',
    'draft-mode': 'src/draft-mode/index.ts',
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
})
