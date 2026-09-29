// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// `table` block emitter — the JS twin of walk.ex table/3 at style=:article.
// Bare `bp-table` chrome: an opt-in `<thead>` band (`bp-table__th`) plus body
// cells (`bp-table__td`); cells render their inline content through the shared
// inline renderer.
//
// TYPED COLUMNS (opt-in, CONTENT ONLY) — the third leg of the `cols` contract
// already rendered by internal/pdrender/richblocks.go (TUI) and compose.ex +
// walk.ex (Elixir :article). An optional `cols` attr, an index-aligned array of
// {type} maps, tags each column text | num | delta | spark: num/delta get a
// right-align CLASS (`--num`), delta replaces the body with a sign GLYPH plus
// the magnitude, spark replaces it with the ONE sparkline primitive. `cols`
// ABSENT (or an unknown/out-of-range type) ⇒ every column is text ⇒ the emitted
// bytes are identical to a table carrying no spec. Head cells keep the legacy
// body in every column type and inherit alignment only — same as both twins.
// The type set and the delta glyphs are recorded once, for all three engines, in
// api/test/support/fixtures/table-col-types.json; tests/table-typed-cols.test.ts
// reads that file rather than re-typing it.

import { type Block, asList, isMap, renderCell } from '../inline'
import { sparkSvg } from './dataviz'

type Emit = (block: Block) => string

// num and delta share the right-align modifier; spark takes its own.
const COL_MOD: Record<string, string> = { num: '--num', delta: '--num', spark: '--spark' }
// [down, flat, up], indexed by Math.sign(n) + 1.
const DELTA_GLYPHS = ['\u25bc', '-', '\u25b2']

const table: Emit = (b) => {
  const types = asList(b.cols).map((c) => (isMap(c) ? String(c.type ?? '') : ''))
  const cls = (base: string, i: number) => {
    const m = COL_MOD[types[i] ?? '']
    return m ? `${base} ${base}${m}` : base
  }
  // head is opt-in (`head`, or the legacy `header` alias).
  let head = asList(b.head ?? b.header)
  let body = asList(b.rows)
  const columns = asList(b.columns)
  if (!head.length && columns.length && columns.every(isMap)) {
    const maps = columns as Array<Record<string, unknown>>
    const keys = maps.map((column) => (typeof column.key === 'string' ? column.key : ''))
    head = maps.map((column, index) => column.text ?? column.label ?? keys[index])
    if (keys.every(Boolean)) {
      body = body.map((row) =>
        isMap(row) ? keys.map((key) => row[key] ?? '') : row,
      )
    }
  } else if (
    !head.length &&
    body.length &&
    isMap(body[0]) &&
    (body[0].header || allHeaderCells(rowCells(body[0])))
  ) {
    head = rowCells(body[0])
    body = body.slice(1)
  }

  const thead =
    head.length === 0
      ? ''
      : `<thead><tr>${head
          .map(
            (cell, i) =>
              `<th class="${cls('bp-table__th', i)}">${renderCell(cellContent(cell))}</th>`,
          )
          .join('')}</tr></thead>`

  const tbody = body
    .map((row) => {
      const cells = rowCells(row)
        .map(
          (cell, i) =>
            `<td class="${cls('bp-table__td', i)}">${typedCell(cell, types[i] ?? '')}</td>`,
        )
        .join('')
      return `<tr>${cells}</tr>`
    })
    .join('')

  return `<table role="presentation" class="bp-table">${thead}<tbody>${tbody}</tbody></table>`
}

// One body cell rendered per its column type. num shares the text BODY (only
// its alignment differs), so a num column stays content-identical to legacy
// text; delta and spark transform the body, and each falls back to the legacy
// body when the cell does not carry the value its type needs.
function typedCell(cell: unknown, type: string): string {
  if (type === 'delta') {
    const n = cellNum(cell)
    // Glyph FIRST, then the magnitude — the direction survives with zero colour.
    if (n !== null) return renderCell(`${DELTA_GLYPHS[Math.sign(n) + 1]} ${Math.abs(n)}`)
  } else if (type === 'spark' && Array.isArray(cell)) {
    const vals = cell.map(cellNum).filter((n): n is number => n !== null)
    if (vals.length) return sparkSvg(vals, 'bp-table__spark')
  }
  return renderCell(cellContent(cell))
}

// Only a SCALAR cell coerces to a number (mirrors compose.ex table_cell_number/1
// and Go's toFloat, both of which see the raw cell); a {content:…} / node-array
// cell is prose and stays prose. A string must parse WHOLE — a partial parse is
// not a number.
function cellNum(cell: unknown): number | null {
  if (typeof cell === 'number') return Number.isFinite(cell) ? cell : null
  if (typeof cell !== 'string') return null
  const t = cell.trim()
  const n = Number(t)
  return t !== '' && Number.isFinite(n) ? n : null
}

function rowCells(row: unknown): unknown[] {
  return isMap(row) && Array.isArray(row.cells) ? row.cells : asList(row)
}

function cellContent(cell: unknown): unknown {
  if (!isMap(cell)) return cell
  if (typeof cell.text === 'string') return cell.text
  if (!Array.isArray(cell.content)) return cell
  return cell.content.flatMap((node) =>
    isMap(node) && Array.isArray(node.content) ? node.content : [node],
  )
}

function allHeaderCells(cells: unknown[]): boolean {
  return cells.every((cell) => isMap(cell) && !!cell.header)
}

export const tableEmitters: Record<string, Emit> = { table }
