// taskboard family (charter D49): tasks / task-list — snapshot rows
// (Components.tasks_html twin). The capstone's task-list is QUERY-driven with
// no snapshot: that renders the same honest "No tasks yet." empty state the
// reference emits. Round-2 grid natives (task-board — mob-zb-s6, D46c) land
// here without touching registry.tsx.
import { Text, View } from 'react-native'

import { scale } from '../../../ui/typography'
import { asList, isMap, str } from '../model'
import type { Render } from '../register'

const TASK_GLYPH: Record<string, string> = {
  open: '○',
  ready: '○',
  in_progress: '◐',
  blocked: '!',
  done: '✓',
  closed: '✓',
  cancelled: '✕',
  considering: '◌',
  researching: '◎',
}

const taskList: Render = (b, ctx, key) => {
  const rows = asList(b.snapshot).filter(isMap)
  if (rows.length === 0) {
    return (
      <Text key={key} style={{ ...scale.sm, fontStyle: 'italic', color: ctx.theme.textMuted, marginVertical: 8 }}>
        No tasks yet.
      </Text>
    )
  }
  const title = str(b.title).trim()
  return (
    <View
      key={key}
      style={{
        borderWidth: 1,
        borderColor: ctx.theme.border,
        borderRadius: 8,
        padding: 10,
        marginVertical: 8,
        backgroundColor: ctx.theme.surface,
      }}
    >
      {title !== '' && (
        <Text style={{ ...scale.base, fontWeight: '700', color: ctx.theme.text, marginBottom: 6 }}>{title}</Text>
      )}
      {rows.map((r, i) => {
        const status = str(r.status)
        const glyph = TASK_GLYPH[status] ?? (status === '' ? '○' : '◦')
        const done = status === 'done' || status === 'closed'
        return (
          <View key={i} style={{ flexDirection: 'row', gap: 8, marginVertical: 2 }}>
            <Text style={{ ...scale.base, color: done ? ctx.theme.success : ctx.theme.textMuted }}>{glyph}</Text>
            <Text style={{ flex: 1, ...scale.base, color: ctx.theme.text }}>{str(r.title)}</Text>
          </View>
        )
      })}
    </View>
  )
}

export const taskboardRenderers: Record<string, Render> = {
  tasks: taskList,
  'task-list': taskList,
}
