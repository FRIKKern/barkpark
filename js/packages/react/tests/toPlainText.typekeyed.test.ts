// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Type-keyed `toPlainText` — the JS-OWNED per-type plain-text contract over the
// 46-type PortableDocument grammar (charter D35).
//
// This proof closes the `rpu-backlog-toplaintext-typekeyed` parity backlog item.
// It reuses the FROZEN `tests/fixtures/pd-golden/*.golden.json` `.input` blocks
// as-is (never re-authoring the 46-block array) and asserts, per type:
//
//   • PROSE-bearing types  → `toPlainText([input])` is non-empty AND exactly
//     equals its JS-owned golden in `PROSE_GOLDEN`. Because every prose type has
//     its own `blockText` dispatch clause, reverting a clause flips the output to
//     `''` ≠ the non-empty golden → RED (anti-vacuous-green).
//   • TEXTLESS types       → `toPlainText([input])` is exactly `''`, AND the type
//     appears on the explicit `TEXTLESS_SKIP` allow-list. A type that returns `''`
//     but is NOT on the allow-list FAILS — that is what distinguishes an
//     intentional skip from a silent drop (D35's key rigor).
//
// The partition covers ALL 46 grammar types exactly once, so a NEW pd-golden type
// (or one that silently changes shape) trips the coverage guard rather than
// slipping through as an unexamined `''`.

import { describe, it, expect } from 'vitest'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { toPlainText } from '../src/toPlainText'
import { PROSE_GOLDEN, TEXTLESS_SKIP } from './fixtures/pd-plaintext-golden'

const HERE = dirname(fileURLToPath(import.meta.url))
const FIXTURE_DIR = join(HERE, 'fixtures', 'pd-golden')

interface GoldenFixture {
  type: string
  input: unknown
  expectedHtml: string
}

const cases: GoldenFixture[] = existsSync(FIXTURE_DIR)
  ? readdirSync(FIXTURE_DIR)
      .filter((f) => f.endsWith('.golden.json'))
      .sort()
      .map((f) => JSON.parse(readFileSync(join(FIXTURE_DIR, f), 'utf8')) as GoldenFixture)
  : []

describe('toPlainText — type-keyed grammar coverage', () => {
  it('the pd-golden fixture corpus is the expected 49 types', () => {
    // scaffy:add-block-type Toc MARK:typekeyed-corpus-toc
    // scaffy:add-block-type Steps MARK:typekeyed-corpus-steps
    // scaffy:add-block-type Footnote MARK:typekeyed-corpus-footnote
    // scaffy:add-block-type Expandable MARK:typekeyed-corpus-expandable
    // scaffy:add-block-type BarChart MARK:typekeyed-corpus-bar-chart
    // scaffy:add-block-type Equation MARK:typekeyed-corpus-equation
    // scaffy:add-block-type CriteriaProgress MARK:typekeyed-corpus-criteria-progress
    // scaffy:add-block-type Video MARK:typekeyed-corpus-video
    // scaffy:add-block-type ApiEndpoint MARK:typekeyed-corpus-api-endpoint
    // scaffy:add-block-type CodeTabs MARK:typekeyed-corpus-code-tabs
    // scaffy:add-block-type Tabs MARK:typekeyed-corpus-tabs
    expect(cases.length).toBe(63)
  })

  it('every golden type is partitioned into EXACTLY ONE of PROSE / TEXTLESS', () => {
    for (const c of cases) {
      const inProse = Object.prototype.hasOwnProperty.call(PROSE_GOLDEN, c.type)
      const inSkip = Object.prototype.hasOwnProperty.call(TEXTLESS_SKIP, c.type)
      expect(
        inProse !== inSkip,
        `type "${c.type}" must be in EXACTLY ONE of PROSE_GOLDEN / TEXTLESS_SKIP ` +
          `(prose=${inProse}, skip=${inSkip}) — silent-drop ≠ intentional-skip`,
      ).toBe(true)
    }
  })

  it('the golden maps reference only real fixture types (no stale entries)', () => {
    const known = new Set(cases.map((c) => c.type))
    for (const t of Object.keys(PROSE_GOLDEN)) {
      expect(known.has(t), `PROSE_GOLDEN has stale type "${t}" not in pd-golden`).toBe(true)
    }
    for (const t of Object.keys(TEXTLESS_SKIP)) {
      expect(known.has(t), `TEXTLESS_SKIP has stale type "${t}" not in pd-golden`).toBe(true)
    }
  })

  it('the partition is 26 prose + 37 textless = 63', () => {
    // grown (pbw-stier-equation): tex source is reading content, the `code` precedent
    // grown (pbw-stier-tabs): each tab's label + nested blocks' prose, the `steps` precedent
    // grown (jarl-dogfood): expandable's summary + nested blocks are reading prose
    expect(Object.keys(PROSE_GOLDEN).length).toBe(26)
    // scaffy:add-block-type Toc MARK:typekeyed-textless-toc
    // scaffy:add-block-type Steps MARK:typekeyed-textless-steps
    // scaffy:add-block-type Footnote MARK:typekeyed-textless-footnote
    // scaffy:add-block-type Expandable MARK:typekeyed-textless-expandable
    // scaffy:add-block-type BarChart MARK:typekeyed-textless-bar-chart
    // scaffy:add-block-type CriteriaProgress MARK:typekeyed-textless-criteria-progress
    // scaffy:add-block-type Video MARK:typekeyed-textless-video
    // scaffy:add-block-type ApiEndpoint MARK:typekeyed-textless-api-endpoint
    // scaffy:add-block-type CodeTabs MARK:typekeyed-textless-code-tabs
    expect(Object.keys(TEXTLESS_SKIP).length).toBe(37)
    expect(Object.keys(PROSE_GOLDEN).length + Object.keys(TEXTLESS_SKIP).length).toBe(cases.length)
  })

  it('every TEXTLESS_SKIP rationale is a non-empty committed justification', () => {
    for (const [t, why] of Object.entries(TEXTLESS_SKIP)) {
      expect(typeof why === 'string' && why.trim().length > 0, `skip "${t}" needs a rationale`).toBe(
        true,
      )
    }
  })

  for (const c of cases) {
    it(`${c.type}`, () => {
      const out = toPlainText([c.input] as never)
      if (Object.prototype.hasOwnProperty.call(PROSE_GOLDEN, c.type)) {
        // Prose-bearing: non-empty AND exactly the JS-owned golden.
        expect(out, `prose type "${c.type}" dropped to '' — a reverted dispatch clause?`).not.toBe(
          '',
        )
        expect(out).toBe(PROSE_GOLDEN[c.type])
      } else {
        // Textless: exactly '' AND explicitly allow-listed (else it is a silent drop).
        expect(
          Object.prototype.hasOwnProperty.call(TEXTLESS_SKIP, c.type),
          `type "${c.type}" returned '' but is NOT on the TEXTLESS_SKIP allow-list ` +
            `(silent-drop ≠ intentional-skip)`,
        ).toBe(true)
        expect(out).toBe('')
      }
    })
  }
})

describe('toPlainText — type-keyed document walking', () => {
  it('walks a mixed type-keyed document, joining prose blocks with a blank line', () => {
    const heading = cases.find((c) => c.type === 'heading')!.input
    const image = cases.find((c) => c.type === 'image')!.input // textless → dropped
    const paragraph = cases.find((c) => c.type === 'paragraph')!.input
    const out = toPlainText([heading, image, paragraph] as never)
    // The textless image injects NO stray separator between the two prose blocks.
    expect(out).toBe(`${PROSE_GOLDEN.heading}\n\n${PROSE_GOLDEN.paragraph}`)
  })

  it('a document of only textless blocks yields the empty string', () => {
    const image = cases.find((c) => c.type === 'image')!.input
    const chart = cases.find((c) => c.type === 'chart')!.input
    const divider = cases.find((c) => c.type === 'divider')!.input
    expect(toPlainText([image, chart, divider] as never)).toBe('')
  })

  it('accepts a single type-keyed block (not wrapped in an array)', () => {
    const heading = cases.find((c) => c.type === 'heading')!.input
    expect(toPlainText(heading as never)).toBe(PROSE_GOLDEN.heading)
  })
})
