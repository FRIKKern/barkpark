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
  const headRaw = b.head ?? b.header
  let head = Array.isArray(headRaw) ? headRaw : []
  let body = asList(b.rows)
  const columns = tableColumns(b.columns)
  if (head.length === 0 && columns.length > 0) {
    head = columns.map(({ key, label }) => label || key)
    body = body.map((row) =>
      isMap(row) ? columns.map(({ key }) => row[key] ?? '') : row,
    )
  } else if (
    head.length === 0 &&
    body.length > 0 &&
    isMap(body[0]) &&
    (body[0].header === true || allHeaderCells(rowCells(body[0])))
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
  if (!isMap(cell) || !Array.isArray(cell.content)) return cell
  return cell.content.flatMap((node) =>
    isMap(node) && node.type === 'paragraph' && Array.isArray(node.content)
      ? node.content
      : [node],
  )
}

function tableColumns(value: unknown): Array<{ key: string; label: string }> {
  if (!Array.isArray(value)) return []
  const columns = value.map((column) => {
    if (!isMap(column) || typeof column.key !== 'string' || column.key === '') return null
    return {
      key: column.key,
      label: typeof column.label === 'string' ? column.label : '',
    }
  })
  return columns.every((column) => column !== null)
    ? (columns as Array<{ key: string; label: string }>)
    : []
}

function allHeaderCells(cells: unknown[]): boolean {
  return cells.length > 0 && cells.every((cell) => isMap(cell) && cell.header === true)
}

export const tableEmitters: Record<string, Emit> = { table }
