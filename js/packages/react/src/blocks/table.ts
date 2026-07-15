// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// `table` block emitter — the JS twin of walk.ex table/3 at style=:article.
// Bare `bp-table` chrome: an opt-in `<thead>` band (`bp-table__th`) plus body
// cells (`bp-table__td`); cells render their inline content through the shared
// inline renderer.

import { type Block, asList, renderInlines } from '../inline'

type Emit = (block: Block) => string

const table: Emit = (b) => {
  // head is opt-in (`head`, or the legacy `header` alias).
  const headRaw = b.head ?? b.header
  const head = Array.isArray(headRaw) ? headRaw : []
  const body = asList(b.rows)

  const thead =
    head.length === 0
      ? ''
      : `<thead><tr>${head
          .map((cell) => `<th class="bp-table__th">${renderInlines(cell)}</th>`)
          .join('')}</tr></thead>`

  const tbody = body
    .map((row) => {
      const cells = asList(row)
        .map((cell) => `<td class="bp-table__td">${renderInlines(cell)}</td>`)
        .join('')
      return `<tr>${cells}</tr>`
    })
    .join('')

  return `<table role="presentation" class="bp-table">${thead}<tbody>${tbody}</tbody></table>`
}

export const tableEmitters: Record<string, Emit> = { table }
