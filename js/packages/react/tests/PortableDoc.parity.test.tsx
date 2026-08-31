// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// THE WAVE-1 CAPSTONE (charter D10): cross-surface DOM-shape parity proof.
//
// It has two parts:
//
//   1. `dom-shape comparator` — unconditional self-tests that prove the Layer-2
//      comparator (tests/support/dom-shape.ts) actually discriminates. These run on
//      every `pnpm --filter @barkpark/react test`, independent of any other slice,
//      and include the distrust-vacuous-green protective proof: a deliberately
//      corrupted node MUST turn the comparison red.
//
//   2. `PortableDoc x Elixir golden parity (42 non-plugin types)` — the END proof.
//      For each frozen golden fixture at tests/fixtures/pd-golden/<type>.golden.json
//      (produced by slice rpu-w1-golden-gen from the REAL Elixir :article emitter) it
//      renders the type-keyed `PortableDoc` (slice rpu-w1-pd-renderer) via
//      renderToStaticMarkup and asserts its DOM shape equals the golden's expectedHtml,
//      covering every registered non-plugin block type.
//
// SEQUENCING: this slice is sequenced AFTER golden-gen + pd-renderer. Until BOTH land
// (the golden mirror is populated AND `@barkpark/react` exports `PortableDoc`), part 2
// self-arms: it registers a single visible `it.skip` naming exactly what it waits on,
// so the suite stays green and honest rather than falsely passing. The moment both
// land, all 42 assertions fire and any divergence reds. Part 1 guards the comparator
// itself in the meantime, so the green is never vacuous.
//
// D6 CAVEAT (chat family): chat blocks (chat-thinking / chat-todo / chat-tool-diff /
// chat-approval / chat-question / chat-plan) are asserted at shape + style-attribute level. Computed COLORS depend on the theme token
// values and hold only against the default theme; the DOM SHAPE (tags, classes, data-*,
// and the literal style-attribute string, e.g. `color: var(--danger)`) is theme-
// independent and holds unconditionally. This test asserts shape; it does not resolve
// CSS custom properties.

import { describe, it, expect } from 'vitest'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createElement, type ReactNode } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { assertShapeEqual, diffShape, parseShape } from './support/dom-shape'

const HERE = dirname(fileURLToPath(import.meta.url))
const SURFACE = 'bp-paper-surface' // wrapper both sides may (or may not) carry — unwrapped for per-block compare

// ─────────────────────────────────────────────────────────────────────────────
// Part 1 — comparator self-tests (unconditional; the non-vacuous-green guarantee)
// ─────────────────────────────────────────────────────────────────────────────
describe('dom-shape comparator', () => {
  it('parses an HTML fragment into a normalized shape tree', () => {
    const p = parseShape('<p class="bp-lede">Hello <strong>world</strong></p>')[0]!
    expect(p.tag).toBe('p')
    expect(p.classes).toEqual(['bp-lede'])
    expect(p.text).toBe('Hello')
    expect(p.children).toHaveLength(1)
    expect(p.children[0]!.tag).toBe('strong')
    expect(p.children[0]!.text).toBe('world')
  })

  it('treats classes as an order-INSENSITIVE set', () => {
    assertShapeEqual('<div class="a b c">x</div>', '<div class="c a b">x</div>')
  })

  it('ignores insignificant whitespace between elements (HEEx indentation vs JS SSR)', () => {
    const elixir = '<ul class="bp-list">\n  <li>one</li>\n  <li>two</li>\n</ul>'
    const react = '<ul class="bp-list"><li>one</li><li>two</li></ul>'
    assertShapeEqual(react, elixir)
  })

  it('collapses internal whitespace runs in text', () => {
    assertShapeEqual('<p>a   b\n\tc</p>', '<p>a b c</p>')
  })

  it('compares data-* attributes as a map', () => {
    assertShapeEqual('<div data-role="ok" data-n="3">x</div>', '<div data-n="3" data-role="ok">x</div>')
  })

  it('compares the style attribute order-insensitively (D4 inline marks / D6 chat)', () => {
    assertShapeEqual(
      '<span style="font-weight: 700; color: var(--danger)">hi</span>',
      '<span style="color:var(--danger);font-weight:700">hi</span>',
    )
  })

  // ── the non-data-* attribute leg (denylist, NOT allowlist) ──────────────────
  // Before 2026-08-31 the comparator dropped EVERY attribute that was not
  // class/style/data-*, on a rationale ("CDN image URLs vary by query order")
  // that covers only the URL-bearing ones. Measured across all 64 pd-golden
  // fixtures: 41 uncompared attribute names, agreeing on every one — the
  // exclusion hid no live divergence, only future ones. These cases pin the
  // reversal: everything outside VARIABLE_ATTRS is compared.
  // NOTE: cells are always wrapped in a real <table> — `body.innerHTML` DROPS a
  // bare <th>/<td>, so an unwrapped cell fixture compares two EMPTY trees and
  // passes vacuously (this bit once, hence the wrapper and this note).
  const cell = (attrs: string): string => `<table><tbody><tr><th ${attrs}>x</th></tr></tbody></table>`

  it('compares non-data-* attributes as a map (order-insensitively)', () => {
    assertShapeEqual(cell('scope="row" abbr="Q"'), cell('abbr="Q" scope="row"'))
  })

  it('does NOT compare the VARIABLE_ATTRS denylist (href/src/srcset/poster/id)', () => {
    // The original, legitimate exemption: a CDN URL's query order is not shape.
    assertShapeEqual(
      '<a href="/a?x=1&y=2" id="r1">go</a>',
      '<a href="/a?y=2&x=1" id="r9">go</a>',
    )
  })

  it('does NOT compare width/height on media tags, but DOES on svg geometry', () => {
    // composed-doc-parity's RESPONSIVE WIDTHS case: sizing hints ride attributes.
    assertShapeEqual('<img width="320" height="200">', '<img width="1200" height="630">')
    // …but on an <svg> the same names ARE geometry and must still diverge.
    expect(() => assertShapeEqual('<svg width="10"></svg>', '<svg width="20"></svg>')).toThrow(
      /attr: width "10" != "20"/,
    )
  })

  // ── the distrust-vacuous-green protective proof (charter D10) ────────────────
  describe('reds on a corrupted node (protective proof — the green must be meaningful)', () => {
    const golden = '<div class="bp-callout bp-callout--info"><p>note</p></div>'

    it('catches a wrong TAG', () => {
      expect(() => assertShapeEqual('<section class="bp-callout bp-callout--info"><p>note</p></section>', golden)).toThrow(
        /tag <section> != <div>/,
      )
    })

    it('catches a MISSING class', () => {
      expect(() => assertShapeEqual('<div class="bp-callout"><p>note</p></div>', golden)).toThrow(/class set/)
    })

    it('catches an EXTRA / wrong class', () => {
      expect(() =>
        assertShapeEqual('<div class="bp-callout bp-callout--danger"><p>note</p></div>', golden),
      ).toThrow(/class set/)
    })

    it('catches divergent TEXT', () => {
      expect(() => assertShapeEqual('<div class="bp-callout bp-callout--info"><p>WRONG</p></div>', golden)).toThrow(
        /text "WRONG" != "note"/,
      )
    })

    it('catches a divergent data-* value', () => {
      expect(() => assertShapeEqual('<div data-tone="danger">x</div>', '<div data-tone="info">x</div>')).toThrow(
        /data-tone "danger" != "info"/,
      )
    })

    it('catches a divergent ACCESSIBILITY attribute (role / aria-*)', () => {
      expect(() => assertShapeEqual('<div role="list">x</div>', '<div role="grid">x</div>')).toThrow(
        /attr: role "list" != "grid"/,
      )
      expect(() =>
        assertShapeEqual('<i aria-hidden="false">x</i>', '<i aria-hidden="true">x</i>'),
      ).toThrow(/attr: aria-hidden "false" != "true"/)
    })

    it('catches a divergent TABLE-STRUCTURE attribute (scope / colspan)', () => {
      // Wrapped in a real <table>: see the `cell` note above — a bare cell is
      // dropped by the parser and would make this proof vacuous.
      expect(() => assertShapeEqual(cell('scope="col"'), cell('scope="row"'))).toThrow(
        /attr: scope "col" != "row"/,
      )
      expect(() => assertShapeEqual(cell('colspan="2"'), cell('colspan="3"'))).toThrow(
        /attr: colspan "2" != "3"/,
      )
    })

    it('catches a MISSING security attribute (rel="noopener")', () => {
      expect(() => assertShapeEqual('<a>x</a>', '<a rel="noopener">x</a>')).toThrow(
        /golden has rel="noopener", actual missing it/,
      )
    })

    it('catches a divergent style property', () => {
      expect(() =>
        assertShapeEqual('<span style="color: var(--ok)">x</span>', '<span style="color: var(--danger)">x</span>'),
      ).toThrow(/style: color/)
    })

    it('catches a missing / extra child', () => {
      expect(() =>
        assertShapeEqual('<div class="bp-callout bp-callout--info"></div>', golden),
      ).toThrow(/child count 0 != 1/)
    })

    it('catches reordered children (structure is order-sensitive)', () => {
      const g = '<div><h2>a</h2><p>b</p></div>'
      const swapped = '<div><p>b</p><h2>a</h2></div>'
      expect(() => assertShapeEqual(swapped, g)).toThrow(/tag <p> != <h2>/)
    })
  })

  it('diffShape reports EVERY divergence, not just the first', () => {
    const { equal, diffs } = diffShape('<div class="x" data-a="1">no</div>', '<div class="y" data-a="2">yes</div>')
    expect(equal).toBe(false)
    // class set + data-* + text all diverge → at least three findings.
    expect(diffs.length).toBeGreaterThanOrEqual(3)
  })

  it('unwrapClass descends through a single .bp-paper-surface wrapper on either side', () => {
    // golden = bare block; actual = same block wrapped by the JS renderer → equal after unwrap.
    const bare = '<p class="bp-para">hi</p>'
    const wrapped = '<div class="bp-paper-surface"><p class="bp-para">hi</p></div>'
    assertShapeEqual(wrapped, bare, { unwrapClass: SURFACE })
    assertShapeEqual(bare, wrapped, { unwrapClass: SURFACE })
    // without unwrap, they legitimately differ (div wrapper vs bare p).
    expect(() => assertShapeEqual(wrapped, bare)).toThrow()
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// Part 2 — PortableDoc × Elixir golden parity (the END proof; self-arming)
// ─────────────────────────────────────────────────────────────────────────────
const FIXTURE_DIR = join(HERE, 'fixtures', 'pd-golden')
const fixtureFiles = existsSync(FIXTURE_DIR)
  ? readdirSync(FIXTURE_DIR)
      .filter((f) => f.endsWith('.golden.json'))
      .sort()
  : []

// Dynamic import so the file loads (and Part 1 runs) even before the renderer slice
// exports `PortableDoc`. Top-level await is supported in vitest ESM test modules.
let PortableDoc: unknown
try {
  const mod = (await import('../src/index')) as Record<string, unknown>
  PortableDoc = mod.PortableDoc
} catch {
  PortableDoc = undefined
}

const CHAT_TYPES = new Set([
  'chat-thinking',
  'chat-todo',
  'chat-tool-diff',
  'chat-approval',
  'chat-question',
  'chat-plan',
])

interface GoldenFixture {
  type: string
  input: unknown
  expectedHtml: string
  shape?: unknown
}

const armed = fixtureFiles.length > 0 && typeof PortableDoc === 'function'

describe('PortableDoc × Elixir golden parity (46 non-plugin types)', () => {
  if (!armed) {
    it.skip(
      `ARMED, awaiting upstream — ${fixtureFiles.length} golden fixture(s) present, ` +
        `PortableDoc export is ${typeof PortableDoc}; fires when rpu-w1-golden-gen ` +
        `(tests/fixtures/pd-golden/) + rpu-w1-pd-renderer (PortableDoc) both merge`,
      () => {},
    )
    return
  }

  const Renderer = PortableDoc as (props: { value: unknown }) => ReactNode

  for (const file of fixtureFiles) {
    const golden = JSON.parse(readFileSync(join(FIXTURE_DIR, file), 'utf8')) as GoldenFixture
    const isChat = CHAT_TYPES.has(golden.type)
    const suffix = isChat ? ' — shape+style (colors: default-theme only, D6)' : ''

    it(`${golden.type} — DOM shape equals Elixir golden${suffix}`, () => {
      // The golden `input` is ONE authored block; PortableDoc takes the block
      // ARRAY (`value: Block[]`), so wrap it. It renders the single block inside
      // the `.bp-paper-surface` wrapper, which unwrapClass then descends past to
      // compare against the per-block Elixir golden.
      const actualHtml = renderToStaticMarkup(createElement(Renderer, { value: [golden.input] }))
      assertShapeEqual(actualHtml, golden.expectedHtml, { unwrapClass: SURFACE })
    })
  }

  it('covers every frozen golden fixture (no silent gaps)', () => {
    expect(fixtureFiles.length).toBeGreaterThanOrEqual(46)
  })
})
