import { readFileSync } from 'node:fs'
import { defineConfig } from 'tsup'

// The CLI's --version is THIS package's version, read at build time. It used to
// be a literal ('1.0.0-preview.0') that no release ever bumped, so a published
// 1.0.0-preview.1 printed preview.0 (stranger walk, 2026-10-01).
const BARKPARK_VERSION: string = JSON.parse(
  readFileSync(new URL('./package.json', import.meta.url), 'utf8'),
).version

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
