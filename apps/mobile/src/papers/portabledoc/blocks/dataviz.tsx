// dataviz family (charter D49): stat, stats, stat-grid — the dataviz.ts twins
// (value/denom/label/max bar; sparklines are omitted honestly: no SVG
// dependency in v1). Round-2 dataviz natives (chart, heatmap, gauge-list,
// bar-chart, criteria-progress — mob-zb-s5, D56) land here without touching
// registry.tsx.
import type { ReactNode } from 'react'
import { Text, View } from 'react-native'

import { roles, scale } from '../../../ui/typography'
import { asList, isMap, num, str } from '../model'
import type { BlockCtx, Render } from '../register'

function statCard(item: Record<string, unknown>, ctx: BlockCtx, key: number): ReactNode {
  const value = str(item.value)
  if (value === '') return null
  const denom = str(item.denom)
  const label = str(item.label)
  const max = num(item.max)
  const nv = num(value)
  const pct = max !== undefined && max > 0 && nv !== undefined ? Math.min(nv / max, 1) : undefined
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
      {pct !== undefined && (
        <View style={{ height: 4, borderRadius: 2, backgroundColor: ctx.theme.border }}>
          <View
            style={{
              height: 4,
              borderRadius: 2,
              width: `${Math.round(pct * 100)}%`,
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
      {label !== '' && (
        <Text style={{ ...scale.xs, color: ctx.theme.textMuted }}>{label}</Text>
      )}
    </View>
  )
}

const stat: Render = (b, ctx, key) => statCard(b, ctx, key)

const stats: Render = (b, ctx, key) => {
  const items = asList(b.items).filter(isMap)
  if (items.length === 0) return emptyDataviz('stats', ctx, key)
  return <View key={key} style={{ marginVertical: 6 }}>{items.map((it, i) => statCard(it, ctx, i))}</View>
}

function emptyDataviz(kind: string, ctx: BlockCtx, key: number): ReactNode {
  return (
    <Text key={key} style={{ ...scale.sm, fontStyle: 'italic', color: ctx.theme.textMuted, marginVertical: 6 }}>
      {kind} — no data
    </Text>
  )
}

export const datavizRenderers: Record<string, Render> = {
  stat,
  stats,
  'stat-grid': stats,
}
