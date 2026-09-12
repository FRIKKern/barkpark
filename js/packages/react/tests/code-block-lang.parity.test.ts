// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The JS leg of the code-block LANGUAGE-FIELD parity lock (task-6e6b2661d201ccc0).
//
// THREE engines read this contract from ONE fixture file —
// `api/test/support/fixtures/code-block-lang-parity.json`:
//
//   Go      internal/pdrender/code.go            reads `lang` → chroma lexer + header
//           tested by internal/pdrender/code_block_lang_parity_test.go
//   Elixir  api/lib/barkpark/portable_doc/render/compose.ex   code composer (value only)
//           tested by api/test/barkpark/portable_doc/render/code_block_lang_parity_test.exs
//   JS      js/packages/react/src/blocks/core.ts  `code` emitter (value only)
//           tested HERE
//
// The language field is `lang`. `language` is a RETIRED alias. Only the Go TUI
// engine consumes a code-block language at render (naming the chroma lexer), and
// it reads `lang` alone. The JS `code` emitter renders `str(b.value)` and is
// language-AGNOSTIC: it reads NEITHER `lang` nor `language`. This leg proves it —
// a block carrying `lang`, one carrying the retired `language`, and one carrying
// neither render to IDENTICAL html (every fixture case shares one value). So the
// SDK can never drift to preferring `language`: there is no branch to drift.
//
// (`b.language` IS read for the `code-tabs` block — a different block type — in
// `codeTabEntries`; that is not the standalone `code` block this fixture pins.)
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { renderPortableDocument, type Block } from '../src/PortableDoc'

const FIXTURE_URL = new URL(
  '../../../../api/test/support/fixtures/code-block-lang-parity.json',
  import.meta.url,
)

interface Case {
  name: string
  block: Block
  source: string
  lang: string
  lexer_header: string
}

const fixture = JSON.parse(readFileSync(FIXTURE_URL, 'utf8')) as {
  language_field: string
  retired_alias: string
  cases: Case[]
}

describe('code-block language-field contract (shared fixture)', () => {
  it('reads the one fixture all three engines read, spelling the field `lang`', () => {
    expect(fixture.language_field).toBe('lang')
    expect(fixture.retired_alias).toBe('language')
    expect(fixture.cases.length).toBeGreaterThanOrEqual(3)
  })

  for (const [i, c] of fixture.cases.entries()) {
    it(`${i}: ${c.name} — renders the code source`, () => {
      const html = renderPortableDocument([c.block])
      expect(html, `case ${i} (${c.name}): expected content`).not.toBe('')
      expect(
        html,
        `case ${i} (${c.name}): expected source ${JSON.stringify(c.source)} in the html`,
      ).toContain(c.source)
    })
  }

  it('the JS code emitter is language-agnostic: lang / language / neither render identically', () => {
    // Every case shares one `value`, differing only in the language key (`lang`,
    // the retired `language`, or none). If the emitter read either key its output
    // would differ across cases; it does not.
    const htmls = fixture.cases.map((c) => renderPortableDocument([c.block]))
    for (const [i, html] of htmls.entries()) {
      expect(
        html,
        `case ${i} (${fixture.cases[i].name}): differs from the lang-bearing case; ` +
          'the JS code emitter must branch on NEITHER `lang` nor `language`',
      ).toBe(htmls[0])
    }
  })
})
