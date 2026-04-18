#!/usr/bin/env node
// Post-build step for every Barkpark package:
// tsup 8.x emits `<entry>.d.ts` (ESM-friendly) and `<entry>.d.cts` (CJS) when
// `dts: true` + `format: ['cjs','esm']`. Spec §2.5 (ADR-001 L22) requires the
// ESM type file to be served as `.d.mts` so modern consumers with
// `moduleResolution: "Bundler"` or `"NodeNext"` resolve `import.types` correctly.
// Strategy: copy each `.d.ts` to a sibling `.d.mts` (content-identical — a .d.ts
// declaration file has no runtime semantics that differ between module kinds).
// Leave `.d.cts` in place as the CJS fallback; keep `.d.ts` as the require.types target.
import { readdirSync, copyFileSync, statSync } from 'node:fs'
import { join } from 'node:path'

const dir = 'dist'
try { statSync(dir) } catch { process.exit(0) }  // nothing to do

let copied = 0
for (const f of readdirSync(dir)) {
  // Only act on <name>.d.ts — NOT on .d.cts (that's already the CJS half) and NOT on existing .d.mts.
  if (!f.endsWith('.d.ts')) continue
  if (f.endsWith('.d.cts')) continue
  const target = f.slice(0, -'.d.ts'.length) + '.d.mts'
  copyFileSync(join(dir, f), join(dir, target))
  copied++
}

console.log(`post-build-dts: copied ${copied} .d.ts -> .d.mts`)
