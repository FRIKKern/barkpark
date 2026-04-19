import { defineConfig } from 'tsup'

const BARKPARK_VERSION = '1.0.0-preview.0'

export default defineConfig({
  entry: { index: 'src/index.ts' },
  format: ['esm'],
  target: 'node20.9',
  platform: 'node',
  outDir: 'dist',
  clean: true,
  dts: true,
  sourcemap: true,
  splitting: false,
  shims: false,
  banner: { js: '#!/usr/bin/env node' },
  define: {
    __BARKPARK_VERSION__: JSON.stringify(BARKPARK_VERSION),
  },
  outExtension() {
    return { js: '.js' }
  },
})
