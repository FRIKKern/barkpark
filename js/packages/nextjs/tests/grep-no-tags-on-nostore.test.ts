import { describe, it, expect } from 'vitest'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

// Contract gate for the no-store/next.tags rule (docs/decisions/0003-sync-tags.md).
// In Next 15.5.15 setting `next.tags` together with `cache: 'no-store'` is silently dropped:
// the tag never gets registered with the data cache, so revalidateTag() in a webhook handler
// becomes a no-op for that request lineage. We fail the build if ANY bundled output ever
// emits the two together.
//
// The regex looks for a `cache: "no-store"` (or 'no-store') token anywhere inside the same
// JS object literal that also contains `next: {` … `tags`. False positives here are acceptable
// (we'd just fix the source); false NEGATIVES are not.
//
// IMPORTANT — why this globs instead of naming `dist/server.mjs`:
// tsup runs with `splitting: true` over nine entry points, so esbuild hoists code shared
// between entries into sibling `chunk-*.{mjs,cjs}` files. A forbidden pair living in a
// shared module (e.g. src/tag-prefix.ts, imported by server + actions + revalidate) lands
// in a chunk that `dist/server.mjs` merely *imports* — reading only server.mjs let it ship
// while this gate stayed green. The artifact set is DERIVED from the build output; never
// hand-maintain a file list here, or the same hole reopens one level up.

const distDir = resolve(__dirname, '..', 'dist')

function emittedJsArtifacts(): string[] {
  if (!existsSync(distDir)) return []
  return readdirSync(distDir)
    .filter((f) => /\.(mjs|cjs|js)$/.test(f))
    .sort()
}

function offendersIn(source: string): string[] {
  // Strip newlines so a single-line regex can scan an entire object literal
  const flat = source.replace(/\s+/g, ' ')

  // Find every short window that contains `cache: "no-store"`. For each, look ±200 chars
  // for `tags:` inside what looks like a `next:` object literal.
  const cacheRe = /cache\s*:\s*["']no-store["']/g
  let match: RegExpExecArray | null
  const hits: string[] = []
  while ((match = cacheRe.exec(flat)) !== null) {
    const start = Math.max(0, match.index - 200)
    const end = Math.min(flat.length, match.index + 200)
    const window = flat.slice(start, end)
    if (/next\s*:\s*\{[^}]*tags\s*:/.test(window)) {
      hits.push(window)
    }
  }
  return hits
}

const artifacts = emittedJsArtifacts()

describe('CI gate — no `next.tags` alongside `cache: "no-store"` in any emitted dist/ JS artifact', () => {
  it.runIf(artifacts.length > 0)('the emitted artifact set is non-empty and includes the entry bundles', () => {
    // Guards the gate itself: if the glob ever came back empty or lost the entries,
    // every scan below would pass vacuously.
    expect(artifacts).toContain('server.mjs')
    expect(artifacts).toContain('server.cjs')
  })

  it.runIf(artifacts.length > 0)('no emitted bundle or shared chunk emits the forbidden pair', () => {
    const offenders: string[] = []
    for (const file of artifacts) {
      const src = readFileSync(join(distDir, file), 'utf8')
      for (const window of offendersIn(src)) {
        offenders.push(`dist/${file}:\n${window}`)
      }
    }
    expect(
      offenders,
      `forbidden pair detected in ${offenders.length} place(s) across ${artifacts.length} emitted artifact(s):\n${offenders.join('\n---\n')}`,
    ).toEqual([])
  })

  it.skipIf(artifacts.length > 0)('skipped (run `pnpm build` first to enable this gate)', () => {})
})
