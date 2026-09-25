// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// PINNED-CONSUMER PARITY — the pinned @barkpark/react ARTIFACT vs the CURRENT
// Elixir goldens.
//
// WHY THIS EXISTS. `js/test-harnesses/next-parity`, `astro-parity`, `media-parity` and
// `blog-hydration-parity` all depend on `@barkpark/react` as `workspace:^`: the
// always-current SOURCE, re-transpiled by the runner. A real external consumer
// installs an ARTIFACT — a fixed tarball with a frozen `files` list, a frozen
// `exports` map and prebuilt `dist/**`. Nothing in this repo rendered the
// goldens through that artifact, so a pinned consumer could render a block
// differently from Studio with every suite on both sides green.
//
// WHAT RUNS. `scripts/prepare-pinned.mjs` (a HARD prerequisite, run by
// `vitest.globalSetup.ts` — this project's `globalSetup` — on every invocation
// path, not an optional step) materialises the pinned artifact — by default `npm pack`
// of the workspace package, or a vendored `.tgz` path, or a published npm spec,
// via `BARKPARK_PINNED_REACT`. This suite then:
//
//   1. resolves `PortableDoc` through the artifact's OWN `exports` map (the
//      consumer's resolution path, not a source import),
//   2. renders every frozen `pd-golden` fixture through it and DOM-shape-compares
//      against the Elixir golden with the UNCHANGED `@barkpark/react` comparator
//      (`tests/support/dom-shape.ts`, imported verbatim),
//   3. runs NEGATIVE CONTROLS: deliberately-wrong copies of the same artifact
//      must RED — one that must red on EVERY golden, and one that must red on
//      exactly the affected family while staying QUIET everywhere else.
//
// NO LITERAL COUNTS. Coverage is derived from `readdirSync` of the golden
// directory and from `REGISTERED_TYPES` (the renderer's own `Object.keys(DISPATCH)`).
// The stale `>= 42` / `>= 46` floors elsewhere in the repo are NOT copied: an
// enumeration is a snapshot, a predicate is a rule.
//
// NO SKIPS. A missing `.pinned/` tree throws in the preflight rather than
// skipping, so a cold checkout that never ran the prepare step reds instead of
// reporting a green with no subject. The globalSetup does not retire that
// preflight: it guarantees the artifact for runs that go THROUGH this project's
// config, and the preflight is what still reds for any run that does not.

import { describe, it, expect } from 'vitest'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { createElement, type ReactNode } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
// The W1 comparator and the renderer's own type census, imported VERBATIM from
// @barkpark/react's test/source tree — neither is in the npm tarball, which is
// precisely why this harness must live in the monorepo.
import { assertShapeEqual } from '../../../packages/react/tests/support/dom-shape'
import { REGISTERED_TYPES } from '../../../packages/react/src/blocks/registry'

const HERE = dirname(fileURLToPath(import.meta.url))
const PKG_ROOT = join(HERE, '..')
const PINNED_DIR = join(PKG_ROOT, '.pinned')
const EXTRACT_DIR = join(PINNED_DIR, 'package')
const NEGATIVE_DIR = join(PINNED_DIR, 'negative')
const FIXTURE_DIR = join(PKG_ROOT, '..', '..', 'packages', 'react', 'tests', 'fixtures', 'pd-golden')
const SURFACE = 'bp-paper-surface'

interface GoldenFixture {
  type: string
  input: unknown
  expectedHtml: string
}

interface PinnedManifest {
  spec: string
  sha256: string
  fileCount: number
  files: string[]
  negativeControls: { id: string; find: string; replace: string; hits: number }[]
}

// ── preflight: the prepare step is a PREREQUISITE, never an optional skip ─────
if (!existsSync(join(PINNED_DIR, 'manifest.json'))) {
  throw new Error(
    `no pinned artifact at ${PINNED_DIR} — run \`node scripts/prepare-pinned.mjs\` ` +
      `(pnpm --filter @barkpark/pinned-parity test does this for you). Refusing to report a green with no subject.`,
  )
}
const manifest = JSON.parse(readFileSync(join(PINNED_DIR, 'manifest.json'), 'utf8')) as PinnedManifest

// ── golden census: derived from the directory, never a literal ────────────────
const goldenFiles = readdirSync(FIXTURE_DIR)
  .filter((f) => f.endsWith('.golden.json'))
  .sort()
const goldens = goldenFiles.map(
  (f) => JSON.parse(readFileSync(join(FIXTURE_DIR, f), 'utf8')) as GoldenFixture,
)

/**
 * Resolve one subpath through an installed package's OWN `exports` map, under
 * the conditions a modern ESM consumer presents (`import` before `default`;
 * `react-server` deliberately NOT requested — this is the plain-consumer path).
 */
function resolveExport(pkgDir: string, subpath: string): string {
  const pkgJson = JSON.parse(readFileSync(join(pkgDir, 'package.json'), 'utf8')) as {
    exports?: Record<string, unknown>
  }
  const entry = pkgJson.exports?.[subpath]
  if (entry === undefined) throw new Error(`pinned artifact declares no exports["${subpath}"]`)
  const pick = (node: unknown): string => {
    if (typeof node === 'string') return node
    if (node && typeof node === 'object') {
      const o = node as Record<string, unknown>
      for (const cond of ['import', 'default', 'require']) {
        if (cond in o) return pick(o[cond])
      }
    }
    throw new Error(`exports["${subpath}"] has no import/default condition`)
  }
  return join(pkgDir, pick(entry))
}

type Renderer = (props: { value: unknown }) => ReactNode

/** Import PortableDoc out of an extracted artifact directory, via its exports map. */
async function loadPortableDoc(pkgDir: string): Promise<Renderer> {
  const entry = resolveExport(pkgDir, '.')
  if (!existsSync(entry)) {
    throw new Error(
      `the pinned artifact's exports["."] points at ${entry}, which is NOT in the tarball — ` +
        `a \`files\` / build omission a source-consuming suite can never see`,
    )
  }
  const mod = (await import(pathToFileURL(entry).href)) as Record<string, unknown>
  const PortableDoc = mod.PortableDoc
  if (typeof PortableDoc !== 'function') {
    throw new Error(`pinned artifact does not export PortableDoc (got ${typeof PortableDoc})`)
  }
  return PortableDoc as Renderer
}

const pinned = await loadPortableDoc(EXTRACT_DIR)

function render(renderer: Renderer, input: unknown): string {
  return renderToStaticMarkup(createElement(renderer, { value: [input] }))
}

// ─────────────────────────────────────────────────────────────────────────────
// 1 — the pinned artifact is a real, self-sufficient install target
// ─────────────────────────────────────────────────────────────────────────────
describe('pinned @barkpark/react artifact', () => {
  it('ships a non-empty file set and records what was pinned', () => {
    expect(manifest.spec, 'manifest lost its spec').toBeTruthy()
    expect(manifest.sha256).toMatch(/^[0-9a-f]{64}$/)
    // Derived from the extraction itself — the artifact's own census.
    expect(manifest.fileCount).toBe(manifest.files.length)
    expect(manifest.fileCount).toBeGreaterThan(0)
  })

  it('every subpath in the exports map resolves to a file that is actually IN the tarball', () => {
    const pkgJson = JSON.parse(readFileSync(join(EXTRACT_DIR, 'package.json'), 'utf8')) as {
      exports: Record<string, unknown>
    }
    const subpaths = Object.keys(pkgJson.exports)
    expect(subpaths.length, 'the artifact declares no exports at all').toBeGreaterThan(0)
    const missing = subpaths.filter((s) => !existsSync(resolveExport(EXTRACT_DIR, s)))
    expect(missing, `exports pointing outside the tarball: ${missing.join(', ')}`).toHaveLength(0)
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// 2 — parity: the pinned artifact vs the CURRENT Elixir goldens
// ─────────────────────────────────────────────────────────────────────────────
describe('pinned artifact × current Elixir goldens — DOM-shape parity', () => {
  it('covers the whole frozen golden set, and every golden type is a REGISTERED type', () => {
    // readdir-derived, no floor literal: the census moves WITH the frozen set.
    expect(goldens.length).toBe(goldenFiles.length)
    expect(goldens.length, 'the golden directory is empty — the parity loop would be vacuous').toBeGreaterThan(0)
    const registered = new Set(REGISTERED_TYPES)
    const unregistered = goldens.map((g) => g.type).filter((t) => !registered.has(t))
    expect(unregistered, `goldens for types the renderer does not register: ${unregistered.join(', ')}`).toHaveLength(0)
    // Aliases mean REGISTERED_TYPES is a SUPERSET of the golden types, never smaller.
    expect(REGISTERED_TYPES.length).toBeGreaterThanOrEqual(new Set(goldens.map((g) => g.type)).size)
  })

  for (const golden of goldens) {
    it(`${golden.type} — pinned-artifact DOM shape equals the Elixir golden`, () => {
      assertShapeEqual(render(pinned, golden.input), golden.expectedHtml, { unwrapClass: SURFACE })
    })
  }
})

// ─────────────────────────────────────────────────────────────────────────────
// 3 — negative controls: a WRONG pinned artifact must red this lane
// ─────────────────────────────────────────────────────────────────────────────
describe('negative control — a deliberately-wrong pinned artifact REDS the lane', () => {
  it('prepare-pinned emitted both controls, each having matched real occurrences', () => {
    const ids = manifest.negativeControls.map((c) => c.id).sort()
    expect(ids).toEqual(['callout-class', 'surface-class'])
    for (const c of manifest.negativeControls) {
      expect(c.hits, `control "${c.id}" corrupted nothing — it would be vacuous`).toBeGreaterThan(0)
    }
  })

  it('a CORRUPTED golden reds the same comparison the parity loop above runs', () => {
    // The other direction of the same gate: hold the artifact fixed and corrupt
    // the golden. Uses the loop's own call shape, so it proves THAT call can
    // fail — not merely that the comparator has a throw somewhere in it.
    const golden = goldens.find((g) => g.expectedHtml.includes('<p'))
    expect(golden, 'no golden carries a <p> to corrupt').toBeDefined()
    const corruptedGolden = golden!.expectedHtml.replace('<p', '<blockquote').replace('</p>', '</blockquote>')
    expect(corruptedGolden, 'the corruption matched nothing — it would be vacuous').not.toBe(golden!.expectedHtml)
    expect(() =>
      assertShapeEqual(render(pinned, golden!.input), corruptedGolden, { unwrapClass: SURFACE }),
    ).toThrow()
    // …and the UNcorrupted golden still passes, so the arm above is discriminating.
    assertShapeEqual(render(pinned, golden!.input), golden!.expectedHtml, { unwrapClass: SURFACE })
  })

  it('a renamed .bp-paper-surface root reds EVERY golden (the lane can fail at all)', async () => {
    const wrong = await loadPortableDoc(join(NEGATIVE_DIR, 'surface-class', 'package'))
    const survivors: string[] = []
    for (const golden of goldens) {
      try {
        assertShapeEqual(render(wrong, golden.input), golden.expectedHtml, { unwrapClass: SURFACE })
        survivors.push(golden.type)
      } catch {
        /* expected: the corrupted artifact must diverge */
      }
    }
    expect(survivors, `goldens that stayed GREEN against a corrupted artifact: ${survivors.join(', ')}`).toHaveLength(0)
  })

  it('a renamed callout class reds exactly the callout family and stays QUIET elsewhere', async () => {
    const wrong = await loadPortableDoc(join(NEGATIVE_DIR, 'callout-class', 'package'))
    // Which goldens the corruption CAN touch is derived from the pristine render,
    // never listed by hand: any output carrying the corrupted literal.
    const affected: string[] = []
    const untouched: string[] = []
    for (const golden of goldens) {
      ;(render(pinned, golden.input).includes('bp-callout') ? affected : untouched).push(golden.type)
    }
    expect(affected, 'no golden renders a bp-callout class — the discriminating arm would be vacuous').not.toHaveLength(
      0,
    )
    expect(untouched, 'every golden is callout-flavoured — the quiet arm would be vacuous').not.toHaveLength(0)

    const byType = new Map(goldens.map((g) => [g.type, g]))
    // FIRES when it should.
    const missedReds = affected.filter((t) => {
      try {
        assertShapeEqual(render(wrong, byType.get(t)!.input), byType.get(t)!.expectedHtml, { unwrapClass: SURFACE })
        return true
      } catch {
        return false
      }
    })
    expect(missedReds, `callout-family goldens that did NOT red: ${missedReds.join(', ')}`).toHaveLength(0)
    // QUIET when it should be — present-in-file is not fires-when-it-should.
    const falseReds = untouched.filter((t) => {
      try {
        assertShapeEqual(render(wrong, byType.get(t)!.input), byType.get(t)!.expectedHtml, { unwrapClass: SURFACE })
        return false
      } catch {
        return true
      }
    })
    expect(falseReds, `unaffected goldens that falsely red: ${falseReds.join(', ')}`).toHaveLength(0)
  })
})
