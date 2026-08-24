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
  // The NAME reports what was actually loaded; the ASSERTION carries the pin.
  // They used to be two hand-written numbers and they drifted: the name said
  // "49 types" while the assertion said 63, so for months the suite announced a
  // corpus size it had not checked since the fixture set grew. An observed
  // count in the name can never go stale.
  //
  // The pin itself STAYS a bare literal, deliberately, against this row's own
  // suggestion to derive it from the readdir. Two reasons: `cases` is ALREADY
  // that readdir, so `cases.length === readdirSync(...).length` is a tautology
  // and no tripwire at all; and this exact line is a live scaffy REPLACE anchor
  // (scaffy/commands/add-block-type.scaffy, "typekeyed corpus anchor") that
  // bumps the pin when a new block type lands. Rewriting it would break block
  // scaffolding to remove a guard.
  it(`the pd-golden fixture corpus is the pinned size (${cases.length} loaded)`, () => {
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
    expect(cases.length).toBe(64)
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

  it('the partition is 27 prose + 37 textless = 64', () => {
    // grown (pbw-stier-equation): tex source is reading content, the `code` precedent
    // grown (pbw-stier-tabs): each tab's label + nested blocks' prose, the `steps` precedent
    // grown (jarl-dogfood): expandable's summary + nested blocks are reading prose
    expect(Object.keys(PROSE_GOLDEN).length).toBe(27)
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

// ── the `{content:[…]}` twin of every prose golden ────────────────────────────
//
// The type-keyed goldens above pin each type in ONE authored shape — whichever
// the fixture happens to use. That is exactly how the heading/eyebrow drop hid
// for as long as it did: the renderer was swept for `{content:[…]}` (#6009) and
// the extractor was not, but no golden held a content-shape heading, so the
// suite stayed green over the gap.
//
// These cases re-author the fixture body into the OTHER shape and assert both
// yield the same plaintext. Deliberately NOT applied corpus-wide: for `code`,
// `diff` and `filetree` the `text`/`value` field is DATA, not a prose run, and
// rewriting it into inlines is a different law (task-e4833f198e293ed1).
describe('toPlainText — prose reads BOTH the content[] and the flat shape', () => {
  const inlineOf = (s: string) => [{ type: 'text', value: s }]

  const dualCases: Array<{ type: string; flat: unknown; content: unknown; expected: string }> = [
    {
      type: 'heading',
      flat: { type: 'heading', level: 2, text: 'Capstone' },
      content: { type: 'heading', level: 2, content: inlineOf('Capstone') },
      expected: 'Capstone',
    },
    {
      type: 'eyebrow',
      flat: { type: 'eyebrow', text: 'Field report' },
      content: { type: 'eyebrow', content: inlineOf('Field report') },
      expected: 'Field report',
    },
    {
      type: 'note',
      flat: { type: 'note', label: 'Note', lead: 'Run-in', text: 'A single annotated row.' },
      content: {
        type: 'note',
        label: 'Note',
        lead: 'Run-in',
        content: inlineOf('A single annotated row.'),
      },
      expected: 'Note Run-in A single annotated row.',
    },
    {
      type: 'notes',
      flat: { type: 'notes', items: [{ label: 'Upgrade', lead: 'Instant', text: 'The board updates live.' }] },
      content: {
        type: 'notes',
        items: [
          { label: 'Upgrade', lead: 'Instant', content: inlineOf('The board updates live.') },
        ],
      },
      expected: 'Upgrade Instant The board updates live.',
    },
  ]

  for (const c of dualCases) {
    it(`${c.type}: the content[] shape extracts the same prose as the flat shape`, () => {
      expect(toPlainText([c.flat] as never)).toBe(c.expected)
      expect(toPlainText([c.content] as never)).toBe(c.expected)
    })
  }

  it('a note with BOTH content[] and a legacy text prefers content[] (renderer order)', () => {
    const out = toPlainText([
      { type: 'note', label: 'N', content: inlineOf('from content'), text: 'from text' },
    ] as never)
    expect(out).toBe('N from content')
  })
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
