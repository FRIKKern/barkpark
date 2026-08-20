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
//
// A badge is a COUNT PLUS ITS STANDING (`TabBadge`), never a bare number: a
// count the app has stopped being able to confirm paints as a muted,
// outlined chip and says so to a screen reader, instead of wearing the same
// alarm-red as one that just landed. The shell owns the judgement (it owns the
// feed); this component owns the two paints.
import { Pressable, StyleSheet, Text, View } from 'react-native'

import { useTheme } from './theme'
import { scale } from './typography'

export type TabKey = 'tasks' | 'chat' | 'papers'

export const TABS: readonly { key: TabKey; label: string }[] = [
  { key: 'tasks', label: 'Tasks' },
  { key: 'chat', label: 'Chat' },
  { key: 'papers', label: 'Papers' },
]

/** One tab's needs-you badge: the number, and whether the shell can still
 * vouch for it. `confirmed: false` is not "zero" and not "error" — it is the
 * last-known count, painted as last-known. */
export interface TabBadge {
  count: number
  /** Defaults to true: a feed that says nothing about freshness is treated as
   * confirmed, which is only safe because the one fed badge always says. */
  confirmed?: boolean
}

/** The badge's screen-reader line — pure, so the unconfirmed wording is pinned
 * by a test rather than by a screenshot. */
export function badgeLabel(tabLabel: string, count: number, confirmed: boolean): string {
  return confirmed
    ? `${tabLabel}: ${count} needs you`
    : `${tabLabel}: ${count} needs you, last known count — not confirmed since the app lost contact`
}

export function TabBar({
  active,
  onSelect,
  badges,
}: {
  active: TabKey
  onSelect: (tab: TabKey) => void
  /** needs-you badges per tab, assembled by the app shell. Only `chat` is fed
   * today (blocked sessions from /v1/chat/rollup); see the file header. */
  badges?: Partial<Record<TabKey, TabBadge>>
}) {
  const theme = useTheme()
  return (
    <View style={[styles.bar, { backgroundColor: theme.surface, borderTopColor: theme.border }]}>
      {TABS.map((tab) => {
        const isActive = tab.key === active
        const badge = badges?.[tab.key]
        const count = badge?.count ?? 0
        const confirmed = badge?.confirmed !== false
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
            {count > 0 && (
              <View
                accessibilityLabel={badgeLabel(tab.label, count, confirmed)}
                style={[
                  styles.badge,
                  confirmed
                    ? { backgroundColor: theme.danger }
                    : // Unconfirmed: the soft/outlined warning chip the papers
                      // list and the reader already use for cached content, so
                      // "this is last-known" reads the same everywhere.
                      { backgroundColor: theme.warnSoft, borderColor: theme.warn, borderWidth: 1 },
                ]}
              >
                <Text style={[styles.badgeText, { color: confirmed ? '#ffffff' : theme.textMuted }]}>
                  {count > 99 ? '99+' : String(count)}
                </Text>
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
  badgeText: { ...scale.micro, fontWeight: '700' },
})
