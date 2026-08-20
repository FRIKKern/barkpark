// The round-2 dataviz natives (mob-zb-s5, charter D56): chart, heatmap,
// gauge-list, bar-chart, criteria-progress, and the un-dropped stat sparkline.
//
// ITS OWN FILE by the D49 territory law — paperRenderer.test.tsx and
// chatRenderers.test.tsx are shared serializers, so a renderer slice proves its
// own semantics beside its own family module instead of appending there.
//
// WHAT IS PINNED, and why each pin can fail. Zero-dependency drawing means the
// GEOMETRY is the renderer: there is no SVG path string to eyeball, so a bar
// that stops denominating by the right total, a heat cell that stops mixing, or
// a line that mounts no rotated segment all look like "a box rendered" to a
// coverage check. So the assertions read the resolved STYLES:
//
//   • the three proportional-row blocks — the percentage width AND the digit,
//     each against its own denominator law (sum-or-max / data-max / per-row
//     total). A denominator swap moves the width and reds here.
//   • the heatmap's three variants — that cells exist and that their fills are
//     the accent↔rule LERP at the intensity the data implies (a flat fill, the
//     classic regression when a colour helper is stubbed, reds).
//   • the chart — line mode mounts n−1 ROTATED views plus n vertex dots; bars
//     mode mounts positioned rectangles and NO rotation. Losing the segments
//     leaves an axis and a legend, which no text assertion would notice.
//   • no onLayout ANYWHERE in any rendered tree (D56's cheap-first-frame law).
//   • the honest empty state for all five, since a registered renderer that
//     silently draws an empty card is worse than the unregistered fallback.
import type { ReactElement, ReactNode } from 'react'

import { datavizCases, heatmapVariantCases } from './cases/dataviz.cases'
import {
  chartSpan,
  gaugeRows,
  lerpHex,
  lineSegments,
  quantileBins,
  seriesColors,
} from '../src/papers/portabledoc/blocks/dataviz'
import { BLOCK_RENDERERS, renderBlockNative, type BlockCtx } from '../src/papers/portabledoc/blocks'
import { dark, light } from '../src/ui/theme'

jest.mock('react-native-webview', () => ({ WebView: () => null }))

const paper: BlockCtx = { theme: light }
const chat: BlockCtx = { theme: light, register: 'chat' }

/* ── the element walker (the chatRenderers harness, styles-first) ───────────── */

interface Walk {
  text: string
  styles: Record<string, unknown>[]
  onLayouts: number
}

function isElement(node: unknown): node is ReactElement {
  return !!node && typeof node === 'object' && 'props' in (node as object) && '$$typeof' in (node as object)
}

function walkNode(node: ReactNode, acc: Walk): void {
  if (node === null || node === undefined || typeof node === 'boolean') return
  if (typeof node === 'string' || typeof node === 'number') {
    acc.text += String(node)
    return
  }
  if (Array.isArray(node)) {
    for (const child of node) walkNode(child as ReactNode, acc)
    return
  }
  if (!isElement(node)) return
  const props = node.props as Record<string, unknown>
  if (props.onLayout !== undefined) acc.onLayouts++
  const raw = props.style
  if (raw !== undefined) {
    const parts = Array.isArray(raw) ? raw : [raw]
    acc.styles.push(Object.assign({}, ...parts.filter((p) => !!p)) as Record<string, unknown>)
  }
  walkNode(props.children as ReactNode, acc)
}

function walk(block: unknown, ctx: BlockCtx = paper): Walk {
  const acc: Walk = { text: '', styles: [], onLayouts: 0 }
  walkNode(renderBlockNative(block, ctx, 0), acc)
  return acc
}

/** The percentage-width fills inside a proportional row: an accent-filled bar
 * on the 8pt track. `barRow`'s track itself is border-coloured, so this picks
 * out exactly the fills. */
function fillWidths(w: Walk): string[] {
  return w.styles
    .filter((s) => s.backgroundColor === light.accent && typeof s.width === 'string' && s.height === 8)
    .map((s) => s.width as string)
}

function rotations(w: Walk): number[] {
  return w.styles
    .filter((s) => Array.isArray(s.transform))
    .map((s) => {
      const t = (s.transform as { rotate?: string }[])[0]
      return Number.parseFloat(String(t?.rotate ?? '0'))
    })
}

function dots(w: Walk): Record<string, unknown>[] {
  return w.styles.filter((s) => s.width === 3 && s.height === 3)
}

function parsePct(v: unknown): number {
  return Number.parseFloat(String(v))
}

/* ── 1. registration + both registers ──────────────────────────────────────── */

describe('the five natives are registered and render in BOTH registers', () => {
  it('every new type dispatches to its own renderer', () => {
    for (const t of ['chart', 'heatmap', 'gauge-list', 'bar-chart', 'criteria-progress']) {
      expect(typeof BLOCK_RENDERERS[t]).toBe('function')
    }
    // Distinct functions — none of the five is an alias of another.
    const fns = ['chart', 'heatmap', 'gauge-list', 'bar-chart', 'criteria-progress'].map(
      (t) => BLOCK_RENDERERS[t],
    )
    expect(new Set(fns).size).toBe(5)
  })

  it('every authored case renders without the unknown-block fallback, in paper AND chat', () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {})
    try {
      for (const { type, block } of [...datavizCases, ...heatmapVariantCases]) {
        for (const ctx of [paper, chat]) {
          const out = walk(block, ctx)
          expect(`${type}: ${out.text}`).not.toContain('Unsupported block')
          expect(out.styles.length).toBeGreaterThan(0)
        }
      }
      expect(warn).not.toHaveBeenCalled()
    } finally {
      warn.mockRestore()
    }
  })

  it('is REGISTER-BLIND by design — the two registers resolve to the same styles', () => {
    // dataviz has no prose runs: every string is apparatus (mono label, digit,
    // axis tick) on the chrome scale, so `bodyText(ctx)` never appears and the
    // registers cannot diverge. Recorded HERE so the crown's D50 register
    // tripwire has the per-type ruling it needs for its REGISTER_BLIND
    // allowlist, rather than reading the sameness as a leak.
    //
    // The jarl figure family is the recorded EXCEPTION: a duel row label and a
    // lineage title/body are DOCUMENT voice (the web inherits the paper serif
    // face into `.bp-duel__label` / `.bp-lineage__title` / `.bp-lineage__body`),
    // so both ride `bodyText(ctx)` and MUST diverge — they stay OFF the D50
    // allowlist, and this pin asserts the partition in both directions rather
    // than skipping them.
    const SENSITIVE = new Set(['duel', 'lineage'])
    for (const { type, block } of datavizCases) {
      const same =
        JSON.stringify(walk(block, chat).styles) === JSON.stringify(walk(block, paper).styles)
      expect(`${type} blind=${same}`).toBe(`${type} blind=${!SENSITIVE.has(type)}`)
    }
  })

  it('renders a CHEAP first frame — no onLayout anywhere in any tree (D56)', () => {
    for (const { block } of [...datavizCases, ...heatmapVariantCases]) {
      expect(walk(block).onLayouts).toBe(0)
    }
  })
})

/* ── 2. the honest empty states ────────────────────────────────────────────── */

describe('empty/malformed data keeps the honest state', () => {
  it('all five say "<kind> — no data" rather than drawing an empty card', () => {
    const empties: [string, Record<string, unknown>][] = [
      ['chart', { type: 'chart', series: [] }],
      ['chart', { type: 'chart', series: [{ label: 'x', points: ['junk'] }] }],
      ['heatmap', { type: 'heatmap', cells: [] }],
      ['gauge-list', { type: 'gauge-list', rows: [] }],
      ['bar-chart', { type: 'bar-chart', bars: [] }],
      ['criteria-progress', { type: 'criteria-progress', rows: [] }],
      ['stats', { type: 'stats', items: [] }],
    ]
    for (const [kind, block] of empties) {
      expect(walk(block).text).toBe(`${kind} — no data`)
    }
  })

  it('a missing payload degrades the same way — never a throw', () => {
    for (const type of ['chart', 'heatmap', 'gauge-list', 'bar-chart', 'criteria-progress']) {
      expect(walk({ type }).text).toContain('no data')
    }
  })
})

/* ── 3. the proportional-row blocks: one denominator law each ───────────────── */

describe('bar-chart denominates by the DATA MAX', () => {
  it('widths are proportional to the largest bar, and the digit rides values:true', () => {
    const w = walk({
      type: 'bar-chart',
      bars: [
        { label: 'a', value: 10 },
        { label: 'b', value: 5 },
        { label: 'c', value: 0 },
      ],
      values: true,
    })
    expect(fillWidths(w)).toEqual(['100%', '50%', '0%'])
    expect(w.text).toContain('10')
    expect(w.text).toContain('5')
  })

  it('an explicit positive max overrides the data max', () => {
    const w = walk({ type: 'bar-chart', bars: [{ label: 'a', value: 10 }], max: 40 })
    expect(fillWidths(w)).toEqual(['25%'])
  })

  it('an all-zero column floors the denominator at 1 instead of dividing by zero', () => {
    const w = walk({ type: 'bar-chart', bars: [{ label: 'a', value: 0 }, { label: 'b', value: 0 }] })
    expect(fillWidths(w)).toEqual(['0%', '0%'])
  })

  it('values:false prints NO digit — the bar is the datum', () => {
    const w = walk({ type: 'bar-chart', bars: [{ label: 'alpha', value: 7 }] })
    expect(w.text).toBe('alpha')
    // And the digit COLUMN goes with it: the web omits the span entirely, so a
    // reserved 36pt would be dead gutter the bar could have used.
    expect(w.styles.filter((s) => s.minWidth === 36)).toHaveLength(0)
    expect(walk({ type: 'bar-chart', bars: [{ label: 'a', value: 7 }], values: true }).styles
      .filter((s) => s.minWidth === 36)).toHaveLength(1)
  })
})

describe('gauge-list: share of a total, or a frequency count', () => {
  it('share mode denominates by the SUM and prints a percent digit', () => {
    const w = walk({
      type: 'gauge-list',
      title: 'split',
      rows: [
        { label: 'done', value: 3 },
        { label: 'open', value: 1 },
      ],
    })
    expect(fillWidths(w)).toEqual(['75%', '25%'])
    expect(w.text).toContain('75%')
    expect(w.text).toContain('25%')
    expect(w.text).toContain('split')
  })

  it('an explicit max replaces the sum as the denominator', () => {
    const rows = gaugeRows({ rows: [{ label: 'a', value: 5 }], max: 20 })
    expect(rows).toEqual([{ label: 'a', prop: 0.25, digit: '25%', note: '' }])
  })

  it('count mode groups a snapshot and denominates by the TOP count', () => {
    const w = walk({
      type: 'gauge-list',
      snapshot: [{ status: 'open' }, { status: 'open' }, { status: 'done' }],
    })
    // open=2 (the max → 100%), done=1 (50%), sorted count-desc.
    expect(fillWidths(w)).toEqual(['100%', '50%'])
    expect(w.text).toContain('open')
    expect(w.text).toContain('done')
  })

  it('count mode buckets priority as P<n> and empties as (none)', () => {
    const rows = gaugeRows({ snapshot: [{ priority: 1 }, { priority: 1 }, {}], groupBy: 'priority' })
    expect(rows).not.toBe('epic')
    expect((rows as { label: string; digit: string }[]).map((r) => `${r.label}=${r.digit}`)).toEqual([
      'P1=2',
      '(none)=1',
    ])
  })

  it('groupBy:"epic" states its own unbackedness instead of faking a chart', () => {
    expect(gaugeRows({ snapshot: [{ status: 'open' }], groupBy: 'epic' })).toBe('epic')
    const w = walk({ type: 'gauge-list', snapshot: [{ status: 'open' }], groupBy: 'epic' })
    expect(w.text).toContain('needs the epic resolver')
    expect(fillWidths(w)).toEqual([])
  })
})

describe('criteria-progress denominates by each row OWN total', () => {
  it('shows the met/total digits and a per-row fraction', () => {
    const w = walk({
      type: 'criteria-progress',
      rows: [
        { label: 'slice', met: 2, total: 5 },
        { label: 'other', met: 3, total: 3 },
      ],
    })
    expect(fillWidths(w)).toEqual(['40%', '100%'])
    expect(w.text).toContain('2/5')
    expect(w.text).toContain('3/3')
  })

  it('detail:"total" collapses every row into one summed Total bar', () => {
    const w = walk({
      type: 'criteria-progress',
      detail: 'total',
      rows: [
        { label: 'a', met: 1, total: 4 },
        { label: 'b', met: 1, total: 6 },
      ],
    })
    expect(fillWidths(w)).toEqual(['20%'])
    expect(w.text).toContain('Total')
    expect(w.text).toContain('2/10')
  })

  it('a zero total is 0%, never NaN%', () => {
    const w = walk({ type: 'criteria-progress', rows: [{ label: 'a', met: 0, total: 0 }] })
    expect(fillWidths(w)).toEqual(['0%'])
    expect(w.text).toContain('0/0')
    expect(w.text).not.toContain('NaN')
  })
})

/* ── 4. the heatmap's three variants ───────────────────────────────────────── */

describe('heatmap — all three variants draw lerped cells', () => {
  it('the continuous grid mixes accent over rule by intensity (max 88%)', () => {
    const w = walk({ type: 'heatmap', cells: [[0, 5, 10]] })
    const fills = w.styles.filter((s) => s.borderRadius === 3 && s.width === 16).map((s) => s.backgroundColor)
    expect(fills).toEqual([
      lerpHex(light.border, light.accent, 0),
      lerpHex(light.border, light.accent, 0.44),
      lerpHex(light.border, light.accent, 0.88),
    ])
    // The whole point of a lerp: three DIFFERENT colours, not one flat fill.
    expect(new Set(fills).size).toBe(3)
  })

  it('an explicit max rescales the intensities', () => {
    const fills = (cells: number[][], max?: number) =>
      walk({ type: 'heatmap', cells, max })
        .styles.filter((s) => s.borderRadius === 3 && s.width === 16)
        .map((s) => s.backgroundColor)
    // 10 of 10 is full intensity; 10 of an explicit 20 is half.
    expect(fills([[10]])).toEqual([lerpHex(light.border, light.accent, 0.88)])
    expect(fills([[10]], 20)).toEqual([lerpHex(light.border, light.accent, 0.44)])
  })

  it('calendar mode bins by quantile and marks the no-activity cell', () => {
    const w = walk({ type: 'heatmap', mode: 'calendar', cells: [[0, 1, 5, 9]], colLabels: ['Jan'] })
    const cells = w.styles.filter((s) => s.borderRadius === 3 && s.width === 12)
    expect(cells).toHaveLength(4)
    // bin −1 (the zero cell) keeps the bare rule colour; the three positives
    // climb the 22/44/66 rungs. The TOP rung (88%) is deliberately unreachable
    // here: bin 3 needs v > q75, and with three non-zero values q75 IS the
    // largest of them — the web's own quantile behaviour, not a lost rung.
    expect(quantileBins([[0, 1, 5, 9]])).toEqual([[-1, 0, 1, 2]])
    expect(cells.map((s) => s.backgroundColor)).toEqual([
      light.border,
      lerpHex(light.border, light.accent, 0.22),
      lerpHex(light.border, light.accent, 0.44),
      lerpHex(light.border, light.accent, 0.66),
    ])
    expect(w.text).toContain('less')
    expect(w.text).toContain('more')
    expect(w.text).toContain('Jan')
  })

  it('matrix-extras prints per-cell values, marginals and the grand total', () => {
    const w = walk({
      type: 'heatmap',
      cells: [
        [1, 2],
        [3, 4],
      ],
      values: true,
      marginals: true,
      rowLabels: ['r0', 'r1'],
    })
    for (const s of ['1', '2', '3', '4', 'Σ', '3', '7', '4', '6', '10']) {
      expect(w.text).toContain(s)
    }
    // Grand total 10 = the row sums 3+7 = the col sums 4+6.
    expect(w.text).toContain('10')
    // Value cells widen (the CSS minmax(28,auto)) and stay TRANSPARENT: their
    // bin colour rides the underline strip so the ink keeps full contrast
    // (paper-surface.css .bp-heat__c--v — `text` on an 88%-accent fill is
    // 3.3:1 in light and 3.1:1 in dark, both under AA for 0.7rem mono).
    const valueCells = w.styles.filter((s) => s.borderRadius === 3 && s.width === 40)
    expect(valueCells).toHaveLength(4)
    expect(valueCells.map((s) => s.backgroundColor)).toEqual(Array(4).fill('transparent'))
    const strips = w.styles.filter((s) => s.height === 3 && s.bottom === 0 && s.left === '15%')
    expect(strips).toHaveLength(4)
    // The strip is the bin channel, so it must still SPREAD across the rungs.
    expect(new Set(strips.map((s) => s.backgroundColor)).size).toBeGreaterThan(1)
  })

  it('emphasises the grand total and dims every other sum (.bp-heat__sum--grand)', () => {
    const w = walk({
      type: 'heatmap',
      cells: [
        [1, 2],
        [3, 4],
      ],
      marginals: true,
    })
    const sums = w.styles.filter((s) => s.minWidth === 28 && s.textAlign === 'right')
    // 2 row sums + 2 col sums + the grand.
    expect(sums).toHaveLength(5)
    const grand = sums[sums.length - 1]!
    expect(grand.color).toBe(light.text)
    expect(grand.fontWeight).toBe('700')
    for (const s of sums.slice(0, -1)) {
      expect(s.color).toBe(light.textMuted)
      expect(s.fontWeight).toBeUndefined()
    }
  })

  it('a marginals-only matrix still routes to the extras variant', () => {
    const w = walk({ type: 'heatmap', cells: [[2, 2]], marginals: true })
    expect(w.text).toContain('Σ')
    expect(w.styles.filter((s) => s.borderRadius === 3 && s.width === 16)).toHaveLength(2)
  })
})

/* ── 5. the chart ──────────────────────────────────────────────────────────── */

describe('chart — line mode draws with rotated segments, bars with rectangles', () => {
  it('line mode mounts n−1 rotated segments and n vertex dots per series', () => {
    const w = walk({ type: 'chart', series: [{ label: 's', points: [0, 10, 5, 10] }] })
    expect(rotations(w)).toHaveLength(3)
    expect(dots(w)).toHaveLength(4)
    // A rising run tilts UP (negative degrees: y grows downward), a falling run
    // down — a segment list that lost its angles would be all zeros.
    const [a, b, c] = rotations(w)
    expect(a).toBeLessThan(0)
    expect(b).toBeGreaterThan(0)
    expect(c).toBeLessThan(0)
    // The 10→5 fall and the 5→10 rise are the same run mirrored, so their
    // angles are negatives of each other — an angle helper that lost its sign
    // would make these equal instead.
    expect(b).toBeCloseTo(-c!, 5)
  })

  it('line is the DEFAULT kind, and an unknown kind falls back to it', () => {
    for (const kind of [undefined, 'scatter', 'LINE']) {
      const w = walk({ type: 'chart', kind, series: [{ label: 's', points: [1, 2] }] })
      expect(rotations(w)).toHaveLength(1)
    }
  })

  it('bars mode positions rectangles, with NO rotation anywhere', () => {
    const w = walk({ type: 'chart', kind: 'bars', series: [{ label: 's', points: [0, 5, 10, 10] }] })
    expect(rotations(w)).toEqual([])
    const bars = w.styles.filter((s) => s.opacity === 0.85)
    expect(bars).toHaveLength(4)
    // Four slots across the plot: each bar is 17.5% wide and its left edge
    // advances one slot (25% of the box) at a time.
    for (const bar of bars) expect(parsePct(bar.width)).toBeCloseTo(17.5, 1)
    const lefts = bars.map((bar) => parsePct(bar.left))
    expect(lefts).toEqual([...lefts].sort((x, y) => x - y))
    expect(lefts[1]! - lefts[0]!).toBeCloseTo(25, 1)
    // value 0 with a 0-floored span is a zero-height bar sitting ON the axis.
    expect(parsePct(bars[0]!.height)).toBeCloseTo(0, 1)
    expect(parsePct(bars[2]!.height)).toBeCloseTo(100, 1)
  })

  it('bars floor the span at 0 even when every value is positive', () => {
    const w = walk({ type: 'chart', kind: 'bars', series: [{ label: 's', points: [5, 10] }] })
    const bars = w.styles.filter((s) => s.opacity === 0.85)
    // If the span had stayed [5,10] the first bar would have zero height.
    expect(parsePct(bars[0]!.height)).toBeCloseTo(50, 1)
    expect(w.text).toContain('0')
  })

  it('axes.min/max PIN the span and out-of-span points clamp to an edge', () => {
    const w = walk({
      type: 'chart',
      kind: 'bars',
      series: [{ label: 's', points: [-50, 500] }],
      axes: { min: 0, max: 100 },
    })
    const bars = w.styles.filter((s) => s.opacity === 0.85)
    // −50 clamps to the floor (no height), 500 to the ceiling (full height) —
    // neither escapes the plot box.
    expect(parsePct(bars[0]!.height)).toBeCloseTo(0, 1)
    expect(parsePct(bars[1]!.height)).toBeCloseTo(100, 1)
    expect(parsePct(bars[1]!.top)).toBeCloseTo(0, 1)
  })

  it('draws four gridlines with compact ticks, an axis, x labels and a legend', () => {
    const w = walk({
      type: 'chart',
      caption: 'throughput',
      series: [{ label: 'merged', points: [0, 3_000_000] }],
      axes: { xLabels: ['Mon', 'Tue', 'Fri'] },
    })
    expect(w.styles.filter((s) => s.height === 1 && s.backgroundColor === light.border)).toHaveLength(4)
    expect(w.styles.filter((s) => s.height === 1 && s.backgroundColor === light.textMuted)).toHaveLength(1)
    expect(w.text).toContain('3M') // tickCompact, not 3000000
    expect(w.text).toContain('throughput')
    // FIRST and LAST x label only (the web's xLabelsSvg law).
    expect(w.text).toContain('Mon')
    expect(w.text).toContain('Fri')
    expect(w.text).not.toContain('Tue')
    expect(w.text).toContain('merged')
  })

  it('an unlabelled series still gets a legend key', () => {
    expect(walk({ type: 'chart', series: [{ points: [1, 2] }] }).text).toContain('series 1')
  })

  it('caps at FOUR series and gives each a distinguishable colour', () => {
    const w = walk({
      type: 'chart',
      series: [1, 2, 3, 4, 5].map((k) => ({ label: `s${k}`, points: [k, k + 1] })),
    })
    expect(w.text).toContain('s4')
    expect(w.text).not.toContain('s5')
    const swatches = w.styles.filter((s) => s.width === 14 && s.height === 3)
    expect(swatches).toHaveLength(4)
    expect(new Set(swatches.map((s) => s.backgroundColor)).size).toBe(4)
  })
})

/* ── 6. the shared primitives, as helpers ──────────────────────────────────── */

describe('lineSegments — the polyline, without SVG', () => {
  it('returns n−1 centred segments with real lengths and angles', () => {
    const segs = lineSegments([
      { x: 0, y: 0 },
      { x: 3, y: 4 },
    ])
    expect(segs).toHaveLength(1)
    expect(segs[0]!.len).toBeCloseTo(5, 6)
    expect(segs[0]!.midX).toBeCloseTo(1.5, 6)
    expect(segs[0]!.midY).toBeCloseTo(2, 6)
    expect(segs[0]!.angle).toBeCloseTo(53.13, 2)
  })

  it('drops a zero-length run and needs two points to draw anything', () => {
    expect(lineSegments([{ x: 5, y: 5 }, { x: 5, y: 5 }])).toEqual([])
    expect(lineSegments([{ x: 1, y: 1 }])).toEqual([])
    expect(lineSegments([])).toEqual([])
  })

  it('a horizontal run is 0°, a downward run +90°', () => {
    expect(lineSegments([{ x: 0, y: 0 }, { x: 10, y: 0 }])[0]!.angle).toBeCloseTo(0, 6)
    expect(lineSegments([{ x: 0, y: 0 }, { x: 0, y: 10 }])[0]!.angle).toBeCloseTo(90, 6)
  })
})

describe('lerpHex — the CSS color-mix, in two channels', () => {
  it('hits both endpoints exactly and the midpoint between them', () => {
    expect(lerpHex('#000000', '#ffffff', 0)).toBe('#000000')
    expect(lerpHex('#000000', '#ffffff', 1)).toBe('#ffffff')
    expect(lerpHex('#000000', '#ffffff', 0.5)).toBe('#808080')
    expect(lerpHex('#ff0000', '#0000ff', 0.5)).toBe('#800080')
  })

  it('clamps out-of-range t and passes a non-hex input through unmixed', () => {
    expect(lerpHex('#000000', '#ffffff', -3)).toBe('#000000')
    expect(lerpHex('#000000', '#ffffff', 9)).toBe('#ffffff')
    expect(lerpHex('rgb(0,0,0)', '#123456', 0.5)).toBe('#123456')
  })
})

describe('chartSpan — the axes tie-breaks', () => {
  const s = (points: number[]) => [{ label: '', points }]

  it('uses the data range when no axis is pinned', () => {
    expect(chartSpan(s([2, 9]), {})).toEqual([2, 9])
  })

  it('a pinned min/max wins, and one side alone still pins that side', () => {
    expect(chartSpan(s([2, 9]), { min: 0, max: 100 })).toEqual([0, 100])
    expect(chartSpan(s([2, 9]), { min: 0 })).toEqual([0, 9])
    expect(chartSpan(s([2, 9]), { max: 100 })).toEqual([2, 100])
  })

  it('a REVERSED pinned pair is discarded for the data range', () => {
    expect(chartSpan(s([2, 9]), { min: 100, max: 0 })).toEqual([2, 9])
  })

  it('a flat series opens to a unit span instead of dividing by zero', () => {
    expect(chartSpan(s([4, 4]), {})).toEqual([4, 5])
  })
})

describe('seriesColors — D56 palette, deduplicated', () => {
  it('is the theme own accent/warn/danger ladder, with no invented colour', () => {
    for (const theme of [light, dark]) {
      const four = seriesColors(theme, 4)
      expect(four).toContain(theme.accent)
      expect(four).toContain(theme.warn)
      expect(four).toContain(theme.danger)
      for (const c of four) {
        expect([theme.accent, theme.success, theme.warn, theme.danger, theme.textMuted]).toContain(c)
      }
    }
  })

  it('never paints two series the same colour — theme.success EQUALS theme.accent', () => {
    // The collision is a fact of theme.ts in BOTH palettes, so taking D56's
    // four-token list literally would draw series 1 and 2 identically.
    expect(light.success).toBe(light.accent)
    expect(dark.success).toBe(dark.accent)
    for (const theme of [light, dark]) {
      for (const n of [1, 2, 3, 4]) {
        expect(new Set(seriesColors(theme, n)).size).toBe(n)
      }
    }
  })
})

/* ── 7. the sparkline, un-dropped ──────────────────────────────────────────── */

describe('stat sparkline (UN-DROPPED, D56)', () => {
  it('draws the spark series as segments plus vertex dots', () => {
    const w = walk({ type: 'stat', value: '42', label: 'answers', spark: [1, 4, 2, 8] })
    expect(rotations(w)).toHaveLength(3)
    expect(dots(w)).toHaveLength(4)
    // Kept at the web's own 120×26 box (no measurement pass exists to stretch
    // it to the card width).
    expect(w.styles.some((s) => s.width === 120 && s.height === 26)).toBe(true)
  })

  it('a stat with NO spark draws no segments — the feature is opt-in by data', () => {
    const w = walk({ type: 'stat', value: '42', label: 'answers' })
    expect(rotations(w)).toEqual([])
    expect(dots(w)).toEqual([])
  })

  it('a single-point spark is a lone dot, never a crash or a fake line', () => {
    const w = walk({ type: 'stat', value: '1', spark: [7] })
    expect(rotations(w)).toEqual([])
    expect(dots(w)).toHaveLength(1)
  })

  it('a flat spark stays inside the box instead of dividing by a zero span', () => {
    const w = walk({ type: 'stat', value: '1', spark: [5, 5, 5] })
    expect(rotations(w)).toHaveLength(2)
    for (const angle of rotations(w)) expect(angle).toBeCloseTo(0, 6)
  })

  it('drops non-numeric spark entries rather than plotting NaN', () => {
    const w = walk({ type: 'stat', value: '1', spark: [1, 'junk', null, 3] })
    expect(dots(w)).toHaveLength(2)
  })

  it('the honest-omission comment RETIRED with the feature', () => {
    // The law moved with the code (blocks.tsx:494's note at split time): the
    // comment claimed sparklines were dropped for want of an SVG dependency,
    // which is now false. A future re-drop must retire the feature AND restate
    // the omission — not leave a stale promise in the header.
    const fs = jest.requireActual<typeof import('node:fs')>('node:fs')
    const path = jest.requireActual<typeof import('node:path')>('node:path')
    const text = fs.readFileSync(
      path.join(__dirname, '..', 'src', 'papers', 'portabledoc', 'blocks', 'dataviz.tsx'),
      'utf8',
    )
    expect(text).not.toContain('sparklines are omitted')
    expect(text).not.toContain('no SVG dependency in v1')
  })
})
