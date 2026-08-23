// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// WAVE-2 CAPSTONE (charter D16-D23): Astro SSR-to-HTML DOM-shape parity.
//
// W1 proved `@barkpark/react`'s `PortableDoc` renders every frozen non-plugin block type to
// HTML that DOM-shape-equals the Elixir `:article` golden, via `renderToStaticMarkup`
// in a Node test. W2 re-runs the SAME proof from a DIFFERENT surface: a real Astro
// STATIC build that SSRs each block through `renderPortableDocument` via `set:html`
// (no hydration). This suite reads the BUILT `dist/index.html` off disk and asserts:
//
//   1. PARITY — every `.bp-paper-surface[data-pd-type]` container extracted from the
//      built HTML is DOM-shape-equal to its Elixir golden, using the UNCHANGED
//      comparator from `@barkpark/react`'s W1 harness (tests/support/dom-shape.ts).
//      Coverage ≡ the golden set: all frozen goldens made it into the build.
//
//   2. ZERO SHIPPED JS (D16) — a first-class deliverable, not an afterthought: the
//      built site ships NO JavaScript (`dist/**/*.js` is empty) and emits no
//      `<astro-island>` marker. This is what "no hydration" MEANS on the wire; the
//      sibling `@barkpark/astro-decoy` package proves these two checks are non-vacuous
//      by making them RED with a real client:load island (charter D18).
//
// EXTRACTION (D20): the built HTML is a FULL DOCUMENT. It is parsed with happy-dom's
// DOMParser (`parseFromString(html, 'text/html')`) — NOT `body.innerHTML`, which would
// hoist `<head>` content into phantom body roots and corrupt the container walk. Each
// container's `.outerHTML` is then handed to the comparator, which unwraps the single
// `.bp-paper-surface` root to compare the block against the per-block Elixir golden.

import { describe, it, expect, beforeAll } from 'vitest'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Window } from 'happy-dom'
// The W1 comparator, reused VERBATIM — this file imports it, it is never edited (D17).
import { assertShapeEqual } from '../../react/tests/support/dom-shape'

const HERE = dirname(fileURLToPath(import.meta.url))
const PKG_ROOT = join(HERE, '..')
const DIST = join(PKG_ROOT, 'dist')
const BUILT_HTML = join(DIST, 'index.html')
const FIXTURE_DIR = join(PKG_ROOT, '..', 'react', 'tests', 'fixtures', 'pd-golden')
const SURFACE = 'bp-paper-surface'

interface GoldenFixture {
  type: string
  input: unknown
  expectedHtml: string
}

/** type -> frozen Elixir golden HTML, keyed by the golden's own `type` (handles alias pairs). */
function loadGoldens(): Map<string, GoldenFixture> {
  const map = new Map<string, GoldenFixture>()
  for (const f of readdirSync(FIXTURE_DIR).filter((n) => n.endsWith('.golden.json'))) {
    const g = JSON.parse(readFileSync(join(FIXTURE_DIR, f), 'utf8')) as GoldenFixture
    map.set(g.type, g)
  }
  return map
}

/** Every file under `dir` (recursive) whose name ends in `.js` / `.mjs` / `.cjs`. */
function shippedJs(dir: string): string[] {
  if (!existsSync(dir)) return []
  return readdirSync(dir, { recursive: true, encoding: 'utf8' }).filter((p) =>
    /\.(m|c)?js$/.test(p),
  )
}

const goldens = loadGoldens()

let builtHtml = ''
let containers: { type: string; outerHTML: string }[] = []

beforeAll(() => {
  expect(
    existsSync(BUILT_HTML),
    `dist/index.html missing — run \`astro build\` (pnpm --filter @barkpark/astro-parity build) first`,
  ).toBe(true)
  builtHtml = readFileSync(BUILT_HTML, 'utf8')

  // FULL-DOCUMENT parse (D20): DOMParser, NOT body.innerHTML.
  const window = new Window()
  try {
    const doc = new window.DOMParser().parseFromString(builtHtml, 'text/html')
    containers = Array.from(doc.querySelectorAll(`.${SURFACE}[data-pd-type]`)).map((el) => ({
      type: el.getAttribute('data-pd-type') ?? '',
      outerHTML: el.outerHTML,
    }))
  } finally {
    window.close?.()
  }
})

describe('Astro SSR → HTML DOM-shape parity (full frozen golden set)', () => {
  it('extracts one .bp-paper-surface[data-pd-type] container per golden from the BUILT HTML', () => {
    // Every fixture that went into the page must have a container in the output.
    expect(containers.length).toBe(goldens.size)
    for (const c of containers) {
      expect(c.type, 'a container is missing its data-pd-type').not.toBe('')
      expect(goldens.has(c.type), `built HTML has an unknown data-pd-type="${c.type}"`).toBe(true)
    }
  })

  it('covers every frozen golden fixture (coverage >= the golden-dir census, no silent gaps)', () => {
    const built = new Set(containers.map((c) => c.type))
    const missing = [...goldens.keys()].filter((t) => !built.has(t))
    expect(missing, `goldens absent from the Astro build: ${missing.join(', ')}`).toHaveLength(0)
    // Derived from the canonical golden directory, never a hand-counted literal
    // (stale-count prose sweep): the floor moves WITH the frozen set.
    expect(containers.length).toBeGreaterThanOrEqual(goldens.size)
  })

  // One assertion per built container: its DOM shape must equal the Elixir golden.
  // Bound lazily inside each `it` because `containers` is filled in beforeAll.
  for (const file of readdirSync(FIXTURE_DIR)
    .filter((n) => n.endsWith('.golden.json'))
    .sort()) {
    const golden = JSON.parse(readFileSync(join(FIXTURE_DIR, file), 'utf8')) as GoldenFixture
    it(`${golden.type} — Astro-built DOM shape equals Elixir golden`, () => {
      const container = containers.find((c) => c.type === golden.type)
      expect(container, `no built container for type "${golden.type}"`).toBeDefined()
      assertShapeEqual(container!.outerHTML, golden.expectedHtml, { unwrapClass: SURFACE })
    })
  }
})

describe('zero shipped JS — no hydration reaches the wire (D16, first-class deliverable)', () => {
  it('ships NO JavaScript in the built site (dist/**/*.js is empty)', () => {
    const js = shippedJs(DIST)
    expect(js, `Astro static build shipped JS it should not: ${js.join(', ')}`).toHaveLength(0)
  })

  it('ships NO JS specifically under dist/_astro (the island bundle dir is empty)', () => {
    const astroJs = shippedJs(join(DIST, '_astro'))
    expect(astroJs, `dist/_astro shipped JS: ${astroJs.join(', ')}`).toHaveLength(0)
  })

  it('emits no <astro-island> marker in the built HTML (nothing hydrates)', () => {
    expect(builtHtml).not.toContain('<astro-island')
    expect(builtHtml).not.toContain('astro-island')
  })
})
