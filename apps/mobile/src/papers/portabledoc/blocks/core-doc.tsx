// core-doc family — the document-apparatus band of react's core family
// (charter D49): note, notes, cards. Round-2 structure natives (status-legend,
// card, pipeline, stage, task-detail, roadmap — mob-zb-s3) land here without
// touching registry.tsx.
import type { ReactNode } from 'react'
import { Text, View } from 'react-native'

import { scale } from '../../../ui/typography'
import { asList, isMap, str } from '../model'
import type { BlockCtx, Render } from '../register'

/* note / notes (label + lead + text) */

function noteRow(item: unknown, ctx: BlockCtx, key: number): ReactNode {
  const m = isMap(item) ? item : {}
  const label = str(m.label)
  const lead = str(m.lead).trim()
  const text = str(m.text)
  return (
    <View key={key} style={{ flexDirection: 'row', gap: 10, marginVertical: 4 }}>
      {label !== '' && (
        <Text
          style={{
            ...scale.xs,
            fontWeight: '700',
            color: ctx.theme.accent,
            minWidth: 44,
            marginTop: 2,
          }}
        >
          {label}
        </Text>
      )}
      <Text style={{ flex: 1, ...scale.base, color: ctx.theme.text }}>
        {lead !== '' && <Text style={{ fontWeight: '700' }}>{lead + ' '}</Text>}
        {text}
      </Text>
    </View>
  )
}

const note: Render = (b, ctx, key) => noteRow(b, ctx, key)

const notes: Render = (b, ctx, key) => {
  const items = asList(b.items)
  if (items.length === 0) return null
  return <View key={key} style={{ marginVertical: 6 }}>{items.map((it, i) => noteRow(it, ctx, i))}</View>
}

/* cards (items title/text/tone) */

const cards: Render = (b, ctx, key) => {
  const items = asList(b.items)
  if (items.length === 0) return null
  return (
    <View key={key} style={{ marginVertical: 6, gap: 8 }}>
      {items.map((it, i) => {
        const m = isMap(it) ? it : {}
        const title = str(m.title)
        const text = str(m.text)
        return (
          <View
            key={i}
            style={{
              borderWidth: 1,
              borderColor: ctx.theme.border,
              borderRadius: 8,
              padding: 12,
              backgroundColor: ctx.theme.surface,
              gap: 4,
            }}
          >
            {title !== '' && <Text style={{ ...scale.base, fontWeight: '700', color: ctx.theme.text }}>{title}</Text>}
            {text !== '' && <Text style={{ ...scale.sm, color: ctx.theme.textMuted }}>{text}</Text>}
          </View>
        )
      })}
    </View>
  )
}

export const coreDocRenderers: Record<string, Render> = {
  note,
  notes,
  cards,
}
