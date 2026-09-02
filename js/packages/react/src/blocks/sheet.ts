// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// `sheet` embed emitter — a FRESH table renderer written from walk.ex sheet/3
// (charter D14). It does NOT reuse the web fork's interactive SheetSnapshot grid
// (row-number gutters, checkbox glyphs — a categorically different DOM); it
// renders the dense all-string snapshot into the plain `bp-table` / `bp-sheet__th`
// / `bp-sheet__td` shape the Elixir article walker emits: per-column widths,
// colspan/rowspan merges, per-cell b/i/bg/al styles, engine-error red/bold, the
// default-alignment class, URL-cell anchors, and the truncation note.

import { type Block, escapeHtml, safeUrl, isMap } from '../inline'

type Emit = (block: Block) => string

const MERGE_AREA_CAP = 10_000

// Engine error vocabulary (Sheets.Engine.error_values) — a cell whose entire
// value is one of these renders red + bold.
//
// This is a MIRROR of `Barkpark.Plugins.Sheets.Engine.error_values/0`
// (@canonical capability:engine-error-vocabulary). Until now it was the one
// unchecked mirror: nothing compared it to the engine, so a code added
// engine-side would render as plain text here while every other surface marked
// it red. `tests/sheet-error-vocabulary.test.ts` now locks it to the SAME
// engine-generated fixture the web mirror consumes
// (`web/__tests__/fixtures/engine-errors.json`, asserted equal to
// `Engine.error_values/0` by api/test/barkpark/sheets_parity_test.exs), so
// neither side can drift alone. Exported for that test only — it is not part
// of the package's public entry points.
export const ERROR_VALUES = new Set(['#CYCLE!', '#REF!', '#VALUE!', '#DIV/0!', '#N/A', '#NUM!', '#SPILL!'])

// A cell whose ENTIRE value is an http(s) URL renders as an anchor.
const SHEET_URL_RE = /^https?:\/\/[^\s<>"']+$/i
// Right-align: General-number / grouped / currency / percent / fixed shapes.
const NUMERIC_RE = /^-?\$?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?(?:[eE][+-]?\d+)?%?$/
// Right-align: ISO date / datetime display strings.
const TEMPORAL_RE = /^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}:\d{2})?$/
// A strict #rrggbb may reach the inline background (Sheets.CondFormat.valid_bg?).
const BG_RE = /^#[0-9a-fA-F]{6}$/

function toStr(v: unknown): string {
  return typeof v === 'string' ? v : typeof v === 'number' ? String(v) : ''
}

function colWidthStyle(colWidths: unknown, idx: number): string {
  if (!Array.isArray(colWidths)) return ''
  const w = colWidths[idx]
  return typeof w === 'number' && Number.isInteger(w) && w > 0 ? `width:${w}px;` : ''
}

interface MergeLookup {
  anchors: Map<string, [number, number]>
  covered: Set<string>
}

function mergeLookup(merges: unknown): MergeLookup {
  const anchors = new Map<string, [number, number]>()
  const covered = new Set<string>()
  if (!Array.isArray(merges)) return { anchors, covered }
  for (const m of merges) {
    if (!Array.isArray(m) || m.length !== 4) continue
    const [r, c, rs, cs] = m
    if (
      Number.isInteger(r) &&
      Number.isInteger(c) &&
      Number.isInteger(rs) &&
      Number.isInteger(cs) &&
      r >= 0 &&
      c >= 0 &&
      rs >= 1 &&
      cs >= 1 &&
      rs * cs <= MERGE_AREA_CAP
    ) {
      for (let rr = r; rr < r + rs; rr++) {
        for (let cc = c; cc < c + cs; cc++) {
          if (rr === r && cc === c) continue
          covered.add(`${rr},${cc}`)
        }
      }
      anchors.set(`${r},${c}`, [rs, cs])
    }
  }
  return { anchors, covered }
}

function spanAttr(anchors: Map<string, [number, number]>, r: number, c: number): string {
  const hit = anchors.get(`${r},${c}`)
  if (!hit) return ''
  const [rs, cs] = hit
  return (cs > 1 ? ` colspan="${cs}"` : '') + (rs > 1 ? ` rowspan="${rs}"` : '')
}

function cellStyleFragment(styles: unknown, r: number, c: number): string {
  if (!isMap(styles)) return ''
  const s = styles[`${r},${c}`]
  if (!isMap(s)) return ''
  const parts = [
    s.b === true ? 'font-weight:bold;' : '',
    s.i === true ? 'font-style:italic;' : '',
    typeof s.bg === 'string' && BG_RE.test(s.bg) ? `background:${s.bg};` : '',
    s.al === 'left' || s.al === 'center' || s.al === 'right' ? `text-align:${s.al};` : '',
  ].join('')
  return parts === '' ? '' : ';' + parts
}

function errStyle(cell: string): string {
  return ERROR_VALUES.has(cell) ? ';color:#dc2626;font-weight:bold' : ''
}

function explicitAl(styles: unknown, r: number, c: number): boolean {
  if (!isMap(styles)) return false
  const s = styles[`${r},${c}`]
  return isMap(s) && (s.al === 'left' || s.al === 'center' || s.al === 'right')
}

function defaultAlignClass(cell: string): string | null {
  if (cell === 'TRUE' || cell === 'FALSE') return 'sheet-al-center'
  if (NUMERIC_RE.test(cell) || TEMPORAL_RE.test(cell)) return 'sheet-al-right'
  return null
}

// Collapse the `;;` seam + trim the cosmetic leading `;` (sheet_inline_style/1).
function inlineStyle(raw: string): string {
  const style = raw.replace(/;;/g, ';').replace(/^;+/, '')
  return style === '' ? '' : ` style="${style}"`
}

function cellHtml(cell: string): string {
  if (SHEET_URL_RE.test(cell)) {
    return `<a href="${safeUrl(cell)}" class="bp-sheet-link" target="_blank" rel="noopener noreferrer nofollow">${escapeHtml(cell)}</a>`
  }
  return escapeHtml(cell)
}

const sheet: Emit = (b) => {
  const snap = isMap(b.snapshot) ? b.snapshot : {}
  const head = Array.isArray(snap.head) ? snap.head.map(toStr) : []
  const body = Array.isArray(snap.rows)
    ? snap.rows.map((row) => (Array.isArray(row) ? row.map(toStr) : []))
    : []
  const colWidths = snap.col_widths
  const styles = snap.styles
  const { anchors, covered } = mergeLookup(snap.merges)

  const thead =
    head.length === 0
      ? ''
      : `<thead><tr>${head
          .map((cell, idx) => `<th class="bp-sheet__th"${inlineStyle(colWidthStyle(colWidths, idx))}>${escapeHtml(cell)}</th>`)
          .join('')}</tr></thead>`

  const tbody = body
    .map((row, r) => {
      const cells = row
        .map((cell, c) => {
          if (covered.has(`${r},${c}`)) return ''
          const wStyle = colWidthStyle(colWidths, c)
          const span = spanAttr(anchors, r, c)
          const extra = cellStyleFragment(styles, r, c)
          const err = errStyle(cell)
          const alignClass = explicitAl(styles, r, c) ? null : defaultAlignClass(cell)
          const tdClass = ['bp-sheet__td', alignClass].filter(Boolean).join(' ')
          return `<td${span} class="${tdClass}"${inlineStyle(wStyle + extra + err)}>${cellHtml(cell)}</td>`
        })
        .join('')
      return `<tr>${cells}</tr>`
    })
    .join('')

  const table = `<table role="presentation" class="bp-table">${thead}<tbody>${tbody}</tbody></table>`

  const note =
    snap.truncated === true
      ? `<p class="bp-sheet-note">${escapeHtml(`Sheet truncated — showing the first ${body.length} rows`)}</p>`
      : ''

  return table + note
}

export const sheetEmitters: Record<string, Emit> = { sheet }
