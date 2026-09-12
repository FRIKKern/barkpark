// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The JS leg of the code-block SOURCE-FIELD parity lock (task-e9af9f95d290307d).
//
// THREE engines read this contract and they all read ONE fixture file —
// `api/test/support/fixtures/code-source-aliases.json`:
//
//   Elixir  api/lib/barkpark/portable_doc/render/compose.ex   `code_source/1`
//           tested by api/test/barkpark/portable_doc/render/code_source_alias_parity_test.exs
//   Go      internal/pdrender/code.go                         `codeSource`
//           tested by internal/pdrender/code_source_alias_parity_test.go
//   JS      js/packages/react/src/inline.tsx                  `codeSource`
//           tested HERE
//
// It is deliberately ONE file, not three generated mirrors. A mirror set drifts
// the moment one side is regenerated and the others are not — which is the exact
// class of bug this task exists to close: Go read `code`||`value`, compose.ex
// read `value`, this SDK read `value`, and nothing compared them.
//
// DRIFT PROOF: drop `'code'` from `CODE_SOURCE_KEYS` in src/inline.tsx and the
// `code-only`, `code wins over text` and accepted-keys cases red HERE while the
// Elixir and Go legs stay green. No engine can move alone.
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { renderPortableDocument, type Block } from '../src/PortableDoc'
import { toPlainText } from '../src/toPlainText'
import { CODE_SOURCE_KEYS, codeSource } from '../src/inline'

const FIXTURE_URL = new URL(
  '../../../../api/test/support/fixtures/code-source-aliases.json',
  import.meta.url,
)

interface Case {
  name: string
  block: Block
  content_present: boolean
  source: string
}

const fixture = JSON.parse(readFileSync(FIXTURE_URL, 'utf8')) as {
  accepted_keys: string[]
  cases: Case[]
}

describe('code-block source-field contract (shared fixture)', () => {
  it('reads the one fixture both other engines read', () => {
    expect(fixture.cases.length).toBeGreaterThanOrEqual(10)
    expect(fixture.accepted_keys.length).toBeGreaterThan(0)
  })

  // The Go leg asserts `codeSourceKeys` equals `accepted_keys` IN ORDER; this is
  // that same assertion. Order is unobservable on live data (zero rows carry two
  // non-blank source keys) — pinning it is what stops it silently differing.
  it('accepts exactly the contract keys, in the contract order', () => {
    expect([...CODE_SOURCE_KEYS]).toEqual(fixture.accepted_keys)
  })

  for (const [i, c] of fixture.cases.entries()) {
    it(`${i}: ${c.name} — renders the contract's source`, () => {
      const html = renderPortableDocument([c.block])

      if (c.content_present) {
        expect(
          html,
          `case ${i} (${c.name}): expected content, got an EMPTY render — ` +
            'this is the hollow-render shape the task closes',
        ).not.toBe('')
        expect(
          html,
          `case ${i} (${c.name}): expected source ${JSON.stringify(c.source)} in the html`,
        ).toContain(c.source)
      } else {
        expect(html, `case ${i} (${c.name}): expected NO content`).toBe('')
      }
    })

    it(`${i}: ${c.name} — toPlainText agrees with the renderer`, () => {
      // The excerpt/SEO reader answers to the same key list, so an excerpt can
      // never be empty for a block the renderer paints (or the reverse).
      expect(toPlainText([c.block]), `case ${i} (${c.name})`).toBe(
        c.content_present ? c.source : '',
      )
    })

    it(`${i}: ${c.name} — the helper selects the contract's source verbatim`, () => {
      expect(codeSource(c.block), `case ${i} (${c.name})`).toBe(c.source)
    })
  }
})
