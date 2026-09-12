// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The JS leg of the INLINE `code` source parity lock (task-e4833f198e293ed1).
//
// Three engines render an inline code chip and they all read ONE fixture file —
// `api/test/support/fixtures/inline-code-source.json`:
//
//   Elixir  api/lib/barkpark/portable_doc/render/inline.ex  `inline_code_source/1`
//           tested by api/test/barkpark/portable_doc/render/inline_code_source_parity_test.exs
//   JS      js/packages/react/src/inline.tsx                `inlineCodeSource`
//           tested HERE
//   Go      internal/pdrender/inline.go                     `inlineCodeSource`
//           tested by internal/pdrender/inline_code_source_parity_test.go
//
// ONE file, not three generated mirrors — a mirror set drifts the moment one
// side is regenerated and the others are not, which is exactly the bug this row
// exists to close: this SDK shipped the value-or-children law while inline.ex
// and the Go TUI still read `value` only, so 66 published paragraphs rendered a
// chip with no body everywhere but the web.
//
// Sibling contract, deliberately DIFFERENT: `code-source-aliases.json` governs
// the BLOCK-level `code` node (first NON-BLANK across value|code|content|text).
// The inline leaf is first NON-EMPTY on `value` then children — a `value` of
// ' ' WINS here and falls through there.
//
// DRIFT PROOF: change `inlineCodeSource` to `str(node.value)` in src/inline.tsx
// and the children-shaped cases red HERE while the Elixir and Go legs stay
// green. No engine can move alone.
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { escapeHtml, inlineCodeSource, renderInline } from '../src/inline'

const FIXTURE_URL = new URL(
  '../../../../api/test/support/fixtures/inline-code-source.json',
  import.meta.url,
)

interface Case {
  name: string
  node: Record<string, unknown>
  source: string
}

const fixture = JSON.parse(readFileSync(FIXTURE_URL, 'utf8')) as { cases: Case[] }

describe('inline `code` source contract (shared fixture)', () => {
  it('carries every recorded case (a shrunken fixture cannot pass vacuously)', () => {
    expect(fixture.cases.length).toBeGreaterThanOrEqual(13)
  })

  for (const c of fixture.cases) {
    it(`inlineCodeSource: ${c.name}`, () => {
      expect(inlineCodeSource(c.node)).toBe(c.source)
    })

    it(`renderInline emits the recorded body: ${c.name}`, () => {
      expect(renderInline(c.node as never)).toBe(`<code>${escapeHtml(c.source)}</code>`)
    })
  }

  it('the children fall-through is REACHED by at least six cases', () => {
    const reached = fixture.cases.filter((c) => {
      if (c.node.children === undefined || c.source === '') return false
      // Copy-then-delete rather than a discarded rest sibling: the discarded
      // binding is a no-unused-vars red under this package's eslint config.
      const withoutChildren = { ...c.node }
      delete withoutChildren.children
      return inlineCodeSource(withoutChildren) !== c.source
    })
    expect(reached.length).toBeGreaterThanOrEqual(6)
  })
})
