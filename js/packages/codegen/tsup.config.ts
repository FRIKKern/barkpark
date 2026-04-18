import { defineConfig } from 'tsup'

export default defineConfig([
  {
    entry: { index: 'src/index.ts' },
    format: ['cjs', 'esm'],
    dts: true,
    sourcemap: true,
    clean: true,
    splitting: false,
    treeshake: true,
    target: 'es2022',
    outDir: 'dist',
    external: ['chokidar', 'cac', 'zod', 'prettier', '@barkpark/core'],
    outExtension({ format }) {
      return {
        js: format === 'cjs' ? '.cjs' : '.mjs',
      }
    },
  },
  {
    entry: { cli: 'src/cli.ts' },
    format: ['esm'],
    dts: false,
    sourcemap: true,
    clean: false,
    splitting: false,
    treeshake: true,
    target: 'es2022',
    outDir: 'dist',
    external: ['chokidar', 'cac', 'zod', 'prettier', '@barkpark/core'],
    banner: { js: '#!/usr/bin/env node' },
    outExtension() {
      return { js: '.mjs' }
    },
  },
])
