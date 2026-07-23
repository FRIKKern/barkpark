// Hand-rolled bottom tab bar — three tabs (Tasks · Chat · Papers, ratified
// R3). Deliberately dependency-free (no react-navigation) to keep the
// Metro/pnpm surface minimal in the skeleton; the needs-you badge slot is
// wired now so the wave-2 rollup only has to feed it a number.
import { Pressable, StyleSheet, Text, View } from 'react-native'

import { useTheme } from './theme'

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
  /** needs-you counts per tab (wave 2 feeds this from /v1/chat/rollup). */
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
  label: { fontSize: 14 },
  badge: {
    marginLeft: 4,
    minWidth: 18,
    height: 18,
    borderRadius: 9,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 4,
  },
  badgeText: { color: '#ffffff', fontSize: 11, fontWeight: '700' },
})
