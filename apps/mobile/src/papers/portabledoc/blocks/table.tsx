// table family (charter D49): table — head/header alias + rows; cells are
// inline arrays or scalars.
//
// Known latent defect, recorded by D46b: the per-cell minWidth/maxWidth means
// rows lay out independently, so columns can misalign. The sheet renderer
// (round 2) must NOT copy this shape; the fix here rides its own backlog row.
import { ScrollView, Text, View } from 'react-native'

import { scale } from '../../../ui/typography'
import { renderInlineNodes } from '../inlines'
import { asList } from '../model'
import type { Render } from '../register'

const table: Render = (b, ctx, key) => {
  const headRaw = b.head ?? b.header
  const head = Array.isArray(headRaw) ? headRaw : []
  const rows = asList(b.rows)
  const cellMin = 96
  return (
    <ScrollView key={key} horizontal style={{ marginVertical: 10 }}>
      <View style={{ borderWidth: 1, borderColor: ctx.theme.border, borderRadius: 6 }}>
        {head.length > 0 && (
          <View style={{ flexDirection: 'row', backgroundColor: ctx.theme.surface }}>
            {head.map((cell, i) => (
              <View key={i} style={{ minWidth: cellMin, maxWidth: 220, padding: 8 }}>
                <Text style={{ ...scale.sm, fontWeight: '700', color: ctx.theme.text }}>
                  {renderInlineNodes(Array.isArray(cell) ? cell : [cell], ctx)}
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
            {asList(row).map((cell, ci) => (
              <View key={ci} style={{ minWidth: cellMin, maxWidth: 220, padding: 8 }}>
                <Text style={{ ...scale.sm, color: ctx.theme.text }}>
                  {renderInlineNodes(Array.isArray(cell) ? cell : [cell], ctx)}
                </Text>
              </View>
            ))}
          </View>
        ))}
      </View>
    </ScrollView>
  )
}

export const tableRenderers: Record<string, Render> = {
  table,
}
