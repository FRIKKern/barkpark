// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Data-viz block emitters — the JS twins of data_viz.ex at style=:article:
// `stat`, `stats`/`stat-grid`, `heatmap` (legacy grid + calendar + matrix modes),
// and `chart` (inline SVG line/bars). All colour rides paper tokens / bin classes,
// never author-controlled inline colour. Empty/absent data → the honest
// `bp-dataviz bp-dataviz--empty` box (the browser twin of pdrender's placeholder).

import { type Block, escapeHtml, isMap, safeUrl } from '../inline'

type Emit = (block: Block) => string

/* ── coercion helpers (data_viz.ex small helpers) ──────────────────────────── */

function get(m: unknown, k: string): unknown {
  return isMap(m) ? m[k] : undefined
}
function asArr(v: unknown): unknown[] {
  return Array.isArray(v) ? v : []
}
function numeric(v: unknown): number | null {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null
  if (typeof v === 'string') {
    const t = v.trim()
    if (t === '') return null
    const f = Number(t)
    return Number.isFinite(f) && /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(t) ? f : null
  }
  return null
}
function displayString(v: unknown): string {
  if (typeof v === 'string') return v.trim()
  if (typeof v === 'number' && Number.isInteger(v)) return String(v)
  if (typeof v === 'number') return fmt(v)
  return ''
}
function numberList(v: unknown): number[] {
  return asArr(v)
    .map(numeric)
    .filter((n): n is number => n !== null)
}
function stringList(v: unknown): string[] {
  return asArr(v).map(displayString)
}
function clamp(v: number, lo: number, hi: number): number {
  return Math.min(Math.max(v, lo), hi)
}
function fmt(v: number): string {
  if (Number.isInteger(v)) return String(v)
  const r = Math.round(v * 10) / 10
  return Number.isInteger(r) ? String(r) : r.toFixed(1)
}
function fmt3(v: number): string {
  return v.toFixed(3)
}
function tick(v: number): string {
  const r = Math.round(v * 10) / 10
  return Number.isInteger(r) ? String(r) : r.toFixed(1)
}
function tickCompact(v: number): string {
  if (Math.abs(v) < 10000) return tick(v)
  let div = 1e3
  let suffix = 'k'
  if (Math.abs(v) >= 1e9) {
    div = 1e9
    suffix = 'B'
  } else if (Math.abs(v) >= 1e6) {
    div = 1e6
    suffix = 'M'
  }
  return (v / div).toFixed(1).replace(/\.0$/, '') + suffix
}

function empty(kind: string): string {
  return `<div class="bp-dataviz bp-dataviz--empty">${escapeHtml(kind)} — no data</div>`
}

/* ── stat / stats ──────────────────────────────────────────────────────────── */

function sparkSvg(values: number[]): string {
  if (values.length === 0) return ''
  const n = values.length
  const minV = Math.min(...values)
  const maxV = Math.max(...values)
  const span = maxV - minV <= 0 ? 1.0 : maxV - minV
  const w = 120
  const h = 26
  const pts = values
    .map((v, i) => {
      const x = n <= 1 ? w / 2 : (w * i) / (n - 1)
      const y = 2 + (h - 4) * (1.0 - (v - minV) / span)
      return `${fmt(x)},${fmt(y)}`
    })
    .join(' ')
  return `<svg class="bp-stat__spark" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none" aria-hidden="true"><polyline points="${pts}"/></svg>`
}

const stat: Emit = (block) => statHtml(block)

function statHtml(block: unknown): string {
  if (!isMap(block)) return empty('stat')
  const value = displayString(get(block, 'value'))
  if (value === '') return empty('stat')
  const label = displayString(get(block, 'label'))
  const max = numeric(get(block, 'max'))
  const spark = numberList(get(block, 'spark'))
  const denom = displayString(get(block, 'denom'))
  const denomHtml = denom === '' ? '' : `<span class="bp-stat__denom">/${escapeHtml(denom)}</span>`
  // Unit/qualifier riding after the number ("%", "USD", "dager") — a separate
  // span, never fused into the display string (jarl figure family).
  const unit = displayString(get(block, 'unit'))
  const unitHtml = unit === '' ? '' : `<span class="bp-stat__unit">${escapeHtml(unit)}</span>`
  // One-sentence prose under the label — what the tile's number means.
  const body = displayString(get(block, 'body'))
  const bodyHtml = body === '' ? '' : `<div class="bp-stat__body">${escapeHtml(body)}</div>`
  let bar = ''
  if (max !== null && max > 0) {
    const nv = numeric(value)
    const pct = nv === null ? 0.0 : clamp(nv / max, 0.0, 1.0)
    bar = `<div class="bp-stat__bar"><i style="width:${fmt(pct * 100)}%"></i></div>`
  }
  const labelHtml = label === '' ? '' : `<div class="bp-stat__l">${escapeHtml(label)}</div>`
  // THE KILDE LAW: a stat is a datum, and a datum carries its provenance.
  const ref = parseSourceRef(displayString(get(block, 'source')))
  const kilde = kildeHtml(ref === null ? [] : [ref])
  return `<div class="bp-stat">${bar}<div class="bp-stat__v">${escapeHtml(value)}${denomHtml}${unitHtml}</div>${labelHtml}${bodyHtml}${sparkSvg(spark)}${kilde}</div>`
}

const stats: Emit = (block) => {
  const items = asArr(get(block, 'items')).filter(isMap)
  if (items.length === 0) return empty('stats')
  // Kilde law, aggregated: per-cell `source` (fallback `sourceDefault`) rolls
  // into ONE deduped footer — cells never stamp their own.
  const dflt = displayString(get(block, 'sourceDefault'))
  const refs = figureRefs(items, dflt, (it) => displayString(get(it, 'value')) !== '')
  const cells = items.map((it) => statHtml(omitSource(it))).join('')
  return `<div class="bp-stats">${cells}${kildeHtml(refs)}</div>`
}

/* ── kilde (source provenance) ─────────────────────────────────────────────── */
//
// THE KILDE LAW (jdf-bl-historiene-renderer-reconciliation): every figure
// datum carries a source ref — `commit:<sha>` | `paper:<slug>` | `task:<id>` |
// `https://…` — surfaced as a small «kilde» stamp under the figure. A ref that
// does not parse never renders: a bad ref is not evidence. Only https refs
// link out; commit/paper/task print as plain provenance text.

interface SourceRef {
  raw: string
  label: string
  href: string | null
}

export function parseSourceRef(ref: unknown): SourceRef | null {
  if (typeof ref !== 'string') return null
  if (/^commit:[0-9a-f]{7,40}$/.test(ref)) {
    return { raw: ref, label: 'commit:' + ref.slice(7, 14), href: null }
  }
  if (/^paper:[a-z0-9][a-z0-9-]*$/.test(ref)) return { raw: ref, label: ref, href: null }
  if (/^task:[A-Za-z0-9._-]+$/.test(ref)) return { raw: ref, label: ref, href: null }
  if (ref.startsWith('https://') && ref.length > 8) {
    const label = ref.replace(/^https:\/\//, '').replace(/\/+$/, '')
    return { raw: ref, label, href: ref }
  }
  return null
}

// Only datum-bearing items (per `isDatum`) carry the provenance obligation;
// each takes its own `source` or the figure's `sourceDefault`; invalid refs
// drop; dedup by raw ref in first-use order (authored order is never sorted).
function figureRefs(
  items: unknown[],
  dflt: string,
  isDatum: (it: unknown) => boolean,
): SourceRef[] {
  const out: SourceRef[] = []
  const seen = new Set<string>()
  for (const it of items) {
    if (!isDatum(it)) continue
    const own = displayString(get(it, 'source'))
    const ref = parseSourceRef(own === '' ? dflt : own)
    if (ref === null || seen.has(ref.raw)) continue
    seen.add(ref.raw)
    out.push(ref)
  }
  return out
}

// The «kilde» stamp: "Kilde" (one ref) / "Kilder" (several), then each ref.
function kildeHtml(refs: SourceRef[]): string {
  if (refs.length === 0) return ''
  const word = refs.length > 1 ? 'Kilder' : 'Kilde'
  const spans = refs
    .map((r) => {
      const inner =
        r.href === null
          ? escapeHtml(r.label)
          : // safeUrl is defense-in-depth over the parseSourceRef https-only gate:
            // today href is non-null ONLY for `https://…` refs, for which safeUrl
            // returns the same attr-escaped bytes escapeHtml did (goldens
            // byte-identical). If that parse-gate is ever loosened, the canonical
            // scheme-allowlister still neutralizes javascript:/data:/protocol-
            // relative values to `#` at the sink.
            `<a href="${safeUrl(r.href)}">${escapeHtml(r.label)}</a>`
      return `<span class="bp-kilde__ref">${inner}</span>`
    })
    .join('')
  return `<p class="bp-kilde"><span class="bp-kilde__word">${word}</span>${spans}</p>`
}

function omitSource(it: unknown): unknown {
  if (!isMap(it)) return it
  const rest = { ...it }
  delete rest.source
  return rest
}

/* ── duel (two-arm comparison, jarl figure family) ─────────────────────────── */
//
// Named legend columns (arm A carries the accent), rows of
// {label, delta, valueA, valueB, unit, source}. The delta annotation rides
// under the row label — authored display text ("−30 %"), never computed. Both
// legends are REQUIRED — unnamed columns are a meaningless comparison → the
// honest empty box. Kilde law: every row is a datum; per-row `source`
// (fallback `sourceDefault`) aggregates into the stamp.

function duelRowHtml(r: unknown): string {
  const label = displayString(get(r, 'label'))
  const delta = displayString(get(r, 'delta'))
  const unit = displayString(get(r, 'unit'))
  const va = displayString(get(r, 'valueA'))
  const vb = displayString(get(r, 'valueB'))
  const deltaHtml = delta === '' ? '' : `<span class="bp-duel__delta">${escapeHtml(delta)}</span>`
  const unitHtml = unit === '' ? '' : `<span class="bp-duel__unit">${escapeHtml(unit)}</span>`
  return (
    `<tr class="bp-duel__row"><th class="bp-duel__label" scope="row">${escapeHtml(label)}${deltaHtml}</th>` +
    `<td class="bp-duel__val bp-duel__val--a">${escapeHtml(va)}${unitHtml}</td>` +
    `<td class="bp-duel__val">${escapeHtml(vb)}${unitHtml}</td></tr>`
  )
}

const duel: Emit = (block) => {
  const legendA = displayString(get(block, 'legendA'))
  const legendB = displayString(get(block, 'legendB'))
  const rows = asArr(get(block, 'rows'))
    .filter(isMap)
    .filter((r) => ['label', 'valueA', 'valueB'].some((k) => displayString(get(r, k)) !== ''))
  if (rows.length === 0 || legendA === '' || legendB === '') return empty('duel')
  const dflt = displayString(get(block, 'sourceDefault'))
  const refs = figureRefs(
    rows,
    dflt,
    (r) => displayString(get(r, 'valueA')) !== '' || displayString(get(r, 'valueB')) !== '',
  )
  const head =
    `<thead><tr><th class="bp-duel__th"></th>` +
    `<th class="bp-duel__th bp-duel__th--a" scope="col">${escapeHtml(legendA)}</th>` +
    `<th class="bp-duel__th" scope="col">${escapeHtml(legendB)}</th></tr></thead>`
  const body = rows.map(duelRowHtml).join('')
  return `<div class="bp-duel"><table class="bp-duel__table">${head}<tbody>${body}</tbody></table>${kildeHtml(refs)}</div>`
}

/* ── lineage (dated nodes on a line, jarl figure family) ───────────────────── */
//
// Each node is {overline, title, body, value, unit, source} — `overline`
// carries the date/period ("jan–sep 2025", "i dag") or qualifier, value+unit
// an optional datum. Nodes render in authored order; a node with nothing to
// say contributes nothing. Kilde law: datum-bearing nodes (those with a
// `value`) carry the provenance obligation (own `source`, else
// `sourceDefault`).

function lineageNodeHtml(n: unknown): string {
  const overline = displayString(get(n, 'overline'))
  const title = displayString(get(n, 'title'))
  const value = displayString(get(n, 'value'))
  const unit = displayString(get(n, 'unit'))
  const body = displayString(get(n, 'body'))
  const unitHtml = unit === '' ? '' : `<span class="bp-lineage__unit">${escapeHtml(unit)}</span>`
  const parts =
    (overline === '' ? '' : `<div class="bp-lineage__overline">${escapeHtml(overline)}</div>`) +
    (title === '' ? '' : `<div class="bp-lineage__title">${escapeHtml(title)}</div>`) +
    (value === '' ? '' : `<div class="bp-lineage__value">${escapeHtml(value)}${unitHtml}</div>`) +
    (body === '' ? '' : `<div class="bp-lineage__body">${escapeHtml(body)}</div>`)
  return `<li class="bp-lineage__node">${parts}</li>`
}

const lineage: Emit = (block) => {
  const nodes = asArr(get(block, 'nodes'))
    .filter(isMap)
    .filter((n) =>
      ['overline', 'title', 'body', 'value'].some((k) => displayString(get(n, k)) !== ''),
    )
  if (nodes.length === 0) return empty('lineage')
  const dflt = displayString(get(block, 'sourceDefault'))
  const refs = figureRefs(nodes, dflt, (n) => displayString(get(n, 'value')) !== '')
  const lis = nodes.map(lineageNodeHtml).join('')
  return `<div class="bp-lineage"><ol class="bp-lineage__nodes">${lis}</ol>${kildeHtml(refs)}</div>`
}

/* ── heatmap ───────────────────────────────────────────────────────────────── */

function binClass(bin: number): string {
  if (bin === -1) return 'bp-heat__c--z'
  return `bp-heat__c--b${Math.min(Math.max(bin, 0), 3)}`
}

function dualLegend(): string {
  let s = '<div class="bp-heat__legend">less '
  for (let k = 0; k <= 3; k++) s += `<i class="bp-heat__c bp-heat__c--b${k}"></i>`
  return s + ' more</div>'
}

function quantileBins(grid: number[][]): number[][] {
  const nz = grid
    .flat()
    .filter((v) => v > 0)
    .sort((a, b) => a - b)
  const n = nz.length
  const q = (p: number): number => {
    if (n === 0) return 0.0
    const idx = Math.ceil(p * n) - 1
    return nz[Math.min(Math.max(idx, 0), n - 1)]!
  }
  const q1 = q(0.25)
  const q2 = q(0.5)
  const q3 = q(0.75)
  return grid.map((row) =>
    row.map((v) => {
      if (v <= 0) return -1
      if (v <= q1) return 0
      if (v <= q2) return 1
      if (v <= q3) return 2
      return 3
    }),
  )
}

function normGrid(block: unknown): number[][] {
  return asArr(get(block, 'cells'))
    .map((row) => asArr(row).map((v) => numeric(v) ?? 0.0))
    .filter((row) => row.length > 0)
}

function heatGridHtml(grid: number[][], block: unknown): string {
  const maxNum = numeric(get(block, 'max'))
  // Mirror data_viz.ex heat_grid_html/2: with no explicit `max`, the divisor is
  // the actual grid max (NOT floored at 1.0 — that would flatten all intensities),
  // with 1.0 only as the empty-grid default and 1e-9 as the divide-by-zero floor.
  const flat = grid.flat()
  const maxVal =
    maxNum !== null && maxNum > 0 ? maxNum : Math.max(flat.length ? Math.max(...flat) : 1.0, 1e-9)
  const rowLabels = stringList(get(block, 'rowLabels'))
  const colLabels = stringList(get(block, 'colLabels'))
  const cols = Math.max(...grid.map((r) => r.length), 0)

  let head = ''
  if (colLabels.length > 0) {
    const corner = rowLabels.length === 0 ? '' : '<span class="bp-heat__rl"></span>'
    let cells = ''
    for (let j = 0; j < cols; j++)
      cells += `<span class="bp-heat__cl">${escapeHtml(colLabels[j] ?? '')}</span>`
    head = corner + cells
  }

  let body = ''
  grid.forEach((row, i) => {
    const label =
      rowLabels.length === 0
        ? ''
        : `<span class="bp-heat__rl">${escapeHtml(rowLabels[i] ?? '')}</span>`
    let cells = ''
    for (let j = 0; j < cols; j++) {
      const v = row[j] ?? 0.0
      const iNorm = clamp(v / maxVal, 0.0, 1.0)
      cells += `<i class="bp-heat__c" style="--i:${fmt3(iNorm)}" title="${fmt(v)}"></i>`
    }
    body += label + cells
  })

  const track = rowLabels.length === 0 ? '' : 'auto '
  let legend = '<div class="bp-heat__legend">less '
  for (const i of [0.15, 0.35, 0.55, 0.75, 1.0])
    legend += `<i class="bp-heat__c" style="--i:${fmt3(i)}"></i>`
  legend += ' more</div>'
  return `<div class="bp-heat"><div class="bp-heat__grid" style="grid-template-columns:${track}repeat(${cols},minmax(10px,28px))">${head}${body}</div>${legend}</div>`
}

function heatCalendarHtml(grid: number[][], block: unknown): string {
  const bins = quantileBins(grid)
  const rowLabels = stringList(get(block, 'rowLabels'))
  const colLabels = stringList(get(block, 'colLabels'))
  const weeks = Math.max(...grid.map((r) => r.length), 0)

  let head = ''
  if (colLabels.length > 0) {
    const corner = rowLabels.length === 0 ? '' : '<span class="bp-heat__rl"></span>'
    let cells = ''
    for (let w = 0; w < weeks; w++)
      cells += `<span class="bp-heat__ml">${escapeHtml(colLabels[w] ?? '')}</span>`
    head = corner + cells
  }

  let body = ''
  grid.forEach((row, i) => {
    const label =
      rowLabels.length === 0
        ? ''
        : `<span class="bp-heat__rl">${escapeHtml(rowLabels[i] ?? '')}</span>`
    const binRow = bins[i] ?? []
    let cells = ''
    for (let w = 0; w < weeks; w++) {
      const v = row[w] ?? 0.0
      const bin = binRow[w] ?? -1
      cells += `<i class="bp-heat__c ${binClass(bin)}" title="${fmt(v)}"></i>`
    }
    body += label + cells
  })

  const track = rowLabels.length === 0 ? '' : 'auto '
  return `<div class="bp-heat bp-heat--cal"><div class="bp-heat__scroll"><div class="bp-heat__grid" style="grid-template-columns:${track}repeat(${weeks},12px)">${head}${body}</div></div>${dualLegend()}</div>`
}

function matrixCell(bin: number, v: number, showVals: boolean): string {
  if (showVals)
    return `<i class="bp-heat__c ${binClass(bin)} bp-heat__c--v" title="${fmt(v)}">${fmt(v)}</i>`
  return `<i class="bp-heat__c ${binClass(bin)}" title="${fmt(v)}"></i>`
}

function heatMatrixExtrasHtml(grid: number[][], block: unknown): string {
  const bins = quantileBins(grid)
  const showVals = get(block, 'values') === true
  const showMarg = get(block, 'marginals') === true
  const rowLabels = stringList(get(block, 'rowLabels'))
  const colLabels = stringList(get(block, 'colLabels'))
  const cols = Math.max(...grid.map((r) => r.length), 0)
  const rowSums = grid.map((row) => row.reduce((a, b) => a + b, 0))
  const colSums: number[] = []
  for (let j = 0; j < cols; j++) colSums.push(grid.reduce((a, row) => a + (row[j] ?? 0.0), 0))
  const grand = rowSums.reduce((a, b) => a + b, 0)
  const gutter = rowLabels.length !== 0 || showMarg

  let head = ''
  if (!(colLabels.length === 0 && !showMarg)) {
    const corner = gutter ? '<span class="bp-heat__rl"></span>' : ''
    let labels = ''
    for (let j = 0; j < cols; j++)
      labels += `<span class="bp-heat__cl">${escapeHtml(colLabels[j] ?? '')}</span>`
    const sumHead = showMarg ? '<span class="bp-heat__cl bp-heat__cl--sum">Σ</span>' : ''
    head = corner + labels + sumHead
  }

  let body = ''
  grid.forEach((row, i) => {
    const label = gutter ? `<span class="bp-heat__rl">${escapeHtml(rowLabels[i] ?? '')}</span>` : ''
    const binRow = bins[i] ?? []
    let cells = ''
    for (let j = 0; j < cols; j++) {
      const v = row[j] ?? 0.0
      const bin = binRow[j] ?? -1
      cells += matrixCell(bin, v, showVals)
    }
    const rowSum = showMarg ? `<span class="bp-heat__sum">${fmt(rowSums[i]!)}</span>` : ''
    body += label + cells + rowSum
  })

  let foot = ''
  if (showMarg) {
    foot =
      '<span class="bp-heat__rl">Σ</span>' +
      colSums.map((s) => `<span class="bp-heat__sum">${fmt(s)}</span>`).join('') +
      `<span class="bp-heat__sum bp-heat__sum--grand">${fmt(grand)}</span>`
  }

  const track = gutter ? 'auto ' : ''
  const cellTrack = showVals ? 'minmax(28px,auto)' : 'minmax(10px,28px)'
  const sumTrack = showMarg ? ' auto' : ''
  return `<div class="bp-heat bp-heat--mtx"><div class="bp-heat__grid" style="grid-template-columns:${track}repeat(${cols},${cellTrack})${sumTrack}">${head}${body}${foot}</div>${dualLegend()}</div>`
}

const heatmap: Emit = (block) => {
  const grid = normGrid(block)
  if (grid.length === 0) return empty('heatmap')
  if (displayString(get(block, 'mode')) === 'calendar') return heatCalendarHtml(grid, block)
  if (get(block, 'marginals') === true || get(block, 'values') === true)
    return heatMatrixExtrasHtml(grid, block)
  return heatGridHtml(grid, block)
}

/* ── chart (inline SVG) ────────────────────────────────────────────────────── */

const VW = 640
const VH = 190
const PAD_L = 46
const PAD_R = 10
const PAD_T = 8
const PAD_B = 30

interface Series {
  label: string
  points: number[]
}

function xAt(i: number, n: number): number {
  const inner = VW - PAD_L - PAD_R
  return n <= 1 ? PAD_L + inner / 2 : PAD_L + (inner * i) / (n - 1)
}
function yAt(v: number, minV: number, maxV: number): number {
  const inner = VH - PAD_T - PAD_B
  const norm = clamp((v - minV) / (maxV - minV), 0.0, 1.0)
  return PAD_T + inner * (1.0 - norm)
}

function span(series: Series[], axes: Record<string, unknown>): [number, number] {
  const data = series.flatMap((s) => s.points)
  const dmin = Math.min(...data)
  const dmax = Math.max(...data)
  const pmin = numeric(get(axes, 'min'))
  const pmax = numeric(get(axes, 'max'))
  let minV: number
  let maxV: number
  if (pmin !== null && pmax !== null && pmin >= pmax) {
    minV = dmin
    maxV = dmax
  } else {
    minV = pmin ?? dmin
    maxV = pmax ?? dmax
  }
  return maxV <= minV ? [minV, minV + 1.0] : [minV, maxV]
}

function gridSvg(minV: number, maxV: number): string {
  let out = ''
  for (let k = 0; k <= 3; k++) {
    const v = minV + ((maxV - minV) * (3 - k)) / 3
    const y = yAt(v, minV, maxV)
    out += `<line class="bp-chart__grid" x1="${PAD_L}" y1="${fmt(y)}" x2="${VW - PAD_R}" y2="${fmt(y)}"/>`
    out += `<text class="bp-chart__tick" x="${PAD_L - 6}" y="${fmt(y + 4)}" text-anchor="end">${tickCompact(v)}</text>`
  }
  return (
    out +
    `<line class="bp-chart__axis" x1="${PAD_L}" y1="${VH - PAD_B}" x2="${VW - PAD_R}" y2="${VH - PAD_B}"/>`
  )
}

function plotLine(series: Series[], minV: number, maxV: number, n: number): string {
  return series
    .map((s, si) => {
      const pts = s.points.map((v, i) => `${fmt(xAt(i, n))},${fmt(yAt(v, minV, maxV))}`).join(' ')
      return `<polyline class="bp-chart__s bp-chart__s${si % 4}" points="${pts}"/>`
    })
    .join('')
}

function plotBars(series: Series[], minV: number, maxV: number, n: number): string {
  const ns = series.length
  const slot = (VW - PAD_L - PAD_R) / Math.max(n, 1)
  const barW = Math.max((slot * 0.7) / ns, 1.0)
  const floorY = VH - PAD_B
  return series
    .map((s, si) =>
      s.points
        .map((v, i) => {
          const x = PAD_L + slot * i + slot * 0.15 + barW * si
          const y = yAt(v, minV, maxV)
          return `<rect class="bp-chart__b bp-chart__s${si % 4}" x="${fmt(x)}" y="${fmt(y)}" width="${fmt(barW)}" height="${fmt(Math.max(floorY - y, 0.0))}"/>`
        })
        .join(''),
    )
    .join('')
}

function xLabelsSvg(labels: string[]): string {
  if (labels.length === 0) return ''
  const first = labels[0] ?? ''
  const last = labels[labels.length - 1] ?? ''
  const y = VH - PAD_B + 16
  let out = `<text class="bp-chart__tick" x="${PAD_L}" y="${y}" text-anchor="start">${escapeHtml(first)}</text>`
  if (last !== '' && labels.length > 1)
    out += `<text class="bp-chart__tick" x="${VW - PAD_R}" y="${y}" text-anchor="end">${escapeHtml(last)}</text>`
  return out
}

function legendHtml(series: Series[]): string {
  return (
    '<div class="bp-chart__legend">' +
    series
      .map((s, si) => {
        const label = s.label === '' ? `series ${si + 1}` : s.label
        return `<span class="bp-chart__key"><i class="bp-chart__swatch bp-chart__s${si % 4}"></i>${escapeHtml(label)}</span>`
      })
      .join('') +
    '</div>'
  )
}

const chart: Emit = (block) => {
  const series: Series[] = asArr(get(block, 'series'))
    .map((s) => ({ label: displayString(get(s, 'label')), points: numberList(get(s, 'points')) }))
    .filter((s) => s.points.length > 0)
    .slice(0, 4)
  if (series.length === 0) return empty('chart')

  const kind = displayString(get(block, 'kind')) === 'bars' ? 'bars' : 'line'
  const axes = isMap(get(block, 'axes')) ? (get(block, 'axes') as Record<string, unknown>) : {}
  let [minV, maxV] = span(series, axes)
  if (kind === 'bars' && numeric(get(axes, 'min')) === null) minV = Math.min(0.0, minV)

  const xLabels = stringList(get(axes, 'xLabels'))
  const caption = displayString(get(block, 'caption'))
  const n = Math.max(...series.map((s) => s.points.length))
  const capHtml = caption === '' ? '' : `<div class="bp-chart__t">${escapeHtml(caption)}</div>`
  const plot = kind === 'bars' ? plotBars(series, minV, maxV, n) : plotLine(series, minV, maxV, n)

  // The svg rides its own scroll container, mirroring data_viz.ex: CSS pins
  // the svg at its viewBox width so tick/label text never paints below its
  // authored px at narrow viewports — the figure scrolls instead of shrinking.
  return (
    `<div class="bp-chart">${capHtml}` +
    `<div class="bp-chart__scroll">` +
    `<svg viewBox="0 0 ${VW} ${VH}" preserveAspectRatio="none" role="img">` +
    gridSvg(minV, maxV) +
    plot +
    xLabelsSvg(xLabels) +
    `</svg></div>${legendHtml(series)}</div>`
  )
}

/* ── gauge-list (data_viz.ex gauge_list_html) ──────────────────────────────── */

interface Gauge {
  label: string
  prop: number
  digit: string
  note: string
}

// share | count, mirroring data_viz.ex gauge_mode/1: explicit "mode" wins, else
// `rows` present without `snapshot` → share (a hand-authored share list), else count.
function gaugeMode(block: unknown): 'share' | 'count' {
  const m = displayString(get(block, 'mode')).toLowerCase()
  if (m === 'count') return 'count'
  if (m === 'share') return 'share'
  if (isMap(block) && 'rows' in block && !('snapshot' in block)) return 'share'
  return 'count'
}

// share_gauges/1: each row's value as a proportion of `max` (or the summed total).
function shareGauges(block: unknown): Gauge[] {
  const items = asArr(get(block, 'rows')).filter(isMap)
  if (items.length === 0) return []
  const sum = items.reduce((a, it) => a + (numeric(get(it, 'value')) ?? 0.0), 0)
  const max = numeric(get(block, 'max'))
  let denom = max !== null && max > 0 ? max : sum
  if (denom <= 0) denom = 1.0
  return items.map((it) => {
    const prop = clamp((numeric(get(it, 'value')) ?? 0.0) / denom, 0.0, 1.0)
    return {
      label: displayString(get(it, 'label')),
      prop,
      digit: `${Math.round(prop * 100)}%`,
      note: displayString(get(it, 'note')),
    }
  })
}

// A task row's bucket label (gauge_bucket_key/2): priority via its P<n> label,
// every other field by its trimmed string; missing/empty → "(none)".
function gaugeBucketKey(row: unknown, groupBy: string): string {
  if (groupBy === 'priority') {
    const p = displayString(get(row, 'priority'))
    return p === '' ? '(none)' : 'P' + p
  }
  const key = displayString(get(row, groupBy))
  return key === '' ? '(none)' : key
}

// count_gauges/1: frequency of a `snapshot` grouped by a field; the unbacked
// "epic" groupBy signals with the 'epic' sentinel (the note the renderer shows).
function countGauges(block: unknown): 'epic' | Gauge[] {
  const raw = displayString(get(block, 'groupBy'))
  const groupBy = raw === '' ? 'status' : raw
  if (groupBy === 'epic') return 'epic'
  const rows = asArr(get(block, 'snapshot')).filter(isMap)
  if (rows.length === 0) return []
  const counts = new Map<string, number>()
  for (const r of rows) {
    const k = gaugeBucketKey(r, groupBy)
    counts.set(k, (counts.get(k) ?? 0) + 1)
  }
  const maxCount = Math.max(1, ...counts.values())
  const entries = [...counts.entries()].sort((a, b) =>
    a[1] !== b[1] ? b[1] - a[1] : a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0,
  )
  return entries.map(([label, count]) => ({ label, prop: count / maxCount, digit: String(count), note: '' }))
}

function gaugeRows(block: unknown): 'epic' | Gauge[] {
  return gaugeMode(block) === 'share' ? shareGauges(block) : countGauges(block)
}

const gaugeList: Emit = (block) => {
  if (!isMap(block)) return empty('gauge-list')
  const title = displayString(get(block, 'title'))
  const titleHtml = title === '' ? '' : `<div class="bp-gauge__t">${escapeHtml(title)}</div>`
  const rows = gaugeRows(block)
  if (rows === 'epic') {
    return (
      `<div class="bp-gauge">${titleHtml}` +
      `<div class="bp-gauge__note">groupBy "epic" is unbacked here — needs the epic resolver</div></div>`
    )
  }
  if (rows.length === 0) return empty('gauge-list')
  const body = rows
    .map((g) => {
      const noteHtml = g.note === '' ? '' : `<span class="bp-gauge__n">${escapeHtml(g.note)}</span>`
      return (
        `<div class="bp-gauge__row">` +
        `<span class="bp-gauge__l">${escapeHtml(g.label)}</span>` +
        `<span class="bp-gauge__bar"><i style="width:${fmt(g.prop * 100)}%"></i></span>` +
        `<span class="bp-gauge__d">${escapeHtml(g.digit)}</span>` +
        noteHtml +
        `</div>`
      )
    })
    .join('')
  return `<div class="bp-gauge">${titleHtml}${body}</div>`
}

/* ── bar-chart (horizontal bars for categorical counts, B003) ──────────────── */
//
// bar-chart: {bars: [{label, value}], max?, values?}. Rides the same
// proportional-bar vocabulary as gauge-list's share mode (a labeled row +
// a filled track), but denominated by the DATA MAX (never the sum — bars
// are categorical counts, not shares) unless an explicit `max` is given.
const barChart: Emit = (block) => {
  const bars = asArr(get(block, 'bars')).filter(isMap)
  if (bars.length === 0) return empty('bar-chart')
  const values = bars.map((b) => numeric(get(b, 'value')) ?? 0.0)
  const explicitMax = numeric(get(block, 'max'))
  let denom = explicitMax !== null && explicitMax > 0 ? explicitMax : Math.max(...values)
  if (denom <= 0) denom = 1.0
  const showValues = get(block, 'values') === true

  const rows = bars
    .map((b, i) => {
      const label = displayString(get(b, 'label'))
      const value = values[i] ?? 0.0
      const prop = clamp(value / denom, 0.0, 1.0)
      const digitHtml = showValues
        ? `<span class="bp-bar-chart__d">${escapeHtml(fmt(value))}</span>`
        : ''
      return (
        `<div class="bp-bar-chart__row">` +
        `<span class="bp-bar-chart__l">${escapeHtml(label)}</span>` +
        `<span class="bp-bar-chart__bar"><i style="width:${fmt(prop * 100)}%"></i></span>` +
        digitHtml +
        `</div>`
      )
    })
    .join('')
  return `<div class="bp-bar-chart">${rows}</div>`
}

/* ── criteria-progress (acceptance-criteria met/total rollup, B034) ───────── */
//
// criteria-progress: {rows: [{label, met, total}], detail?: 'rows'|'total'}.
// Renders from its OWN attrs — no live task-resolver query at render time.
// Same proportional-bar vocabulary as bar-chart, but the denominator is each
// row's own `total` (a fraction, not a shared max) and the digit is always
// shown (met/total IS the datum). `detail: 'total'` collapses all rows into
// one aggregate bar (summed met/total, label "Total").
function effectiveCriteriaRows(rows: unknown[], detail: unknown): unknown[] {
  if (detail !== 'total') return rows
  let met = 0
  let total = 0
  for (const row of rows) {
    met += numeric(get(row, 'met')) ?? 0
    total += numeric(get(row, 'total')) ?? 0
  }
  return [{ label: 'Total', met, total }]
}

const criteriaProgress: Emit = (block) => {
  const rows = asArr(get(block, 'rows')).filter(isMap)
  if (rows.length === 0) return empty('criteria-progress')

  const body = effectiveCriteriaRows(rows, get(block, 'detail'))
    .map((row) => {
      const met = numeric(get(row, 'met')) ?? 0
      const total = numeric(get(row, 'total')) ?? 0
      const prop = total > 0 ? clamp(met / total, 0.0, 1.0) : 0.0
      const label = displayString(get(row, 'label'))
      return (
        `<div class="bp-criteria-progress__row">` +
        `<span class="bp-criteria-progress__l">${escapeHtml(label)}</span>` +
        `<span class="bp-criteria-progress__bar"><i style="width:${fmt(prop * 100)}%"></i></span>` +
        `<span class="bp-criteria-progress__d">${escapeHtml(fmt(met))}/${escapeHtml(fmt(total))}</span>` +
        `</div>`
      )
    })
    .join('')
  return `<div class="bp-criteria-progress">${body}</div>`
}

/* ── route (sport track) ─────────────────────────────────────────────────────
 * The JS twin of data_viz.ex §route: `polyline` carries a Google encoded
 * polyline; the render is a self-contained SVG track shape (equirectangular,
 * cos(mid-lat) x-scale; start ring green, finish dot terracotta) + the meta
 * row and caption. Byte-mirrors the Elixir :article emitter — same projection,
 * same 2-decimal formatting, same evergreen skin literals — so the golden
 * parity harness proves shape equality per type. */

const ROUTE_W = 640
const ROUTE_MAX_H = 400
const ROUTE_PAD = 16
const ROUTE_START = '#2f9e63'
const ROUTE_FINISH = '#c65a3f'
const ROUTE_TRACK = 'var(--paper-accent, #1e5347)'
const ROUTE_MUTED = '#55635e'
const ROUTE_BORDER = '#dde7e2'

/** Google encoded-polyline decoder — the same drop-at-last-whole-pair contract
 * as the Elixir/Go twins: a malformed tail never invents a point. */
export function decodePolyline(s: string): Array<[number, number]> {
  const out: Array<[number, number]> = []
  let lat = 0
  let lng = 0
  let i = 0

  const next = (): number | null => {
    let shift = 0
    let acc = 0
    while (i < s.length) {
      const c = s.charCodeAt(i)
      if (c < 63 || c > 126) return null
      i++
      acc |= ((c - 63) & 0x1f) << shift
      if (((c - 63) & 0x20) === 0) return (acc & 1) !== 0 ? -((acc >> 1) + 1) : acc >> 1
      shift += 5
    }
    return null
  }

  while (i < s.length) {
    const dlat = next()
    if (dlat === null) break
    const dlng = next()
    if (dlng === null) break
    lat += dlat
    lng += dlng
    out.push([lat / 1e5, lng / 1e5])
  }
  return out
}

const fmt2 = (v: number): string => v.toFixed(2)

const route: Emit = (block) => {
  const points = decodePolyline(displayString(get(block, 'polyline')))
  if (points.length < 2) return empty('route')

  const midLat = points.reduce((a, p) => a + p[0], 0) / points.length
  const k = Math.cos((midLat * Math.PI) / 180)
  const projected = points.map((p): [number, number] => [p[1] * k, -p[0]])
  const minX = Math.min(...projected.map((q) => q[0]))
  const minY = Math.min(...projected.map((q) => q[1]))
  const spanX = Math.max(Math.max(...projected.map((q) => q[0])) - minX, 1e-9)
  const spanY = Math.max(Math.max(...projected.map((q) => q[1])) - minY, 1e-9)

  const innerW = ROUTE_W - 2 * ROUTE_PAD
  const scale = Math.min(innerW / spanX, (ROUTE_MAX_H - 2 * ROUTE_PAD) / spanY)
  const h = Math.round(spanY * scale) + 2 * ROUTE_PAD

  const coords = projected.map(([x, y]): [string, string] => [
    fmt2((x - minX) * scale + ROUTE_PAD),
    fmt2((y - minY) * scale + ROUTE_PAD),
  ])

  const first = coords[0]
  const last = coords[coords.length - 1]
  if (first === undefined || last === undefined) return empty('route')

  const d = coords.map(([x, y], i2) => `${i2 === 0 ? 'M' : 'L'}${x},${y}`).join(' ')
  const [sx, sy] = first
  const [fx, fy] = last

  const svg =
    `<svg class="bp-route__map" viewBox="0 0 ${ROUTE_W} ${h}" role="img" aria-label="route track" style="display:block;width:100%;max-width:${ROUTE_W}px;height:auto;">` +
    `<path d="${d}" fill="none" stroke="${ROUTE_TRACK}" stroke-width="3" stroke-linejoin="round" stroke-linecap="round"/>` +
    `<circle cx="${sx}" cy="${sy}" r="5.5" fill="none" stroke="${ROUTE_START}" stroke-width="3"/>` +
    `<circle cx="${fx}" cy="${fy}" r="5.5" fill="${ROUTE_FINISH}"/>` +
    `</svg>`

  const meta = ['sport', 'distance', 'elevation', 'duration']
    .map((key) => displayString(get(block, key)))
    .filter((v) => v !== '')

  const metaHtml =
    meta.length === 0
      ? ''
      : `<div class="bp-route__meta" style="font-size:13px;color:${ROUTE_MUTED};margin-top:6px;">` +
        meta.map(escapeHtml).join(` <span style="color:${ROUTE_BORDER};">·</span> `) +
        '</div>'

  const caption = displayString(get(block, 'caption'))
  const captionHtml =
    caption === ''
      ? ''
      : `<div class="bp-route__caption" style="font-size:13px;color:${ROUTE_MUTED};font-style:italic;margin-top:2px;">${escapeHtml(caption)}</div>`

  return `<div class="bp-route">${svg}${metaHtml}${captionHtml}</div>`
}

export const datavizEmitters: Record<string, Emit> = {
  stat,
  stats,
  'stat-grid': stats,
  heatmap,
  chart,
  duel,
  lineage,
  'gauge-list': gaugeList,
  'bar-chart': barChart,
  'criteria-progress': criteriaProgress,
  route,
}
