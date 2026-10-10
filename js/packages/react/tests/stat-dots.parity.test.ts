// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The JS leg of stat trial dots (pe-bl-stat-tile-dots): `dots: {on, of}` on a
// stat renders `of` dots, the first `on` filled, as ONE image to assistive tech.
//
//   Elixir  api/lib/barkpark/portable_doc/render/data_viz.ex  dots/1, dots_html/1
//           tested by api/test/barkpark/portable_doc/render/stat_dots_test.exs
//   JS      js/packages/react/src/blocks/dataviz.ts           whole, dotsHtml
//           tested HERE; the stat/stats/nb-NO goldens hold the two halves equal.
import { describe, expect, it } from 'vitest'
import { datavizEmitters } from '../src/blocks/dataviz'
import { EN, makeCtx } from '../src/blocks/chrome'

const stat = datavizEmitters.stat
const emit = (block: unknown, ctx = EN) => {
  if (!stat) throw new Error('missing stat emitter')
  return stat(block as never, ctx)
}
const count = (html: string, needle: string) => html.split(needle).length - 1
const ON = '<i class="bp-stat__dot bp-stat__dot--on" aria-hidden="true"></i>'
const OFF = '<i class="bp-stat__dot" aria-hidden="true"></i>'

describe('stat dots', () => {
  it('renders of dots, on filled, labelled once', () => {
    const html = emit({ type: 'stat', value: '2', label: 'trials', dots: { on: 2, of: 10 } })
    expect(html).toContain('<div class="bp-stat__dots" role="img" aria-label="2 of 10">')
    expect(count(html, ON)).toBe(2)
    expect(count(html, OFF)).toBe(8)
  })

  it('labels in the render language', () => {
    const html = emit(
      { type: 'stat', value: '2', dots: { on: 2, of: 10 } },
      makeCtx({ '%{on} of %{total}': '%{on} av %{total}' }),
    )
    expect(html).toContain('aria-label="2 av 10"')
  })

  it('clamps on into 0..of and takes whole-number strings', () => {
    expect(count(emit({ type: 'stat', value: '1', dots: { on: 99, of: 3 } }), ON)).toBe(3)
    expect(count(emit({ type: 'stat', value: '1', dots: { on: -4, of: 3 } }), OFF)).toBe(3)
    expect(emit({ type: 'stat', value: '1', dots: { on: '1', of: ' 4 ' } })).toContain(
      'aria-label="1 of 4"',
    )
  })

  it('renders nothing for a missing or malformed field', () => {
    const bare = emit({ type: 'stat', value: '1' })
    for (const dots of [
      null,
      'x',
      [],
      { on: 1 },
      { on: 1, of: 0 },
      { on: 1, of: 51 },
      { on: 1, of: 2.5 },
      { on: 'a', of: 3 },
    ]) {
      expect(emit({ type: 'stat', value: '1', dots })).toBe(bare)
    }
  })
})
