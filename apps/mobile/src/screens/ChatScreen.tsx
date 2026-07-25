// Chat tab — the sessions list, live on the minted token (charter D10: chat
// is workspace-scoped BY DESIGN — the workspace's sessions ARE the floor).
// Rows carry the herd truth (agent_state pill + stall badge) and sort by the
// ported attention order (herd.ts: blocked > stalled > working > idle >
// unknown). Selecting a row opens the full session floor. Honest states:
// loading, error-with-retry, empty, ready with pull-to-refresh — the same
// idiom as the Tasks tab.
import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  ActivityIndicator,
  FlatList,
  Pressable,
  RefreshControl,
  StyleSheet,
  Text,
  View,
} from 'react-native'

import type { InstanceConnection } from '../api/instance'
import { listChatSessions } from '../api/chat'
import { emptyHerd, herdOrder, herdRowFor, herdSeed, herdStalled } from '../chat/herd'
import type { ChatSessionSummary } from '../chat/wire'
import { ChatSessionScreen } from './ChatSessionScreen'
import { useTheme, type Theme } from '../ui/theme'

type ListState =
  | { phase: 'loading' }
  | { phase: 'error'; message: string }
  | {
      phase: 'ready'
      sessions: ChatSessionSummary[]
      refreshing: boolean
      /** the fetch's wall-clock — the deterministic "now" the stall badge and
       * attention sort are computed against (pure per render). */
      loadedAtMs: number
    }

export function ChatScreen({ connection }: { connection: InstanceConnection }) {
  const theme = useTheme()
  const [state, setState] = useState<ListState>({ phase: 'loading' })
  const [attempt, setAttempt] = useState(0)
  const [openSession, setOpenSession] = useState<{ id: string; title?: string } | undefined>(
    undefined,
  )

  useEffect(() => {
    let alive = true
    ;(async () => {
      try {
        const sessions = await listChatSessions(connection)
        if (alive)
          setState({ phase: 'ready', sessions, refreshing: false, loadedAtMs: Date.now() })
      } catch {
        if (alive)
          setState({ phase: 'error', message: 'Could not load chat sessions from your Barkpark.' })
      }
    })()
    return () => {
      alive = false
    }
  }, [connection, attempt])

  const retry = useCallback(() => {
    setState({ phase: 'loading' })
    setAttempt((a) => a + 1)
  }, [])

  const refresh = useCallback(() => {
    setState((prev) =>
      prev.phase === 'ready' ? { ...prev, refreshing: true } : { phase: 'loading' },
    )
    setAttempt((a) => a + 1)
  }, [])

  // The ported herd attention sort: seed rows from the cold list, order by
  // rank / freshest flip / id (deterministic — no jitter under refresh).
  const ordered = useMemo(() => {
    if (state.phase !== 'ready') return []
    const herd = herdSeed(emptyHerd(), state.sessions)
    const byId = new Map(state.sessions.map((s) => [s.id, s]))
    const now = state.loadedAtMs
    return herdOrder(
      herd,
      state.sessions.map((s) => s.id),
      now,
    ).map((id) => ({
      session: byId.get(id) as ChatSessionSummary,
      row: herdRowFor(herd, id),
      stalled: herdStalled(herdRowFor(herd, id), now),
    }))
  }, [state])

  if (openSession !== undefined) {
    return (
      <ChatSessionScreen
        connection={connection}
        sessionId={openSession.id}
        sessionTitle={openSession.title}
        onBack={() => {
          setOpenSession(undefined)
          refresh()
        }}
      />
    )
  }

  if (state.phase === 'loading') {
    return (
      <View style={[styles.center, { backgroundColor: theme.bg }]}>
        <ActivityIndicator color={theme.accent} />
        <Text style={[styles.muted, { color: theme.textMuted }]}>Loading sessions…</Text>
      </View>
    )
  }

  if (state.phase === 'error') {
    return (
      <View style={[styles.center, { backgroundColor: theme.bg }]}>
        <Text style={[styles.body, { color: theme.danger }]}>{state.message}</Text>
        <Pressable accessibilityRole="button" onPress={retry}>
          <Text style={[styles.link, { color: theme.accent }]}>Try again</Text>
        </Pressable>
      </View>
    )
  }

  if (ordered.length === 0) {
    return (
      <View style={[styles.center, { backgroundColor: theme.bg }]}>
        <Text style={[styles.body, { color: theme.text }]}>No chat sessions yet.</Text>
        <Text style={[styles.muted, { color: theme.textMuted }]}>
          Sessions on this workspace show up here.
        </Text>
        <Pressable accessibilityRole="button" onPress={retry}>
          <Text style={[styles.link, { color: theme.accent }]}>Refresh</Text>
        </Pressable>
      </View>
    )
  }

  return (
    <FlatList
      style={{ backgroundColor: theme.bg }}
      contentContainerStyle={styles.listContent}
      data={ordered}
      keyExtractor={(item) => item.session.id}
      refreshControl={
        <RefreshControl
          refreshing={state.refreshing}
          onRefresh={refresh}
          tintColor={theme.accent}
        />
      }
      renderItem={({ item }) => (
        <SessionRow
          session={item.session}
          stalled={item.stalled}
          nowMs={state.loadedAtMs}
          theme={theme}
          onPress={() => setOpenSession({ id: item.session.id, title: item.session.title })}
        />
      )}
    />
  )
}

function stateColors(theme: Theme, agentState: string): { fg: string; label: string } {
  switch (agentState) {
    case 'blocked':
      return { fg: theme.danger, label: 'needs you' }
    case 'working':
      return { fg: theme.success, label: 'working' }
    case 'idle':
      return { fg: theme.textMuted, label: 'idle' }
    default:
      return { fg: theme.textMuted, label: 'unknown' }
  }
}

function SessionRow({
  session,
  stalled,
  nowMs,
  theme,
  onPress,
}: {
  session: ChatSessionSummary
  stalled: boolean
  nowMs: number
  theme: Theme
  onPress: () => void
}) {
  const pill = stateColors(theme, session.agent_state ?? '')
  const pending = session.pending_approvals ?? 0
  return (
    <Pressable accessibilityRole="button" onPress={onPress} style={styles.row}>
      <View style={styles.rowTop}>
        <Text numberOfLines={2} style={[styles.title, { color: theme.text }]}>
          {session.title !== undefined && session.title !== '' ? session.title : session.id}
        </Text>
        {pending > 0 && (
          <View style={[styles.pendingBadge, { backgroundColor: theme.danger }]}>
            <Text style={styles.pendingText}>{pending}</Text>
          </View>
        )}
      </View>
      <View style={styles.rowMeta}>
        <Text style={[styles.stateLabel, { color: pill.fg }]}>{pill.label}</Text>
        {stalled && <Text style={[styles.stateLabel, { color: theme.danger }]}>stalled</Text>}
        {session.message_count !== undefined && session.message_count > 0 && (
          <Text style={[styles.metaText, { color: theme.textMuted }]}>
            {session.message_count} messages
          </Text>
        )}
        {session.last_active_at !== undefined && (
          <Text style={[styles.metaText, { color: theme.textMuted }]}>
            {relativeTime(session.last_active_at, nowMs)}
          </Text>
        )}
      </View>
      {session.summary !== undefined && session.summary !== '' && (
        <Text numberOfLines={2} style={[styles.summary, { color: theme.textMuted }]}>
          {session.summary}
        </Text>
      )}
    </Pressable>
  )
}

/** Honest coarse age — '' when the timestamp does not parse. */
export function relativeTime(iso: string, nowMs: number): string {
  const t = Date.parse(iso)
  if (Number.isNaN(t)) return ''
  const s = Math.max(0, Math.floor((nowMs - t) / 1000))
  if (s < 60) return 'just now'
  if (s < 3600) return `${Math.floor(s / 60)}m ago`
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`
  return `${Math.floor(s / 86400)}d ago`
}

const styles = StyleSheet.create({
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 10, padding: 24 },
  // paddingTop clears the status bar — this tab draws edge-to-edge with no
  // header slab of its own.
  listContent: { paddingHorizontal: 20, paddingTop: 58, paddingBottom: 12 },
  // Borderless rows on the background — whitespace separates sessions, the
  // way the ChatGPT/Claude session lists do it.
  row: { paddingVertical: 14, gap: 5 },
  rowTop: { flexDirection: 'row', alignItems: 'flex-start', gap: 8 },
  title: { flex: 1, fontSize: 16, fontWeight: '600', lineHeight: 22 },
  pendingBadge: {
    minWidth: 20,
    height: 20,
    borderRadius: 10,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 5,
  },
  pendingText: { color: '#ffffff', fontSize: 11, fontWeight: '700' },
  rowMeta: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  stateLabel: { fontSize: 12, fontWeight: '600' },
  metaText: { fontSize: 12 },
  summary: { fontSize: 14, lineHeight: 20 },
  body: { fontSize: 15, textAlign: 'center' },
  muted: { fontSize: 13, textAlign: 'center' },
  link: { fontSize: 14, textDecorationLine: 'underline' },
})
