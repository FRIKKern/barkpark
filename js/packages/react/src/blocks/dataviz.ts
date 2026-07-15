// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Data-viz block emitters — the JS twins of data_viz.ex at style=:article:
// `stat`, `stats`/`stat-grid`, `heatmap` (legacy grid + calendar + matrix modes),
// and `chart` (inline SVG line/bars). All colour rides paper tokens / bin classes,
// never author-controlled inline colour. Empty/absent data → the honest
// `bp-dataviz bp-dataviz--empty` box (the browser twin of pdrender's placeholder).

import { type Block, escapeHtml, isMap } from '../inline'

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
  return asArr(v).map(numeric).filter((n): n is number => n !== null)
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
  let bar = ''
  if (max !== null && max > 0) {
    const nv = numeric(value)
    const pct = nv === null ? 0.0 : clamp(nv / max, 0.0, 1.0)
    bar = `<div class="bp-stat__bar"><i style="width:${fmt(pct * 100)}%"></i></div>`
  }
  const labelHtml = label === '' ? '' : `<div class="bp-stat__l">${escapeHtml(label)}</div>`
  return `<div class="bp-stat">${bar}<div class="bp-stat__v">${escapeHtml(value)}${denomHtml}</div>${labelHtml}${sparkSvg(spark)}</div>`
}

const stats: Emit = (block) => {
  const items = asArr(get(block, 'items')).filter(isMap)
  if (items.length === 0) return empty('stats')
  return `<div class="bp-stats">${items.map(statHtml).join('')}</div>`
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
  const nz = grid.flat().filter((v) => v > 0).sort((a, b) => a - b)
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
  const maxVal = maxNum !== null && maxNum > 0 ? maxNum : Math.max(...grid.flat(), 1.0, 1e-9)
  const rowLabels = stringList(get(block, 'rowLabels'))
  const colLabels = stringList(get(block, 'colLabels'))
  const cols = Math.max(...grid.map((r) => r.length), 0)

  let head = ''
  if (colLabels.length > 0) {
    const corner = rowLabels.length === 0 ? '' : '<span class="bp-heat__rl"></span>'
    let cells = ''
    for (let j = 0; j < cols; j++) cells += `<span class="bp-heat__cl">${escapeHtml(colLabels[j] ?? '')}</span>`
    head = corner + cells
  }

  let body = ''
  grid.forEach((row, i) => {
    const label = rowLabels.length === 0 ? '' : `<span class="bp-heat__rl">${escapeHtml(rowLabels[i] ?? '')}</span>`
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
  for (const i of [0.15, 0.35, 0.55, 0.75, 1.0]) legend += `<i class="bp-heat__c" style="--i:${fmt3(i)}"></i>`
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
    for (let w = 0; w < weeks; w++) cells += `<span class="bp-heat__ml">${escapeHtml(colLabels[w] ?? '')}</span>`
    head = corner + cells
  }

  let body = ''
  grid.forEach((row, i) => {
    const label = rowLabels.length === 0 ? '' : `<span class="bp-heat__rl">${escapeHtml(rowLabels[i] ?? '')}</span>`
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
  if (showVals) return `<i class="bp-heat__c ${binClass(bin)} bp-heat__c--v" title="${fmt(v)}">${fmt(v)}</i>`
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
    for (let j = 0; j < cols; j++) labels += `<span class="bp-heat__cl">${escapeHtml(colLabels[j] ?? '')}</span>`
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
  return out + `<line class="bp-chart__axis" x1="${PAD_L}" y1="${VH - PAD_B}" x2="${VW - PAD_R}" y2="${VH - PAD_B}"/>`
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

  return (
    `<div class="bp-chart">${capHtml}` +
    `<svg viewBox="0 0 ${VW} ${VH}" preserveAspectRatio="none" role="img">` +
    gridSvg(minV, maxV) +
    plot +
    xLabelsSvg(xLabels) +
    `</svg>${legendHtml(series)}</div>`
  )
}

export const datavizEmitters: Record<string, Emit> = {
  stat,
  stats,
  'stat-grid': stats,
  heatmap,
  chart,
}
