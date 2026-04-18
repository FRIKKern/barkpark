import { describe, it, expect } from 'vitest'
import { existsSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'

// ADR-004 L31 / spike-c §4 contract gate.
// In Next 15.5.15 setting `next.tags` together with `cache: 'no-store'` is silently dropped:
// the tag never gets registered with the data cache, so revalidateTag() in a webhook handler
// becomes a no-op for that request lineage. We fail the build if the bundled server output ever
// emits the two together.
//
// The regex looks for a `cache: "no-store"` (or 'no-store') token anywhere inside the same
// JS object literal that also contains `next: {` … `tags`. False positives here are acceptable
// (we'd just fix the source); false NEGATIVES are not.

const distPath = resolve(__dirname, '..', 'dist', 'server.mjs')

describe('CI gate — no `next.tags` alongside `cache: "no-store"` in dist/server.mjs', () => {
  it.runIf(existsSync(distPath))('built bundle never emits the forbidden pair', () => {
    const src = readFileSync(distPath, 'utf8')
    // Strip newlines so a single-line regex can scan an entire object literal
    const flat = src.replace(/\s+/g, ' ')

    // Find every short window that contains `cache: "no-store"`. For each, look ±200 chars
    // for `tags:` inside what looks like a `next:` object literal.
    const cacheRe = /cache\s*:\s*["']no-store["']/g
    let match: RegExpExecArray | null
    const offenders: string[] = []
    while ((match = cacheRe.exec(flat)) !== null) {
      const start = Math.max(0, match.index - 200)
      const end = Math.min(flat.length, match.index + 200)
      const window = flat.slice(start, end)
      if (/next\s*:\s*\{[^}]*tags\s*:/.test(window)) {
        offenders.push(window)
      }
    }
    expect(offenders, `forbidden pair detected in bundle:\n${offenders.join('\n---\n')}`).toEqual([])
  })

  it.skipIf(existsSync(distPath))('skipped (run `pnpm build` first to enable this gate)', () => {})
})
