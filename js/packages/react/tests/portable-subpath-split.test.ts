// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// SUBPATH SPLIT GUARD (rpu-backlog-subpath-split-portabletext): the legacy
// PortableText shim and the PortableDoc renderer ship as separate subpath
// exports (`@barkpark/react/portable-text`, `@barkpark/react/portable-doc`),
// so a consumer of ONE surface tree-shakes free of the other. The root barrel
// keeps exporting both — the subpaths are additive opt-in (compatibility
// policy: README "Subpath exports").
//
// This file is the PRODUCTION BUNDLE ANALYSIS the task demands: it walks each
// built subpath entry's transitive local chunk graph off dist/ (the exact
// files npm ships) and asserts disjointness by DISTINCTIVE CODE MARKERS:
//   • `bp-unknown-block` — emitted only by the PortableDoc registry dispatcher;
//   • `markDefs`         — read only by the Sanity-shaped PortableText shim.
// A refactor that couples the two surfaces back into one chunk reds this file.
//
// MUTATION-VALIDITY: add `export { renderPortableDocument } from
// './PortableDoc'` to src/portable-text.ts, rebuild, and the portable-text
// graph test goes RED (renderer marker enters the graph); restore + rebuild
// re-greens.

import { describe, it, expect } from 'vitest'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const DIST = join(dirname(fileURLToPath(import.meta.url)), '..', 'dist')

/** Transitively collect a dist entry file plus every local chunk it imports. */
function chunkGraph(entryFile: string): Map<string, string> {
  const seen = new Map<string, string>()
  const queue = [entryFile]
  while (queue.length > 0) {
    const f = queue.pop()!
    if (seen.has(f)) continue
    const body = readFileSync(join(DIST, f), 'utf8')
    seen.set(f, body)
    for (const m of body.matchAll(/from\s*['"]\.\/(chunk-[A-Za-z0-9]+\.(?:mjs|cjs))['"]/g)) {
      queue.push(m[1]!)
    }
    // CJS: require("./chunk-….cjs")
    for (const m of body.matchAll(/require\(['"]\.\/(chunk-[A-Za-z0-9]+\.(?:mjs|cjs))['"]\)/g)) {
      queue.push(m[1]!)
    }
  }
  return seen
}

const RENDERER_MARKER = 'bp-unknown-block' // PortableDoc registry dispatcher
const SHIM_MARKER = 'markDefs' // Sanity-shaped PortableText only

describe('portable-text / portable-doc subpath split (production bundle analysis)', () => {
  it('both subpath entries exist in dist with ESM + CJS + types', () => {
    for (const f of [
      'portable-text.mjs', 'portable-text.cjs', 'portable-text.d.ts', 'portable-text.d.mts',
      'portable-doc.mjs', 'portable-doc.cjs', 'portable-doc.d.ts', 'portable-doc.d.mts',
    ]) {
      expect(existsSync(join(DIST, f)), `dist/${f} missing`).toBe(true)
    }
  })

  it('package.json exports map serves both subpaths (import + require + types)', () => {
    const pkg = JSON.parse(
      readFileSync(join(DIST, '..', 'package.json'), 'utf8'),
    ) as { exports: Record<string, Record<string, Record<string, string>>> }
    for (const sub of ['./portable-text', './portable-doc']) {
      const entry = pkg.exports[sub]
      expect(entry, `exports["${sub}"] missing`).toBeDefined()
      expect(entry!.import!.types).toContain('.d.mts')
      expect(entry!.import!.default).toContain('.mjs')
      expect(entry!.require!.types).toContain('.d.ts')
      expect(entry!.require!.default).toContain('.cjs')
    }
  })

  for (const fmt of ['mjs', 'cjs'] as const) {
    it(`portable-text.${fmt} graph carries the shim and ZERO renderer code`, () => {
      const graph = chunkGraph(`portable-text.${fmt}`)
      const all = [...graph.entries()]
      expect(
        all.some(([, body]) => body.includes(SHIM_MARKER)),
        'the shim marker must be reachable (non-vacuous)',
      ).toBe(true)
      for (const [file, body] of all) {
        expect(body.includes(RENDERER_MARKER), `renderer marker leaked into ${file}`).toBe(false)
      }
    })

    it(`portable-doc.${fmt} graph carries the renderer and ZERO legacy shim code`, () => {
      const graph = chunkGraph(`portable-doc.${fmt}`)
      const all = [...graph.entries()]
      expect(
        all.some(([, body]) => body.includes(RENDERER_MARKER)),
        'the renderer marker must be reachable (non-vacuous)',
      ).toBe(true)
      for (const [file, body] of all) {
        expect(body.includes(SHIM_MARKER), `legacy shim marker leaked into ${file}`).toBe(false)
      }
    })
  }

  it('the client-boundary banner rides portable-text, and portable-doc stays server-evaluable', () => {
    expect(readFileSync(join(DIST, 'portable-text.mjs'), 'utf8').startsWith('"use client"')).toBe(
      true,
    )
    // portable-doc re-exports the hook-free renderer chunk `server.mjs` also
    // re-exports; bannering it would poison the RSC graph (rsc-chunk guard).
    const doc = chunkGraph('portable-doc.mjs')
    for (const [file, body] of doc) {
      expect(body.startsWith('"use client"'), `unexpected client banner on ${file}`).toBe(false)
      // Hook-free, like the rsc-chunk guard demands of the renderer chunk.
      expect(/\buse(State|Effect|Context|Memo|Ref)\b/.test(body), `hook in ${file}`).toBe(false)
    }
  })

  it('functional smoke: each subpath renders through its own entry', async () => {
    const doc = (await import(join(DIST, 'portable-doc.mjs'))) as {
      renderPortableDocument: (b: unknown[]) => string
    }
    const html = doc.renderPortableDocument([
      { type: 'paragraph', content: [{ type: 'text', value: 'split works' }] },
    ])
    expect(html).toContain('split works')
    const text = (await import(join(DIST, 'portable-text.mjs'))) as {
      PortableText: unknown
    }
    expect(typeof text.PortableText).toBe('function')
  })
})
