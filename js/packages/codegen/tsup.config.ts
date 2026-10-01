import { readFileSync } from 'node:fs'
import { defineConfig } from 'tsup'

// `barkpark --version` prints THIS package's version, injected at build time.
const CODEGEN_VERSION: string = JSON.parse(
  readFileSync(new URL('./package.json', import.meta.url), 'utf8'),
).version

export default defineConfig({
  define: {
    __CODEGEN_VERSION__: JSON.stringify(CODEGEN_VERSION),
  },
  entry: {
    index: 'src/index.ts',
    cli: 'src/cli.ts',
  },
  format: ['cjs', 'esm'],
  dts: true,
  sourcemap: true,
  clean: true,
  splitting: true,
  treeshake: true,
  target: 'es2022',
  outDir: 'dist',
  external: ['chokidar', 'cac', 'zod', 'prettier', 'jiti', '@barkpark/core'],
  outExtension({ format }) {
    return {
      js: format === 'cjs' ? '.cjs' : '.mjs',
    }
  },
})
