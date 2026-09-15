// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The JS leg of the two SEMANTIC VERDICT accents (pe-bl-verdict-accent-tokens).
//
// `loss` (terracotta-red) and `peace` (green) are design/tokens.json
// color.verdict — derived per theme by design/derive.mjs and resolved by
// paper-surface.css on `.bp-stat__v--loss/--peace` (the stat VALUE) and
// `.bp-callout--loss/--peace` (the callout RAIL + soft wash). Neither is a new
// block type: the stat takes a `verdict` field, the callout takes two more words
// in the `tone` vocabulary it already had.
//
//   Elixir  api/lib/barkpark/portable_doc/render/data_viz.ex  stat_html/1
//           api/lib/barkpark/portable_doc/render/walk.ex      callout_tone_class/1
//           tested by api/test/barkpark/portable_doc/render/verdict_accent_test.exs
//   JS      js/packages/react/src/blocks/dataviz.ts           statHtml
//           js/packages/react/src/blocks/core.ts              calloutToneClass
//           tested HERE
//
// DRIFT PROOF: drop `verdictMod` from `statHtml` (or remove 'loss'/'peace' from
// CALLOUT_TONES) and the expectations below red while the Elixir leg stays green.
import { describe, expect, it } from 'vitest'
import { datavizEmitters } from '../src/blocks/dataviz'
import { coreEmitters } from '../src/blocks/core'

const stat = datavizEmitters.stat
const stats = datavizEmitters.stats
const callout = coreEmitters.callout

const emitStat = (block: unknown) => {
  if (!stat) throw new Error('missing stat emitter')
  return stat(block as never)
}
const emitStats = (block: unknown) => {
  if (!stats) throw new Error('missing stats emitter')
  return stats(block as never)
}
const emitCallout = (block: unknown) => {
  if (!callout) throw new Error('missing callout emitter')
  return callout(block as never)
}

describe('stat verdict — the number carries the judgement', () => {
  it('stamps the value modifier for loss and peace, and only the value', () => {
    for (const verdict of ['loss', 'peace']) {
      const html = emitStat({
        type: 'stat',
        value: '0',
        label: 'reviews on the merge',
        verdict,
      })
      expect(html).toContain(`<div class="bp-stat__v bp-stat__v--${verdict}">`)
      expect(html).toContain('<div class="bp-stat">')
      expect(html).not.toContain(`bp-stat--${verdict}`)
    }
  })

  it('leaves an absent or off-vocabulary verdict on the bare class', () => {
    for (const block of [
      { type: 'stat', value: '42', label: 'x' },
      { type: 'stat', value: '42', label: 'x', verdict: 'puce' },
      { type: 'stat', value: '42', label: 'x', verdict: '' },
    ]) {
      const html = emitStat(block)
      expect(html).toContain('<div class="bp-stat__v">')
      expect(html).not.toContain('bp-stat__v--')
    }
  })

  it('carries a verdict through the stats grid onto its own cell', () => {
    const html = emitStats({
      type: 'stats',
      items: [
        { value: '0', label: 'reviews', verdict: 'loss' },
        { value: '12', label: 'tests', verdict: 'peace' },
        { value: '3', label: 'plain' },
      ],
    })
    expect(html).toContain('<div class="bp-stat__v bp-stat__v--loss">')
    expect(html).toContain('<div class="bp-stat__v bp-stat__v--peace">')
    expect(html).toContain('<div class="bp-stat__v">')
  })
})

describe('callout verdict tones — the rail says the conclusion', () => {
  const block = (tone: string, extra: Record<string, unknown> = {}) => ({
    type: 'callout',
    tone,
    content: [{ type: 'text', value: 'x' }],
    ...extra,
  })

  it('maps loss and peace to their own rail modifier, not the info fallback', () => {
    for (const tone of ['loss', 'peace']) {
      const html = emitCallout(block(tone))
      expect(html).toContain(`<div class="bp-callout bp-callout--${tone}">`)
      expect(html).not.toContain('bp-callout--info')
    }
  })

  it('gives the collapsible form the verdict rail and a sentence-cased summary', () => {
    const html = emitCallout(block('loss', { collapsible: true }))
    expect(html).toContain('<details open class="bp-callout bp-callout--loss">')
    expect(html).toContain('<summary class="bp-callout__summary">Loss</summary>')
  })

  it('leaves the five system tones untouched', () => {
    for (const tone of ['success', 'warning', 'danger', 'neutral']) {
      expect(emitCallout(block(tone))).toContain(`<div class="bp-callout bp-callout--${tone}">`)
    }
    expect(emitCallout(block('sparkle'))).toContain('<div class="bp-callout bp-callout--info">')
  })
})
