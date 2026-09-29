// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The JS leg of the CLOCK STRIP's per-stop VERDICT (pe-bl-clock-strip-block).
//
// A lineage stop may carry `tone` from the four-word vocabulary the chart
// regions already use (info/ok/warn/danger). The stylesheet colours that stop's
// spine tick and its time from the matching `--bp-tone-*-fg` token, so the class
// IS the verdict — an engine that drops it renders a strip where the stop the
// paper is about looks like every other stop.
//
//   Elixir  api/lib/barkpark/portable_doc/render/data_viz.ex  lineage_node_html/1
//           tested by api/test/barkpark/portable_doc/render/data_viz_test.exs
//   JS      js/packages/react/src/blocks/dataviz.ts           lineageNodeHtml
//           tested HERE
//
// DRIFT PROOF: replace the `toneClass(...)` call in `lineageNodeHtml` with the
// literal `'bp-lineage__node'` and the four modifier expectations below red
// while the Elixir leg stays green.
import { describe, expect, it } from 'vitest'
import { datavizEmitters } from '../src/blocks/dataviz'

const lineage = datavizEmitters.lineage

// The Eight-Minute Erasure clock strip, §I: four dated stops, the verdict
// sharpening across them.
const STRIP = {
  type: 'lineage',
  nodes: [
    { overline: '20:47:43', title: '“Thanks for finding this…”', tone: 'ok' },
    { overline: '20:50:24', title: 'His description rewritten — first of four', tone: 'warn' },
    { overline: '20:54:36', title: 'Fourth rewrite. His test disclosure is gone', tone: 'danger' },
    { overline: '20:55:53', title: 'Merged. Zero review comments', tone: 'info' },
  ],
}

const emit = (block: unknown) => {
  if (!lineage) throw new Error('missing lineage emitter')
  return lineage(block as never)
}

describe('lineage tone — the clock strip’s per-stop verdict', () => {
  it('emits one verdict modifier per toned stop', () => {
    const html = emit(STRIP)
    for (const t of ['ok', 'warn', 'danger', 'info']) {
      expect(html).toContain(`<li class="bp-lineage__node bp-lineage__node--${t}">`)
    }
  })

  it('leaves an untoned stop and an off-vocabulary tone on the bare class', () => {
    const html = emit({
      type: 'lineage',
      nodes: [
        { overline: 'later', title: 'No tone at all' },
        { overline: 'later still', title: 'Tone off-vocabulary', tone: 'puce' },
      ],
    })
    expect(html).toContain(
      '<li class="bp-lineage__node"><div class="bp-lineage__overline">later</div>',
    )
    expect(html).toContain(
      '<li class="bp-lineage__node"><div class="bp-lineage__overline">later still</div>',
    )
    expect(html).not.toContain('bp-lineage__node--puce')
  })
})
