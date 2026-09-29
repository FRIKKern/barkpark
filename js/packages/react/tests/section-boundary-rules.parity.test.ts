// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The JS leg of the ONE-RULE-PER-BOUNDARY parity lock (task-a4d1ae76fdb2a6b0).
//
// A `section` container used to open AND close on a full-width rule, so two
// adjacent sections stacked two hairlines where the grammar wants one. The
// Elixir engine settled the grammar in #16233 (SectionLayout.stack_rules?/2):
// an UNTITLED stack-mode section whose first child is a heading draws NO pair,
// because the heading itself carries the boundary (paper-surface.css gives a
// container head the same beat/rule/gap a top-level h2 gets, #15806). This SDK
// kept drawing both rules on the same published papers until the row that
// added this file.
//
// Three engines, ONE fixture file —
// `api/test/support/fixtures/section-boundary-rules.json`:
//
//   Elixir  api/lib/barkpark/portable_doc/render/section_layout.ex  `stack_rules?/2`
//           tested by api/test/barkpark/portable_doc/render/section_boundary_rules_parity_test.exs
//   Go      internal/pdrender/blocks.go                             `sectionStackRules`
//           tested by internal/pdrender/section_boundary_rules_parity_test.go
//   JS      js/packages/react/src/blocks/core.ts                    `sectionStackRules`
//           tested HERE
//
// DRIFT PROOF: make `sectionStackRules` return `true` unconditionally (the
// pre-fix behaviour) and the three zero-rule cases red HERE while the Elixir
// and Go legs stay green.
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { renderBlocks } from '../src/blocks/registry'

const FIXTURE_URL = new URL(
  '../../../../api/test/support/fixtures/section-boundary-rules.json',
  import.meta.url,
)

interface Case {
  name: string
  rules: number
  block: Record<string, unknown>
}

const fixture = JSON.parse(readFileSync(FIXTURE_URL, 'utf8')) as { cases: Case[] }

/** The number of BOUNDARY rules the emitted section draws. The stack leg adds
 * an inline `border-top-width` and the grid leg does not, so the class prefix
 * counts both. */
const ruleCount = (html: string) => html.split('<hr class="bp-hr"').length - 1

describe('section boundary rules (shared fixture)', () => {
  it('carries every recorded case, both arms (a shrunken fixture cannot pass vacuously)', () => {
    expect(fixture.cases.length).toBeGreaterThanOrEqual(10)
    expect(fixture.cases.filter((c) => c.rules === 0).length).toBeGreaterThanOrEqual(3)
    expect(fixture.cases.filter((c) => c.rules === 2).length).toBeGreaterThanOrEqual(6)
  })

  for (const c of fixture.cases) {
    it(`renderBlocks: ${c.name}`, () => {
      expect(ruleCount(renderBlocks([c.block]))).toBe(c.rules)
    })
  }

  it('every zero-rule case is the untitled heading-opening shape (the predicate is live)', () => {
    for (const c of fixture.cases.filter((x) => x.rules === 0)) {
      expect(c.block.title ?? null, `${c.name} must be UNTITLED`).toBeNull()
      const blocks = c.block.blocks as Array<Record<string, unknown>>
      expect(blocks[0]?.type, `${c.name} must open on a heading`).toBe('heading')
    }
  })

  it('two adjacent heading-opening sections draw ONE boundary between them', () => {
    const section = (text: string) => ({
      type: 'section',
      blocks: [
        { type: 'heading', level: 2, text },
        { type: 'paragraph', content: [{ type: 'text', value: 'body' }] },
      ],
    })
    const html = renderBlocks([section('First'), section('Second')])
    // Zero hairlines between the two: each boundary is the head's own
    // border-top, drawn by paper-surface.css.
    expect(ruleCount(html)).toBe(0)
    expect(html).toContain('First')
    expect(html).toContain('Second')
  })
})
