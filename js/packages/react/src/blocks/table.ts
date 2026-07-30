// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// `table` block emitter — the JS twin of walk.ex table/3 at style=:article.
// Bare `bp-table` chrome: an opt-in `<thead>` band (`bp-table__th`) plus body
// cells (`bp-table__td`); cells render their inline content through the shared
// inline renderer.

import { type Block, asList, isMap, renderCell } from '../inline'

type Emit = (block: Block) => string

const table: Emit = (b) => {
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
          .map((cell) => `<th class="bp-table__th">${renderCell(cellContent(cell))}</th>`)
          .join('')}</tr></thead>`

  const tbody = body
    .map((row) => {
      const cells = rowCells(row)
        .map((cell) => `<td class="bp-table__td">${renderCell(cellContent(cell))}</td>`)
        .join('')
      return `<tr>${cells}</tr>`
    })
    .join('')

  return `<table role="presentation" class="bp-table">${thead}<tbody>${tbody}</tbody></table>`
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
