// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The JS (SDK web) leg of the code-block LINE-EMPHASIS parity lock
// (pe-bl-code-emphasis).
//
// FOUR legs read this contract from ONE fixture file —
// `api/test/support/fixtures/code-block-emphasis-parity.json`:
//
//   Go      internal/pdrender/code.go       tone sigil in the 2-cell gutter (TUI)
//           tested by internal/pdrender/code_block_emphasis_parity_test.go
//   Elixir  render/figures.ex + compose.ex  `.bp-code-em--<tone>` spans (:article)
//           and the :email arm, which must emit NONE of them
//           tested by api/test/.../code_block_emphasis_parity_test.exs
//   JS      js/packages/react/src/blocks/core.ts  the byte-faithful web mirror
//           tested HERE
//
// The JS emitter is a byte-faithful mirror of `Figures.code_block_html/2`, so
// this leg asserts the exact span markup the Elixir leg asserts, derived from
// the same `line_tones` array. A tone the vocabulary does not name is DROPPED
// (never interpolated into the class attribute), and a block whose ranges all
// drop renders byte-identically to a block with no `emphasis` key — which is
// what keeps the 9711-row no-emphasis corpus unmoved.
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { renderPortableDocument, type Block } from '../src/PortableDoc'

const FIXTURE_URL = new URL(
  '../../../../api/test/support/fixtures/code-block-emphasis-parity.json',
  import.meta.url,
)

interface Case {
  name: string
  block: Block
  line_tones: (string | null)[]
}

const fixture = JSON.parse(readFileSync(FIXTURE_URL, 'utf8')) as {
  tones: string[]
  sigils: Record<string, string>
  span_class_prefix: string
  source: string
  cases: Case[]
}

const escapeHtml = (s: string): string =>
  s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')

function expectedBody(lineTones: (string | null)[]): string {
  return fixture.source
    .split('\n')
    .map((line, i) => {
      const tone = lineTones[i]
      return tone === null || tone === undefined
        ? escapeHtml(line)
        : `<span class="bp-code-em bp-code-em--${tone}">${escapeHtml(line)}</span>`
    })
    .join('\n')
}

describe('code-block line-emphasis contract (shared fixture)', () => {
  it('reads the one fixture every engine reads, naming the closed vocabulary', () => {
    expect(fixture.tones).toEqual(['comment', 'offending', 'fixed'])
    expect(fixture.span_class_prefix).toBe('bp-code-em')
    expect(fixture.cases.length).toBeGreaterThanOrEqual(7)
    for (const c of fixture.cases) {
      expect(
        (c.block as Record<string, unknown>).value,
        `case ${c.name}: every case must share ONE source`,
      ).toBe(fixture.source)
      expect(c.line_tones.length).toBe(fixture.source.split('\n').length)
    }
  })

  for (const [i, c] of fixture.cases.entries()) {
    it(`${i}: ${c.name} — emits exactly the fixture's per-line tones`, () => {
      const html = renderPortableDocument([c.block])
      expect(html, `case ${i} (${c.name}): expected content`).not.toBe('')
      expect(
        html,
        `case ${i} (${c.name}): the <pre> body did not match the fixture's line_tones`,
      ).toContain(expectedBody(c.line_tones))
    })
  }

  it('a block whose ranges all drop is byte-identical to one with no emphasis key', () => {
    const legacyCase = fixture.cases[0]
    const unknownToneCase = fixture.cases[4]
    const liveCase = fixture.cases[5]
    if (!legacyCase) throw new Error('missing legacy fixture case 0')
    if (!unknownToneCase) throw new Error('missing unknown-tone fixture case 4')
    if (!liveCase) throw new Error('missing live-range fixture case 5')
    const legacy = renderPortableDocument([legacyCase.block])
    const unknownTone = renderPortableDocument([unknownToneCase.block])
    const live = renderPortableDocument([liveCase.block])

    expect(
      unknownTone,
      'an unknown tone must be DROPPED, rendering like a block with no `emphasis`',
    ).toBe(legacy)
    // CONTROL: case 5 keeps one well-formed `fixed` range, so it MUST differ —
    // otherwise the equality above would pass for an emitter that ignores the
    // field entirely.
    expect(live, 'CONTROL: case 5 has a live range and must differ from legacy').not.toBe(legacy)
  })

  it('an author tone never reaches the class attribute', () => {
    const hostile = {
      type: 'code',
      value: fixture.source,
      emphasis: [{ from: 1, tone: 'fixed"><script>alert(1)</script>' }],
    } as unknown as Block
    const html = renderPortableDocument([hostile])
    expect(html).not.toContain('<script>')
    const legacyCase = fixture.cases[0]
    if (!legacyCase) throw new Error('missing legacy fixture case 0')
    expect(html).toBe(renderPortableDocument([legacyCase.block]))
  })
})
