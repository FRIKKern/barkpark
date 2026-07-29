// dataviz family (charter D49): stat, stats/stat-grid, chart, heatmap,
// gauge-list, bar-chart, criteria-progress — the dataviz.ts twins.
//
// THE DRAWING LAW (charter D56 — zero new dependencies). `react-native-svg` is
// REJECTED on record (a native module drags in a dev build), so every mark here
// is a plain View:
//
//   • bars / gauges / criteria / heat cells — flex rows and percentage widths.
//     The web is already div-only there (paper-surface.css .bp-gauge__bar i is
//     a percentage-width block), so these are twins, not substitutes.
//   • line charts and the stat sparkline — `lineSegments()` below: one 2pt View
//     per segment, rotated about its own centre, plus a 3pt round dot at each
//     vertex. The dots recover what SVG got from stroke-linejoin:round; the
//     joins are a RECORDED cosmetic deviation, not a claim of parity.
//   • the heatmap's `color-mix(in srgb, accent N%, rule)` — `lerpHex()`, the
//     same two channels the CSS mixes.
//
// CHEAP FIRST FRAME (D56, the LegendList caution: ESTIMATED_ROW_HEIGHT=180 and
// no recycleItems). Nothing here measures: no onLayout, no state, no effect, no
// second pass. The chart plot is a `width:'100%' + aspectRatio` box and every
// mark inside it is positioned in PERCENTAGES of that box. A fixed aspect ratio
// makes the logical→rendered mapping UNIFORM, which is what lets a rotated
// segment keep its angle and express its length as one percentage of the width.
// Stroke thicknesses stay in points — the web's own `vector-effect:
// non-scaling-stroke`.
//
// REGISTER (D50): dataviz carries no prose runs. Every string here is
// apparatus — a mono row label, a digit, an axis tick — so it rides the chrome
// scale rather than `bodyText(ctx)`, and the two registers render identically.
// That blindness is legitimate and belongs on the crown's REGISTER_BLIND
// allowlist alongside divider/table.
import type { ReactNode } from 'react'
import { ScrollView, Text, View } from 'react-native'

import type { Theme } from '../../../ui/theme'
import { roles, scale } from '../../../ui/typography'
import { asList, isMap, num, str } from '../model'
import { MONO, type BlockCtx, type Render } from '../register'

/* ── coercion (the dataviz.ts twins) ───────────────────────────────────────── */

// WIDER than model.ts's `num()`, which floors at > 0. In a chart a 0 is a datum
// and a −3 is a datum; dropping them would silently reshape the plot. This is
// data_viz.ex/dataviz.ts `numeric/1` verbatim, strict regex included.
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

function fmt(v: number): string {
  if (Number.isInteger(v)) return String(v)
  const r = Math.round(v * 10) / 10
  return Number.isInteger(r) ? String(r) : r.toFixed(1)
}

function displayString(v: unknown): string {
  if (typeof v === 'string') return v.trim()
  if (typeof v === 'number' && Number.isFinite(v)) return fmt(v)
  return ''
}

function numberList(v: unknown): number[] {
  return asList(v)
    .map(numeric)
    .filter((n): n is number => n !== null)
}

function stringList(v: unknown): string[] {
  return asList(v).map(displayString)
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.min(Math.max(v, lo), hi)
}

/** dataviz.ts tickCompact: plain below 10k, then k/M/B. */
function tickCompact(v: number): string {
  if (Math.abs(v) < 10000) return fmt(v)
  const [div, suffix] = Math.abs(v) >= 1e9 ? [1e9, 'B'] : Math.abs(v) >= 1e6 ? [1e6, 'M'] : [1e3, 'k']
  return (v / (div as number)).toFixed(1).replace(/\.0$/, '') + String(suffix)
}

type Pct = `${number}%`

function pct(fraction: number): Pct {
  return `${Math.round(fraction * 1000) / 10}%`
}

/* ── primitive 1: the RGB lerp (CSS color-mix, two channels) ────────────────── */

/** `color-mix(in srgb, <to> t%, <from>)` for #rrggbb inputs — the heatmap's
 * only colour machinery. A non-hex input returns `to` unmixed rather than
 * NaN-painting a cell. */
export function lerpHex(from: string, to: string, t: number): string {
  if (!/^#[0-9a-f]{6}$/i.test(from) || !/^#[0-9a-f]{6}$/i.test(to)) return to
  const a = Number.parseInt(from.slice(1), 16)
  const b = Number.parseInt(to.slice(1), 16)
  const k = clamp(t, 0, 1)
  const ch = (sh: number) => Math.round(((a >> sh) & 255) * (1 - k) + ((b >> sh) & 255) * k)
  return `#${((1 << 24) | (ch(16) << 16) | (ch(8) << 8) | ch(0)).toString(16).slice(1)}`
}

/* ── primitive 2: the line segment (SVG polyline, without SVG) ─────────────── */

export interface Pt {
  x: number
  y: number
}

/** One drawn segment, in the SAME units its input points came in: the CENTRE of
 * the rotated box, its length, and the rotation in degrees. The caller decides
 * whether to emit those as points (the fixed-size sparkline) or as percentages
 * of a uniform box (the chart). */
export interface Seg {
  midX: number
  midY: number
  len: number
  angle: number
}

/** The n−1 segments of a polyline. Zero-length runs (a repeated point) are
 * DROPPED — a 0-width rotated View paints nothing and would only cost layout;
 * the vertex dot still marks the spot. */
export function lineSegments(points: Pt[]): Seg[] {
  const out: Seg[] = []
  for (let i = 1; i < points.length; i++) {
    const p = points[i - 1]!
    const q = points[i]!
    const dx = q.x - p.x
    const dy = q.y - p.y
    const len = Math.sqrt(dx * dx + dy * dy)
    if (len === 0) continue
    out.push({
      midX: (p.x + q.x) / 2,
      midY: (p.y + q.y) / 2,
      len,
      angle: (Math.atan2(dy, dx) * 180) / Math.PI,
    })
  }
  return out
}

const STROKE = 2
const DOT = 3

/** The polyline as absolutely-positioned Views. `box` picks the coordinate
 * space: 'pt' for a fixed-size container, or a {w,h} pair to emit percentages
 * of a uniform box (angles survive because the mapping scales both axes
 * alike). Each segment is positioned by its CENTRE, which is what RN rotates
 * about. */
function polyline(points: Pt[], color: string, box: { w: number; h: number } | 'pt'): ReactNode[] {
  const asPct = box !== 'pt'
  const x = (v: number) => (asPct ? pct(v / box.w) : v)
  const y = (v: number) => (asPct ? pct(v / box.h) : v)
  const width = (v: number) => (asPct ? pct(v / box.w) : v)
  const out: ReactNode[] = []
  lineSegments(points).forEach((s, i) => {
    out.push(
      <View
        key={`s${i}`}
        style={{
          position: 'absolute',
          left: x(s.midX - s.len / 2),
          top: y(s.midY),
          marginTop: -STROKE / 2,
          width: width(s.len),
          height: STROKE,
          borderRadius: STROKE / 2,
          backgroundColor: color,
          transform: [{ rotate: `${Math.round(s.angle * 100) / 100}deg` }],
        }}
      />,
    )
  })
  // The joins SVG drew with stroke-linejoin:round (D56's recorded deviation).
  points.forEach((p, i) => {
    out.push(
      <View
        key={`v${i}`}
        style={{
          position: 'absolute',
          left: x(p.x),
          top: y(p.y),
          marginLeft: -DOT / 2,
          marginTop: -DOT / 2,
          width: DOT,
          height: DOT,
          borderRadius: DOT / 2,
          backgroundColor: color,
        }}
      />,
    )
  })
  return out
}

/* ── primitive 3: the labelled proportional row ────────────────────────────── */

// Serves gauge-list, bar-chart AND criteria-progress — the three blocks the web
// draws with the same vocabulary (a mono label, an 8px track, a filled
// percentage, a right-aligned digit) and only a different DENOMINATOR. Kept a
// plain function rather than a component so the suites' element walker sees
// through it (a custom element is a leaf to `walk()`), matching statCard.
interface BarRow {
  label: string
  /** 0…1, already clamped by the caller's own denominator law. */
  prop: number
  digit: string
  note?: string
}

const TRACK = 8

function barRow(row: BarRow, ctx: BlockCtx, key: number): ReactNode {
  return (
    <View key={key} style={{ flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 3 }}>
      <Text numberOfLines={1} style={{ ...scale.xs, fontFamily: MONO, color: ctx.theme.text, width: 96 }}>
        {row.label}
      </Text>
      <View
        style={{
          flex: 1,
          height: TRACK,
          borderRadius: TRACK / 2,
          backgroundColor: ctx.theme.border,
          overflow: 'hidden',
        }}
      >
        <View
          style={{
            height: TRACK,
            borderRadius: TRACK / 2,
            width: pct(row.prop),
            backgroundColor: ctx.theme.accent,
          }}
        />
      </View>
      {/* No digit, no column: the web omits the span entirely on
          `values: false`, so reserving its 36pt would leave dead gutter. */}
      {row.digit !== '' && (
        <Text
          style={{ ...scale.xs, fontFamily: MONO, color: ctx.theme.text, minWidth: 36, textAlign: 'right' }}
        >
          {row.digit}
        </Text>
      )}
      {row.note !== undefined && row.note !== '' && (
        <Text numberOfLines={1} style={{ ...scale.micro, color: ctx.theme.textMuted, maxWidth: 72 }}>
          {row.note}
        </Text>
      )}
    </View>
  )
}

/* ── the card shell + the honest empty state ───────────────────────────────── */

function card(ctx: BlockCtx, key: number, children: ReactNode): ReactNode {
  return (
    <View
      key={key}
      style={{
        borderWidth: 1,
        borderColor: ctx.theme.border,
        borderRadius: 10,
        padding: 12,
        marginVertical: 10,
        backgroundColor: ctx.theme.surface,
      }}
    >
      {children}
    </View>
  )
}

function cardTitle(title: string, ctx: BlockCtx): ReactNode {
  if (title === '') return null
  return <Text style={{ ...scale.sm, fontWeight: '600', color: ctx.theme.text, marginBottom: 8 }}>{title}</Text>
}

function emptyDataviz(kind: string, ctx: BlockCtx, key: number): ReactNode {
  return (
    <Text key={key} style={{ ...scale.sm, fontStyle: 'italic', color: ctx.theme.textMuted, marginVertical: 6 }}>
      {kind} — no data
    </Text>
  )
}

/* ── stat / stats / stat-grid ──────────────────────────────────────────────── */

const SPARK_W = 120
const SPARK_H = 26

/** The sparkline, UN-DROPPED (D56). The web's own 120×26 viewBox, kept at that
 * FIXED size rather than stretched to the card width: the CSS stretch rides
 * `preserveAspectRatio="none"`, a non-uniform mapping that rotated Views cannot
 * express — and guessing a width would need the measurement pass this file is
 * forbidden. Same point math as sparkSvg (dataviz.ts:81). */
function sparkline(values: number[], ctx: BlockCtx): ReactNode {
  if (values.length === 0) return null
  const n = values.length
  const minV = Math.min(...values)
  const maxV = Math.max(...values)
  const span = maxV - minV <= 0 ? 1 : maxV - minV
  const points: Pt[] = values.map((v, i) => ({
    x: n <= 1 ? SPARK_W / 2 : (SPARK_W * i) / (n - 1),
    y: 2 + (SPARK_H - 4) * (1 - (v - minV) / span),
  }))
  return <View style={{ width: SPARK_W, height: SPARK_H, marginTop: 4 }}>{polyline(points, ctx.theme.accent, 'pt')}</View>
}

function statCard(item: Record<string, unknown>, ctx: BlockCtx, key: number): ReactNode {
  const value = str(item.value)
  if (value === '') return null
  const denom = str(item.denom)
  const label = str(item.label)
  // THE BAR'S LAW, canonical in react (blocks/dataviz.ts statHtml) and agreed by
  // Go (stat.go): the track EXISTS whenever `max` is above zero REGARDLESS of
  // value, and the fill is a STRICT numeric parse of value else zero, clamped
  // to 0..1. Three divergences from that law rode this one expression and are
  // fixed TOGETHER, because fixing either alone trades one bug for another:
  //
  //   • THE ZERO-DROP (real, painted). `num()` is undefined for anything at or
  //     below zero, so a stat of `0` dropped the whole track where react paints
  //     an empty one. "0 of 10" is information; a missing bar is not.
  //   • THE LOWER CLAMP (latent). `num()` hid negatives too, so main could not
  //     paint a negative width — by ACCIDENT, not by law. Reading value through
  //     a wider parse (which the zero-drop fix requires) arms that trap
  //     immediately: without the lower clamp, -5 of 10 is `width: '-50%'`.
  //     `clamp(…, 0, 1)` makes the floor structural.
  //   • STRICTNESS (real, painted). A stat `value` is a PRE-FORMATTED DISPLAY
  //     STRING by the pdrender contract, so a lenient `parseFloat` read
  //     `"1.24M"` as 1.24 and painted 62% of a max of 2 where react paints 0%.
  //     `numeric` is this file's strict twin of react's own parse: a string
  //     that is not wholly a number is NOT a quantity.
  //
  // `num()` itself is UNCHANGED and stays the reader for `max` (and for cell
  // spans elsewhere): its above-zero law is right there — a max of zero has no
  // bar to denominate — and rewriting it would move those callers too.
  const max = num(item.max)
  const fill = max === undefined ? undefined : clamp((numeric(value) ?? 0) / max, 0, 1)
  return (
    <View
      key={key}
      style={{
        borderWidth: 1,
        borderColor: ctx.theme.border,
        borderRadius: 8,
        padding: 12,
        marginVertical: 4,
        backgroundColor: ctx.theme.surface,
        gap: 4,
      }}
    >
      {fill !== undefined && (
        <View style={{ height: 4, borderRadius: 2, backgroundColor: ctx.theme.border }}>
          <View
            style={{
              height: 4,
              borderRadius: 2,
              width: `${Math.round(fill * 100)}%`,
              backgroundColor: ctx.theme.accent,
            }}
          />
        </View>
      )}
      <Text style={{ ...roles.statValue, fontWeight: '700', color: ctx.theme.text }}>
        {value}
        {/* NESTED Text: size only. A lineHeight on a nested run fights the
            parent's line box, so nested runs take `<token>.fontSize`. */}
        {denom !== '' && (
          <Text style={{ fontSize: scale.md.fontSize, color: ctx.theme.textMuted }}>/{denom}</Text>
        )}
      </Text>
      {label !== '' && <Text style={{ ...scale.xs, color: ctx.theme.textMuted }}>{label}</Text>}
      {sparkline(numberList(item.spark), ctx)}
    </View>
  )
}

const stat: Render = (b, ctx, key) => statCard(b, ctx, key)

const stats: Render = (b, ctx, key) => {
  const items = asList(b.items).filter(isMap)
  if (items.length === 0) return emptyDataviz('stats', ctx, key)
  return <View key={key} style={{ marginVertical: 6 }}>{items.map((it, i) => statCard(it, ctx, i))}</View>
}

/* ── heatmap: three variants ───────────────────────────────────────────────── */

const GRID_CELL = 16
const GRID_GAP = 4
const CAL_CELL = 12
const CAL_GAP = 3
const VALUE_CELL_W = 40
const ROW_LABEL_W = 56
const LEGEND_CELL = 10
const SUM_W = 28

function normGrid(b: Record<string, unknown>): number[][] {
  return asList(b.cells)
    .map((row) => asList(row).map((v) => numeric(v) ?? 0))
    .filter((row) => row.length > 0)
}

/** data_viz.ex quantile_bins: non-zero values only, q25/q50/q75, and −1 for
 * "no activity" (the calendar's gap cell). */
export function quantileBins(grid: number[][]): number[][] {
  const nz = grid
    .flat()
    .filter((v) => v > 0)
    .sort((a, b) => a - b)
  const n = nz.length
  const q = (p: number): number => (n === 0 ? 0 : nz[clamp(Math.ceil(p * n) - 1, 0, n - 1)]!)
  const q1 = q(0.25)
  const q2 = q(0.5)
  const q3 = q(0.75)
  return grid.map((row) => row.map((v) => (v <= 0 ? -1 : v <= q1 ? 0 : v <= q2 ? 1 : v <= q3 ? 2 : 3)))
}

/** The bin ladder's mix fractions — paper-surface.css b0..b3 at 22/44/66/88%. */
const BIN_MIX = [0.22, 0.44, 0.66, 0.88]

function binColor(bin: number, theme: Theme): string {
  if (bin < 0) return theme.border
  return lerpHex(theme.border, theme.accent, BIN_MIX[clamp(bin, 0, 3)]!)
}

/** The cell's SECOND channel — the CSS `::after` inset square (and the zero
 * cell's dot). Colour alone would fail a colourblind reader, and the dual
 * legend the calendar/matrix variants print promises this glyph exists. */
const BIN_INSET = [0.41, 0.33, 0.24, 0.15]

/** The value cell's underline strip — `.bp-heat__c--v::after`'s 3px bar. */
const VALUE_STRIP = 3

/** `color-mix(in srgb, <hex> N%, transparent)` as an alpha suffix. The glyph
 * MUST composite over the cell fill the way the CSS `::after` does: mixing
 * toward the card surface instead would make it bin-independent and wash it out
 * on the top rungs. */
function alphaHex(hex: string, a: number): string {
  if (!/^#[0-9a-f]{6}$/i.test(hex)) return hex
  return (
    hex +
    Math.round(clamp(a, 0, 1) * 255)
      .toString(16)
      .padStart(2, '0')
  )
}

function heatCell(
  key: number,
  size: number,
  fill: string,
  ctx: BlockCtx,
  glyph: { bin: number } | null,
  value?: string,
): ReactNode {
  const isValue = value !== undefined
  const inner =
    glyph === null
      ? null
      : glyph.bin < 0
        ? { side: DOT, radius: DOT / 2, color: ctx.theme.textMuted }
        : {
            side: Math.max(Math.round(size * (1 - 2 * BIN_INSET[clamp(glyph.bin, 0, 3)]!)), 2),
            radius: 1,
            color: alphaHex(ctx.theme.text, 0.42),
          }
  return (
    <View
      key={key}
      style={{
        width: isValue ? VALUE_CELL_W : size,
        height: size,
        borderRadius: 3,
        // A value cell keeps its ink on the CARD, never on the bin fill: at the
        // top rung `text` over an 88%-accent cell measures 3.3:1 (light) and
        // 3.1:1 (dark) — under AA for 0.7rem mono. The bin colour moves to an
        // underline strip, which is what paper-surface.css .bp-heat__c--v does
        // ("so ink text keeps full contrast on every theme").
        backgroundColor: isValue ? 'transparent' : fill,
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      {inner !== null && !isValue && (
        <View
          style={{ width: inner.side, height: inner.side, borderRadius: inner.radius, backgroundColor: inner.color }}
        />
      )}
      {isValue && <Text style={{ ...scale.micro, fontFamily: MONO, color: ctx.theme.text }}>{value}</Text>}
      {isValue && (
        <View
          style={{
            position: 'absolute',
            left: '15%',
            right: '15%',
            bottom: 0,
            height: VALUE_STRIP,
            borderRadius: VALUE_STRIP / 2,
            backgroundColor: fill,
          }}
        />
      )}
    </View>
  )
}

function rowLabel(label: string, ctx: BlockCtx, key?: number): ReactNode {
  return (
    <Text
      key={key}
      numberOfLines={1}
      style={{
        ...scale.micro,
        fontFamily: MONO,
        color: ctx.theme.textMuted,
        width: ROW_LABEL_W,
        textAlign: 'right',
        paddingRight: 8,
      }}
    >
      {label}
    </Text>
  )
}

function colLabel(label: string, width: number, ctx: BlockCtx, key: number): ReactNode {
  return (
    <Text
      key={key}
      numberOfLines={1}
      style={{ ...scale.micro, fontFamily: MONO, color: ctx.theme.textMuted, width, textAlign: 'center' }}
    >
      {label}
    </Text>
  )
}

function heatLegend(cells: ReactNode[], ctx: BlockCtx): ReactNode {
  const word = { ...scale.micro, fontFamily: MONO, color: ctx.theme.textMuted }
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 4, marginTop: 10 }}>
      <Text style={word}>less</Text>
      {cells}
      <Text style={word}>more</Text>
    </View>
  )
}

/** Continuous grid: intensity = v / max, mixed accent-over-rule up to 88% —
 * data_viz.ex heat_grid_html, including the "divisor is the ACTUAL grid max
 * unless an explicit positive `max` is given" law (flooring it at 1.0 would
 * flatten every intensity). */
function heatGrid(grid: number[][], b: Record<string, unknown>, ctx: BlockCtx, key: number): ReactNode {
  const maxNum = numeric(b.max)
  const flat = grid.flat()
  const maxVal = maxNum !== null && maxNum > 0 ? maxNum : Math.max(flat.length ? Math.max(...flat) : 1, 1e-9)
  const rowLabels = stringList(b.rowLabels)
  const colLabels = stringList(b.colLabels)
  const cols = Math.max(...grid.map((r) => r.length), 0)
  const row = { flexDirection: 'row', alignItems: 'center', gap: GRID_GAP } as const
  return card(
    ctx,
    key,
    <View>
      <View style={{ gap: GRID_GAP }}>
        {colLabels.length > 0 && (
          <View style={row}>
            {rowLabels.length > 0 && rowLabel('', ctx)}
            {Array.from({ length: cols }, (_, j) => colLabel(colLabels[j] ?? '', GRID_CELL, ctx, j))}
          </View>
        )}
        {grid.map((cells, i) => (
          <View key={i} style={row}>
            {rowLabels.length > 0 && rowLabel(rowLabels[i] ?? '', ctx)}
            {Array.from({ length: cols }, (_, j) =>
              heatCell(
                j,
                GRID_CELL,
                lerpHex(ctx.theme.border, ctx.theme.accent, clamp((cells[j] ?? 0) / maxVal, 0, 1) * 0.88),
                ctx,
                null,
              ),
            )}
          </View>
        ))}
      </View>
      {heatLegend(
        [0.15, 0.35, 0.55, 0.75, 1].map((i, k) =>
          heatCell(k, LEGEND_CELL, lerpHex(ctx.theme.border, ctx.theme.accent, i * 0.88), ctx, null),
        ),
        ctx,
      )}
    </View>,
  )
}

function binLegend(ctx: BlockCtx): ReactNode {
  return heatLegend(
    BIN_MIX.map((_, bin) => heatCell(bin, LEGEND_CELL, binColor(bin, ctx.theme), ctx, { bin })),
    ctx,
  )
}

/** Calendar: quantile bins, 12pt cells, horizontally scrollable — the web's
 * `bp-heat__scroll` (a year of weeks never fits a phone). */
function heatCalendar(grid: number[][], b: Record<string, unknown>, ctx: BlockCtx, key: number): ReactNode {
  const bins = quantileBins(grid)
  const rowLabels = stringList(b.rowLabels)
  const colLabels = stringList(b.colLabels)
  const weeks = Math.max(...grid.map((r) => r.length), 0)
  const row = { flexDirection: 'row', alignItems: 'center', gap: CAL_GAP } as const
  return card(
    ctx,
    key,
    <View>
      <ScrollView horizontal showsHorizontalScrollIndicator={false}>
        <View style={{ gap: CAL_GAP }}>
          {colLabels.length > 0 && (
            <View style={row}>
              {rowLabels.length > 0 && rowLabel('', ctx)}
              {Array.from({ length: weeks }, (_, w) => colLabel(colLabels[w] ?? '', CAL_CELL, ctx, w))}
            </View>
          )}
          {grid.map((_, i) => (
            <View key={i} style={row}>
              {rowLabels.length > 0 && rowLabel(rowLabels[i] ?? '', ctx)}
              {Array.from({ length: weeks }, (_, w) => {
                const bin = bins[i]?.[w] ?? -1
                return heatCell(w, CAL_CELL, binColor(bin, ctx.theme), ctx, { bin })
              })}
            </View>
          ))}
        </View>
      </ScrollView>
      {binLegend(ctx)}
    </View>,
  )
}

/** Matrix extras: quantile bins PLUS per-cell values and/or row/col marginals
 * with a grand total — data_viz.ex heat_matrix_extras_html. */
function heatMatrix(grid: number[][], b: Record<string, unknown>, ctx: BlockCtx, key: number): ReactNode {
  const bins = quantileBins(grid)
  const showVals = b.values === true
  const showMarg = b.marginals === true
  const rowLabels = stringList(b.rowLabels)
  const colLabels = stringList(b.colLabels)
  const cols = Math.max(...grid.map((r) => r.length), 0)
  const rowSums = grid.map((row) => row.reduce((a, v) => a + v, 0))
  const colSums = Array.from({ length: cols }, (_, j) => grid.reduce((a, row) => a + (row[j] ?? 0), 0))
  const grand = rowSums.reduce((a, v) => a + v, 0)
  const gutter = rowLabels.length > 0 || showMarg
  const cellW = showVals ? VALUE_CELL_W : GRID_CELL
  const row = { flexDirection: 'row', alignItems: 'center', gap: GRID_GAP } as const
  // `.bp-heat__sum` is dim mono; `--grand` is emphasised (weight 650, full ink)
  // — the grand total is the one sum that reads as a conclusion.
  const sumText = (v: number, k: number, grand = false) => (
    <Text
      key={k}
      style={{
        ...scale.micro,
        fontFamily: MONO,
        color: grand ? ctx.theme.text : ctx.theme.textMuted,
        ...(grand && { fontWeight: '700' as const }),
        minWidth: SUM_W,
        textAlign: 'right',
      }}
    >
      {fmt(v)}
    </Text>
  )
  return card(
    ctx,
    key,
    <View>
      <ScrollView horizontal showsHorizontalScrollIndicator={false}>
        <View style={{ gap: GRID_GAP }}>
          {!(colLabels.length === 0 && !showMarg) && (
            <View style={row}>
              {gutter && rowLabel('', ctx)}
              {Array.from({ length: cols }, (_, j) => colLabel(colLabels[j] ?? '', cellW, ctx, j))}
              {showMarg && colLabel('Σ', SUM_W, ctx, cols)}
            </View>
          )}
          {grid.map((cells, i) => (
            <View key={i} style={row}>
              {gutter && rowLabel(rowLabels[i] ?? '', ctx)}
              {Array.from({ length: cols }, (_, j) => {
                const bin = bins[i]?.[j] ?? -1
                return heatCell(
                  j,
                  GRID_CELL,
                  binColor(bin, ctx.theme),
                  ctx,
                  { bin },
                  showVals ? fmt(cells[j] ?? 0) : undefined,
                )
              })}
              {showMarg && sumText(rowSums[i] ?? 0, cols)}
            </View>
          ))}
          {showMarg && (
            <View style={row}>
              {rowLabel('Σ', ctx)}
              {colSums.map((s, j) => sumText(s, j))}
              {sumText(grand, cols, true)}
            </View>
          )}
        </View>
      </ScrollView>
      {binLegend(ctx)}
    </View>,
  )
}

const heatmap: Render = (b, ctx, key) => {
  const grid = normGrid(b)
  if (grid.length === 0) return emptyDataviz('heatmap', ctx, key)
  if (displayString(b.mode) === 'calendar') return heatCalendar(grid, b, ctx, key)
  if (b.marginals === true || b.values === true) return heatMatrix(grid, b, ctx, key)
  return heatGrid(grid, b, ctx, key)
}

/* ── chart ─────────────────────────────────────────────────────────────────── */

// The web's 640×190 viewBox, minus its padding: the PLOT box is the uniform box
// every mark is a percentage of. Ticks and x labels sit OUTSIDE it in real flex
// boxes at real token sizes — inside the viewBox they would scale with the plot
// and land near 6pt on a phone.
const PLOT_W = 584 // 640 − PAD_L 46 − PAD_R 10
const PLOT_H = 152 // 190 − PAD_T 8 − PAD_B 30
const Y_GUTTER = 44

interface Series {
  label: string
  points: number[]
}

/** dataviz.ts `span`: axes.min/max PIN the span; a reversed pair (min ≥ max) is
 * discarded for the data range; a flat series opens to [min, min+1]. */
export function chartSpan(series: Series[], axes: Record<string, unknown>): [number, number] {
  const data = series.flatMap((s) => s.points)
  const dmin = Math.min(...data)
  const dmax = Math.max(...data)
  const pmin = numeric(axes.min)
  const pmax = numeric(axes.max)
  let minV: number
  let maxV: number
  if (pmin !== null && pmax !== null && pmin >= pmax) {
    minV = dmin
    maxV = dmax
  } else {
    minV = pmin ?? dmin
    maxV = pmax ?? dmax
  }
  return maxV <= minV ? [minV, minV + 1] : [minV, maxV]
}

/** D56's recorded substitute for the web's accent/info/warning/danger map: NO
 * new `info` token this wave, so the ladder is the theme's own four tones.
 * theme.ts ships `success` at the SAME hex as `accent` in BOTH palettes, so
 * taken literally a 2-series chart would paint two identical lines; a repeat
 * falls back to `textMuted` — still a theme-owned tone, no colour invented.
 *
 * KNOWN DEFECT, PINNED AS TODAY'S BEHAVIOUR (charter D74, amending D56). That
 * fallback means SERIES 2 WEARS THE APPARATUS COLOUR: `textMuted` is also the
 * chart's tick and baseline-axis ink, so a two-series chart draws one of its
 * lines in the same grey as the furniture around it. That is a real legibility
 * violation and it PAINTS at n=2 — it is not hypothetical. Closing it needs a
 * FIFTH theme token (the web resolves series 2 to `--bp-tone-info-fg`; mobile
 * has no `info` token and no `derive()` — its theme is literal hex), and
 * choosing hexes against `#1f6f4a`/`#3fa374` by eye is exactly the judgment
 * D74 CUT for want of a visual reviewer. So this function ships the assertable
 * half only — pairwise distinctness and a stable prefix, both mutation-killable
 * — and the colour choice stays visibly parked. Do NOT "fix" this by inventing
 * an info hex: a green that hides the defect is worse than the defect.
 *
 * The n>4 half of the distinctness pin is UNREACHABLE by construction — the
 * chart renderer slices `series` to four before it asks for colours — so it is
 * a defensive pin, and nobody may claim it fixed a rendering bug. */
export function seriesColors(theme: Theme, n: number): string[] {
  const ladder = [theme.accent, theme.success, theme.warn, theme.danger]
  // The dedup spares, in order, all theme-owned: textMuted FIRST so today's
  // n=2 answer is byte-unchanged (see the D74 note above), then the remaining
  // distinct tones, which only a series 5+ could ever reach.
  const spares = [theme.textMuted, theme.text, theme.codeFg, theme.border, theme.bubble]
  const out: string[] = []
  for (let i = 0; i < n; i++) {
    const want = ladder[i % 4]!
    if (!out.includes(want)) {
      out.push(want)
      continue
    }
    // The ladder repeats (or collides with itself, as success/accent do): take
    // the first spare not already on the chart. Exhausting nine distinct tones
    // would need a 10-series chart, which cannot exist — the renderer slices to
    // four — so the last resort repeats textMuted rather than inventing a hex.
    out.push(spares.find((c) => !out.includes(c)) ?? theme.textMuted)
  }
  return out
}

/** Plot-box y for a value: 0 at the top edge, PLOT_H at the axis. Out-of-span
 * values CLAMP to an edge (the Go/web tie-break), never escape the box. */
function yAt(v: number, minV: number, maxV: number): number {
  return PLOT_H * (1 - clamp((v - minV) / (maxV - minV), 0, 1))
}

function xAt(i: number, n: number): number {
  return n <= 1 ? PLOT_W / 2 : (PLOT_W * i) / (n - 1)
}

const chart: Render = (b, ctx, key) => {
  const series: Series[] = asList(b.series)
    .map((s) => ({
      label: displayString(isMap(s) ? s.label : undefined),
      points: numberList(isMap(s) ? s.points : undefined),
    }))
    .filter((s) => s.points.length > 0)
    .slice(0, 4)
  if (series.length === 0) return emptyDataviz('chart', ctx, key)

  const kind = displayString(b.kind) === 'bars' ? 'bars' : 'line'
  const axes = isMap(b.axes) ? b.axes : {}
  let [minV, maxV] = chartSpan(series, axes)
  // Bars measure from a baseline, so an unpinned span floors at 0.
  if (kind === 'bars' && numeric(axes.min) === null) minV = Math.min(0, minV)

  const n = Math.max(...series.map((s) => s.points.length))
  const colors = seriesColors(ctx.theme, series.length)
  const xLabels = stringList(axes.xLabels)
  const tickStyle = { ...scale.micro, fontFamily: MONO, color: ctx.theme.textMuted }

  const marks: ReactNode[] = []
  if (kind === 'bars') {
    const slot = PLOT_W / Math.max(n, 1)
    const barW = Math.max((slot * 0.7) / series.length, 1)
    series.forEach((s, si) => {
      s.points.forEach((v, i) => {
        const y = yAt(v, minV, maxV)
        marks.push(
          <View
            key={`b${si}-${i}`}
            style={{
              position: 'absolute',
              left: pct((slot * i + slot * 0.15 + barW * si) / PLOT_W),
              width: pct(barW / PLOT_W),
              top: pct(y / PLOT_H),
              height: pct(Math.max(PLOT_H - y, 0) / PLOT_H),
              backgroundColor: colors[si]!,
              opacity: 0.85,
            }}
          />,
        )
      })
    })
  } else {
    series.forEach((s, si) => {
      marks.push(
        <View key={`l${si}`} style={{ position: 'absolute', left: 0, right: 0, top: 0, bottom: 0 }}>
          {polyline(
            s.points.map((v, i) => ({ x: xAt(i, n), y: yAt(v, minV, maxV) })),
            colors[si]!,
            { w: PLOT_W, h: PLOT_H },
          )}
        </View>,
      )
    })
  }

  // Four gridlines at exactly k/3 of the plot height — the web's k=0..3 ladder
  // resolves to those fractions, which is why the ticks need no measurement.
  const lines = [0, 1, 2, 3].map((k) => ({ frac: k / 3, value: minV + ((maxV - minV) * (3 - k)) / 3 }))

  return card(
    ctx,
    key,
    <View>
      {cardTitle(displayString(b.caption), ctx)}
      <View style={{ flexDirection: 'row' }}>
        <View style={{ width: Y_GUTTER }}>
          {lines.map((l, k) => (
            <Text
              key={k}
              numberOfLines={1}
              style={{
                ...tickStyle,
                position: 'absolute',
                right: 6,
                top: pct(l.frac),
                marginTop: -scale.micro.lineHeight / 2,
                textAlign: 'right',
              }}
            >
              {tickCompact(l.value)}
            </Text>
          ))}
        </View>
        <View style={{ flex: 1, aspectRatio: PLOT_W / PLOT_H }}>
          {lines.map((l, k) => (
            <View
              key={k}
              style={{
                position: 'absolute',
                left: 0,
                right: 0,
                top: pct(l.frac),
                height: 1,
                backgroundColor: ctx.theme.border,
              }}
            />
          ))}
          {marks}
          <View
            style={{
              position: 'absolute',
              left: 0,
              right: 0,
              bottom: 0,
              height: 1,
              backgroundColor: ctx.theme.textMuted,
            }}
          />
        </View>
      </View>
      {xLabels.length > 0 && (
        <View style={{ flexDirection: 'row', justifyContent: 'space-between', marginLeft: Y_GUTTER, marginTop: 4 }}>
          <Text style={tickStyle}>{xLabels[0] ?? ''}</Text>
          {xLabels.length > 1 && <Text style={tickStyle}>{xLabels[xLabels.length - 1] ?? ''}</Text>}
        </View>
      )}
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 12, marginTop: 8 }}>
        {series.map((s, si) => (
          <View key={si} style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
            <View style={{ width: 14, height: 3, borderRadius: 2, backgroundColor: colors[si]! }} />
            <Text style={tickStyle}>{s.label === '' ? `series ${si + 1}` : s.label}</Text>
          </View>
        ))}
      </View>
    </View>,
  )
}

/* ── gauge-list ────────────────────────────────────────────────────────────── */

/** data_viz.ex gauge_mode: an explicit `mode` wins; else `rows` without
 * `snapshot` is a hand-authored share list; else count. */
function gaugeMode(b: Record<string, unknown>): 'share' | 'count' {
  const m = displayString(b.mode).toLowerCase()
  if (m === 'count') return 'count'
  if (m === 'share') return 'share'
  if ('rows' in b && !('snapshot' in b)) return 'share'
  return 'count'
}

/** A task row's bucket: priority reads as P<n>; anything empty is "(none)". */
function gaugeBucketKey(row: Record<string, unknown>, groupBy: string): string {
  if (groupBy === 'priority') {
    const p = displayString(row.priority)
    return p === '' ? '(none)' : `P${p}`
  }
  const k = displayString(row[groupBy])
  return k === '' ? '(none)' : k
}

/** share: each row against `max` or the SUM. count: frequencies of a snapshot
 * grouped by a field, against the MAX count, desc then label-asc. The unbacked
 * `groupBy: 'epic'` returns the sentinel its note is printed for. */
export function gaugeRows(b: Record<string, unknown>): 'epic' | BarRow[] {
  if (gaugeMode(b) === 'share') {
    const items = asList(b.rows).filter(isMap)
    if (items.length === 0) return []
    const sum = items.reduce((a, it) => a + (numeric(it.value) ?? 0), 0)
    const max = numeric(b.max)
    let denom = max !== null && max > 0 ? max : sum
    if (denom <= 0) denom = 1
    return items.map((it) => {
      const prop = clamp((numeric(it.value) ?? 0) / denom, 0, 1)
      return {
        label: displayString(it.label),
        prop,
        digit: `${Math.round(prop * 100)}%`,
        note: displayString(it.note),
      }
    })
  }
  const raw = displayString(b.groupBy)
  const groupBy = raw === '' ? 'status' : raw
  if (groupBy === 'epic') return 'epic'
  const rows = asList(b.snapshot).filter(isMap)
  if (rows.length === 0) return []
  const counts = new Map<string, number>()
  for (const r of rows) {
    const k = gaugeBucketKey(r, groupBy)
    counts.set(k, (counts.get(k) ?? 0) + 1)
  }
  const maxCount = Math.max(1, ...counts.values())
  return [...counts.entries()]
    .sort((a, c) => (a[1] !== c[1] ? c[1] - a[1] : a[0] < c[0] ? -1 : a[0] > c[0] ? 1 : 0))
    .map(([label, count]) => ({ label, prop: count / maxCount, digit: String(count) }))
}

const gaugeList: Render = (b, ctx, key) => {
  const title = displayString(b.title)
  const rows = gaugeRows(b)
  if (rows === 'epic') {
    return card(
      ctx,
      key,
      <View>
        {cardTitle(title, ctx)}
        <Text style={{ ...scale.xs, color: ctx.theme.textMuted }}>
          groupBy &quot;epic&quot; is unbacked here — needs the epic resolver
        </Text>
      </View>,
    )
  }
  if (rows.length === 0) return emptyDataviz('gauge-list', ctx, key)
  return card(
    ctx,
    key,
    <View>
      {cardTitle(title, ctx)}
      {rows.map((r, i) => barRow(r, ctx, i))}
    </View>,
  )
}

/* ── bar-chart ─────────────────────────────────────────────────────────────── */

// Same proportional-row vocabulary as gauge-list's share mode, but denominated
// by the DATA MAX — bars are categorical counts, not shares — unless an
// explicit positive `max` is given. The digit only shows on `values: true`.
const barChart: Render = (b, ctx, key) => {
  const bars = asList(b.bars).filter(isMap)
  if (bars.length === 0) return emptyDataviz('bar-chart', ctx, key)
  const values = bars.map((bar) => numeric(bar.value) ?? 0)
  const explicitMax = numeric(b.max)
  let denom = explicitMax !== null && explicitMax > 0 ? explicitMax : Math.max(...values)
  if (denom <= 0) denom = 1
  const showValues = b.values === true
  return card(
    ctx,
    key,
    <View>
      {bars.map((bar, i) => {
        const value = values[i] ?? 0
        return barRow(
          {
            label: displayString(bar.label),
            prop: clamp(value / denom, 0, 1),
            digit: showValues ? fmt(value) : '',
          },
          ctx,
          i,
        )
      })}
    </View>,
  )
}

/* ── criteria-progress ─────────────────────────────────────────────────────── */

// Renders from its OWN attrs — no task-resolver query at render time. The
// denominator is each row's own `total` (a fraction, not a shared max) and the
// met/total digit ALWAYS shows: it is the datum. `detail: 'total'` collapses
// every row into one summed "Total" bar.
const criteriaProgress: Render = (b, ctx, key) => {
  const rows = asList(b.rows).filter(isMap)
  if (rows.length === 0) return emptyDataviz('criteria-progress', ctx, key)
  let effective: Record<string, unknown>[] = rows
  if (b.detail === 'total') {
    let met = 0
    let total = 0
    for (const row of rows) {
      met += numeric(row.met) ?? 0
      total += numeric(row.total) ?? 0
    }
    effective = [{ label: 'Total', met, total }]
  }
  return card(
    ctx,
    key,
    <View>
      {effective.map((row, i) => {
        const met = numeric(row.met) ?? 0
        const total = numeric(row.total) ?? 0
        return barRow(
          {
            label: displayString(row.label),
            prop: total > 0 ? clamp(met / total, 0, 1) : 0,
            digit: `${fmt(met)}/${fmt(total)}`,
          },
          ctx,
          i,
        )
      })}
    </View>,
  )
}

export const datavizRenderers: Record<string, Render> = {
  stat,
  stats,
  'stat-grid': stats,
  chart,
  heatmap,
  'gauge-list': gaugeList,
  'bar-chart': barChart,
  'criteria-progress': criteriaProgress,
}
