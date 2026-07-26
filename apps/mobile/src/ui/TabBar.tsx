// Hand-rolled bottom tab bar — three tabs (Tasks · Chat · Papers, ratified
// R3). Deliberately dependency-free (no react-navigation) to keep the
// Metro/pnpm surface minimal.
//
// BADGES, HONESTLY: this component renders whatever number the app shell
// hands it, per tab. Today the shell feeds exactly ONE — `chat`, from
// `counts.blocked` on GET /v1/chat/rollup (useChatRollup, 60s poll). The
// `tasks` and `papers` slots render the moment a number arrives and are fed by
// nothing: there is no tasks needs-you source wired. `/v1/tasks/prime` is the
// obvious candidate (its `counts` already ride every Tasks-tab load), but the
// map is assembled in the app shell, not here — so wiring it is a shell
// change, not a TabBar one. Until then this comment is the whole truth.
import { Pressable, StyleSheet, Text, View } from 'react-native'

import { useTheme } from './theme'
import { scale } from './typography'

export type TabKey = 'tasks' | 'chat' | 'papers'

export const TABS: readonly { key: TabKey; label: string }[] = [
  { key: 'tasks', label: 'Tasks' },
  { key: 'chat', label: 'Chat' },
  { key: 'papers', label: 'Papers' },
]

export function TabBar({
  active,
  onSelect,
  badges,
}: {
  active: TabKey
  onSelect: (tab: TabKey) => void
  /** needs-you counts per tab, assembled by the app shell. Only `chat` is fed
   * today (blocked sessions from /v1/chat/rollup); see the file header. */
  badges?: Partial<Record<TabKey, number>>
}) {
  const theme = useTheme()
  return (
    <View style={[styles.bar, { backgroundColor: theme.surface, borderTopColor: theme.border }]}>
      {TABS.map((tab) => {
        const isActive = tab.key === active
        const badge = badges?.[tab.key] ?? 0
        return (
          <Pressable
            key={tab.key}
            accessibilityRole="tab"
            accessibilityState={{ selected: isActive }}
            onPress={() => onSelect(tab.key)}
            style={styles.tab}
          >
            <Text
              style={[
                styles.label,
                { color: isActive ? theme.accent : theme.textMuted, fontWeight: isActive ? '700' : '500' },
              ]}
            >
              {tab.label}
            </Text>
            {badge > 0 && (
              <View style={[styles.badge, { backgroundColor: theme.danger }]}>
                <Text style={styles.badgeText}>{badge > 99 ? '99+' : String(badge)}</Text>
              </View>
            )}
          </Pressable>
        )
      })}
    </View>
  )
}

const styles = StyleSheet.create({
  bar: { flexDirection: 'row', borderTopWidth: 1, paddingBottom: 24, paddingTop: 10 },
  tab: { flex: 1, alignItems: 'center', gap: 2, flexDirection: 'row', justifyContent: 'center' },
  label: { ...scale.base },
  badge: {
    marginLeft: 4,
    minWidth: 18,
    height: 18,
    borderRadius: 9,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 4,
  },
  badgeText: { ...scale.micro, color: '#ffffff', fontWeight: '700' },
})
