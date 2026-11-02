// table family (charter D49): table — head/header alias + rows; cells are
// inline arrays or scalars.
//
// Known latent defect, recorded by D46b: the per-cell minWidth/maxWidth means
// rows lay out independently, so columns can misalign. The sheet renderer
// (round 2) must NOT copy this shape; the fix here rides its own backlog row.
import { ScrollView, Text, View } from 'react-native'

import { scale } from '../../../ui/typography'
import { chromeWord } from '../chrome'
import { renderInlineNodes } from '../inlines'
import { asList, isMap } from '../model'
import type { Render } from '../register'
import { sheetState } from './sheet'

const TABLE_CELL_CAP = 10000

function recordCells(b: Record<string, unknown>): number {
  const columns = asList(b.columns)
  const record =
    columns.length > 0 &&
    columns.every(isMap) &&
    !columns.every((column) => typeof column.text === 'string') &&
    columns.every((column) => typeof column.key === 'string' && column.key !== '')
  return record ? asList(b.rows).length * columns.length : 0
}

const table: Render = (b, ctx, key) => {
  if (recordCells(b) > TABLE_CELL_CAP) return sheetState(chromeWord(ctx.locale, 'Table too large to show'), ctx, key)
  let head = asList(b.head ?? b.header)
  let rows = asList(b.rows)
  const columns = asList(b.columns)
  if (!head.length && columns.length && columns.every(isMap)) {
    const maps = columns as Array<Record<string, unknown>>
    const keys = maps.map((column) => (typeof column.key === 'string' ? column.key : ''))
    head = maps.map((column, index) => column.text ?? column.label ?? keys[index])
    if (keys.every(Boolean)) {
      rows = rows.map((row) =>
        isMap(row) ? keys.map((key) => row[key] ?? '') : row,
      )
    }
  } else if (
    !head.length &&
    rows.length &&
    isMap(rows[0]) &&
    (rows[0].header || allHeaderCells(rowCells(rows[0])))
  ) {
    head = rowCells(rows[0])
    rows = rows.slice(1)
  }
  const cellMin = 96
  return (
    <ScrollView key={key} horizontal style={{ marginVertical: 10 }}>
      <View style={{ borderWidth: 1, borderColor: ctx.theme.border, borderRadius: 6 }}>
        {head.length > 0 && (
          <View style={{ flexDirection: 'row', backgroundColor: ctx.theme.surface }}>
            {head.map((cell, i) => (
              <View key={i} style={{ minWidth: cellMin, maxWidth: 220, padding: 8 }}>
                <Text style={{ ...scale.sm, fontWeight: '700', color: ctx.theme.text }}>
                  {renderInlineNodes(asInlineCell(cell), ctx)}
                </Text>
              </View>
            ))}
          </View>
        )}
        {rows.map((row, ri) => (
          <View
            key={ri}
            style={{ flexDirection: 'row', borderTopWidth: 1, borderTopColor: ctx.theme.border }}
          >
            {rowCells(row).map((cell, ci) => (
              <View key={ci} style={{ minWidth: cellMin, maxWidth: 220, padding: 8 }}>
                <Text style={{ ...scale.sm, color: ctx.theme.text }}>
                  {renderInlineNodes(asInlineCell(cell), ctx)}
                </Text>
              </View>
            ))}
          </View>
        ))}
      </View>
    </ScrollView>
  )
}

function rowCells(row: unknown): unknown[] {
  return isMap(row) && Array.isArray(row.cells) ? row.cells : asList(row)
}

function asInlineCell(cell: unknown): unknown[] {
  if (isMap(cell) && typeof cell.text === 'string') return [cell.text]
  const content = Array.isArray(cell) ? cell : isMap(cell) && Array.isArray(cell.content) ? cell.content : [cell]
  return content.flatMap((node) =>
    isMap(node) && Array.isArray(node.content) ? node.content : [node],
  )
}

function allHeaderCells(cells: unknown[]): boolean {
  return cells.every((cell) => isMap(cell) && !!cell.header)
}

export const tableRenderers: Record<string, Render> = {
  table,
}
