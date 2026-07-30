// table family (charter D49): table — head/header alias + rows; cells are
// inline arrays or scalars.
//
// Known latent defect, recorded by D46b: the per-cell minWidth/maxWidth means
// rows lay out independently, so columns can misalign. The sheet renderer
// (round 2) must NOT copy this shape; the fix here rides its own backlog row.
import { ScrollView, Text, View } from 'react-native'

import { scale } from '../../../ui/typography'
import { renderInlineNodes } from '../inlines'
import { asList, isMap } from '../model'
import type { Render } from '../register'

const table: Render = (b, ctx, key) => {
  const headRaw = b.head ?? b.header
  let head = Array.isArray(headRaw) ? headRaw : []
  let rows = asList(b.rows)
  const columns = tableColumns(b.columns)
  if (head.length === 0 && columns.length > 0) {
    head = columns.map(({ key, label }) => label || key)
    rows = rows.map((row) =>
      isMap(row) ? columns.map(({ key }) => row[key] ?? '') : row,
    )
  } else if (
    head.length === 0 &&
    rows.length > 0 &&
    isMap(rows[0]) &&
    (rows[0].header === true || allHeaderCells(rowCells(rows[0])))
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
  const content = isMap(cell) && Array.isArray(cell.content) ? cell.content : [cell]
  return content.flatMap((node) =>
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

export const tableRenderers: Record<string, Render> = {
  table,
}
