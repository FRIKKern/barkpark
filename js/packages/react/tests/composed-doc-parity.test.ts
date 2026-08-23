// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// COMPOSED-DOCUMENT PARITY (rpu-backlog-composed-doc-parity, deferred from W3).
//
// W1/W2/W3 prove per-block DOM-shape parity — each golden rendered ALONE, one
// container per block. What none of them prove is COMPOSITION: that rendering
// many blocks through ONE `renderPortableDocument(blocks)` document leaves every
// block's DOM shape exactly what it is in isolation — no wrapper, no spacing
// node, no sibling bleed, no stray container between or around blocks.
//
// Method: compose multi-block PortableDocuments FROM the canonical pd-golden
// inputs (NO golden re-authoring — the fixtures are reused byte-for-byte),
// render the whole document ONCE, parse the built HTML's top-level nodes, and
// walk them golden-by-golden: each golden's expectedHtml projects to k root
// shape nodes, so the composed document must yield exactly those k nodes, in
// order, for every golden — with nothing left over. The projection is the SAME
// ShapeNode comparator the W1 harness uses (tests/support/dom-shape.ts).
//
// Coverage beyond the one happy document (criterion 3):
//   • adjacency is varied (sorted AND reversed order — every neighbor pair
//     differs between the two passes);
//   • sibling noise — unknown-type and invalid (non-map) blocks interleaved
//     between every golden must degrade to their own bp-unknown-block nodes
//     WITHOUT disturbing any neighbor's shape;
//   • marks — the paragraph golden (bold-mark inline content) is pinned inside
//     a document between two container blocks;
//   • nested composition — golden inputs placed INSIDE a `columns` block must
//     keep their isolated shapes at depth;
//   • responsive widths — width-bearing props (image width/height) ride plain
//     HTML attributes, never the class/data/text projection, so the SAME
//     document at different widths must be shape-identical (asserted, not
//     assumed).
//
// PROTECTIVE PROOF (criterion 2): a mutant composer that injects a per-block
// wrapper div — the exact defect class this guard exists for — must make the
// comparison FAIL. If that negative control ever goes green, the guard is
// vacuous and this file is lying.

import { describe, it, expect } from 'vitest'
import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { renderPortableDocument, type Block } from '../src'
import { parseShape, type ShapeNode } from './support/dom-shape'

const HERE = dirname(fileURLToPath(import.meta.url))
const FIXTURE_DIR = join(HERE, 'fixtures', 'pd-golden')

interface GoldenFixture {
  type: string
  input: Block
  expectedHtml: string
}

const goldens: { name: string; fx: GoldenFixture }[] = readdirSync(FIXTURE_DIR)
  .filter((f) => f.endsWith('.golden.json'))
  .sort()
  .map((f) => ({
    name: f.replace('.golden.json', ''),
    fx: JSON.parse(readFileSync(join(FIXTURE_DIR, f), 'utf8')) as GoldenFixture,
  }))

/** Project each golden's expectedHtml to its isolated root shape nodes. */
const goldenShapes = new Map<string, ShapeNode[]>(
  goldens.map(({ name, fx }) => [name, parseShape(fx.expectedHtml)]),
)

/**
 * Walk the composed document's top-level shape nodes golden-by-golden: consume
 * exactly each golden's isolated root count and assert the slice deep-equals
 * the isolated projection. `interleaved` names shapes expected BETWEEN goldens
 * (sibling-noise probes); the walk consumes and asserts those too.
 */
function assertComposedEqualsIsolated(
  composedHtml: string,
  order: { name: string }[],
  interleaved?: ShapeNode[],
): void {
  const roots = parseShape(composedHtml)
  let at = 0
  for (const { name } of order) {
    if (interleaved) {
      const probe = roots.slice(at, at + interleaved.length)
      expect(probe, `probe before "${name}" (roots ${at}..)`).toEqual(interleaved)
      at += interleaved.length
    }
    const want = goldenShapes.get(name)!
    const got = roots.slice(at, at + want.length)
    expect(got, `block "${name}" in document context (roots ${at}..${at + want.length})`).toEqual(
      want,
    )
    at += want.length
  }
  expect(roots.length, 'no stray top-level nodes after the last block').toBe(at)
}

describe('composed multi-block document ≡ per-block goldens (no golden re-authoring)', () => {
  it('sanity: the corpus is present and every golden projects to ≥1 root shape', () => {
    expect(goldens.length).toBeGreaterThanOrEqual(42)
    for (const [name, shapes] of goldenShapes) {
      expect(shapes.length, `${name} projects to zero roots`).toBeGreaterThanOrEqual(1)
    }
  })

  it('every golden keeps its isolated DOM shape inside ONE composed document (sorted order)', () => {
    const html = renderPortableDocument(goldens.map(({ fx }) => fx.input))
    assertComposedEqualsIsolated(html, goldens)
  })

  it('adjacency does not leak: the REVERSED composition still matches per golden', () => {
    const rev = [...goldens].reverse()
    const html = renderPortableDocument(rev.map(({ fx }) => fx.input))
    assertComposedEqualsIsolated(html, rev)
  })

  it('unknown and invalid sibling blocks degrade in place without disturbing any neighbor', () => {
    // Between EVERY pair of goldens: one unknown-typed block and one non-map block.
    const noise: unknown[] = [{ type: 'x-composed-drift-probe' }, 42]
    const blocks: unknown[] = []
    for (const { fx } of goldens) {
      blocks.push(...noise, fx.input)
    }
    const html = renderPortableDocument(blocks as Block[])
    const probeShapes = parseShape(
      renderPortableDocument(noise as Block[]),
    )
    expect(probeShapes).toHaveLength(2) // both probes render a visible placeholder
    for (const p of probeShapes) expect(p.classes).toContain('bp-unknown-block')
    assertComposedEqualsIsolated(html, goldens, probeShapes)
  })

  it('inline MARKS survive document context (paragraph golden between two containers)', () => {
    const para = goldens.find((g) => g.name === 'paragraph')!
    const section = goldens.find((g) => g.name === 'section')!
    const table = goldens.find((g) => g.name === 'table')!
    const order = [section, para, table]
    const html = renderPortableDocument(order.map(({ fx }) => fx.input))
    assertComposedEqualsIsolated(html, order)
    // The mark really is in the fixture (guards against a defanged corpus):
    expect(para.fx.expectedHtml).toMatch(/<strong|<b\b|font-weight/)
  })

  it('NESTED composition: golden inputs inside a columns block keep their shapes at depth', () => {
    const para = goldens.find((g) => g.name === 'paragraph')!
    const callout = goldens.find((g) => g.name === 'callout')!
    const nested = {
      type: 'columns',
      columns: [[para.fx.input], [callout.fx.input]],
    } as unknown as Block
    const roots = parseShape(renderPortableDocument([nested]))
    expect(roots).toHaveLength(1)
    const cols = roots[0]!
    // Two column children, each carrying the nested golden's isolated shape.
    expect(cols.children).toHaveLength(2)
    expect(cols.children[0]!.children, 'paragraph nested in column 0').toEqual(
      goldenShapes.get('paragraph'),
    )
    expect(cols.children[1]!.children, 'callout nested in column 1').toEqual(
      goldenShapes.get('callout'),
    )
  })

  it('RESPONSIVE WIDTHS: width props ride attributes, never the shape — variants are shape-identical', () => {
    const image = goldens.find((g) => g.name === 'image')!
    const base = image.fx.input as Record<string, unknown>
    const variants = [
      { ...base },
      { ...base, width: 320 },
      { ...base, width: 1200, height: 630 },
    ] as Block[]
    const shapes = variants.map((v) => parseShape(renderPortableDocument([v])))
    expect(shapes[1]).toEqual(shapes[0])
    expect(shapes[2]).toEqual(shapes[0])
    // …and the width really reached the markup (the variant is not a no-op):
    const html = renderPortableDocument([variants[1]!])
    expect(html).toContain('width="320"')
  })
})

describe('protective proof — the guard REDS on a shape-mutating composition wrapper', () => {
  it('a per-block wrapper div makes the composed comparison fail', () => {
    // The mutant composer this guard exists to catch: a document assembler that
    // wraps every block in its own container.
    const wrapped = goldens
      .map(({ fx }) => `<div class="bp-compose-wrap">${renderPortableDocument([fx.input])}</div>`)
      .join('')
    expect(() => assertComposedEqualsIsolated(wrapped, goldens)).toThrow()
  })

  it('a wrapper that only ADDS a class to the first block root also fails', () => {
    const html = renderPortableDocument(goldens.map(({ fx }) => fx.input))
    const first = goldenShapes.get(goldens[0]!.name)![0]!
    // Forge the expectation: same tree, one extra class on the first root — the
    // comparator must distinguish it from the real composed output.
    const forged = new Map(goldenShapes)
    forged.set(goldens[0]!.name, [
      { ...first, classes: [...first.classes, 'bp-injected'] },
      ...goldenShapes.get(goldens[0]!.name)!.slice(1),
    ])
    const roots = parseShape(html)
    const got = roots.slice(0, forged.get(goldens[0]!.name)!.length)
    expect(got).not.toEqual(forged.get(goldens[0]!.name))
  })
})
