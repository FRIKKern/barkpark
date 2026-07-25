// Tasks tab — live GET /v1/tasks/prime?view=brief through @barkpark/core
// (charter D14: the SDK's RN maiden voyage, expoFetch injected via
// config.fetch). Read-only; fence-free triage lands later in wave 2. Honest
// states: loading, error-with-retry, empty, and the two prime sections
// (in progress / ready) with pull-to-refresh.
//
// Live refresh rides the SDK's listen() SSE stream (/v1/data/listen/:dataset,
// types=task) — the D14 expoFetch streaming seam doing its load-bearing job
// on device: the welcome frame is logged as the connect proof, and every task
// mutation event triggers a silent re-prime.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  ActivityIndicator,
  Pressable,
  RefreshControl,
  SectionList,
  StyleSheet,
  Text,
  View,
} from 'react-native'

import { fetchPrimeBrief, makeInstanceClient, type BriefTaskCard, type InstanceConnection, type PrimeBrief } from '../api/instance'
import { useTheme, type Theme } from '../ui/theme'

type TasksState =
  | { phase: 'loading' }
  | { phase: 'error'; message: string }
  | { phase: 'ready'; prime: PrimeBrief; refreshing: boolean }

export function TasksScreen({ connection }: { connection: InstanceConnection }) {
  const theme = useTheme()
  const [state, setState] = useState<TasksState>({ phase: 'loading' })
  const [attempt, setAttempt] = useState(0)
  const client = useMemo(() => makeInstanceClient(connection), [connection])

  // The fetch lives in the effect; every setState happens AFTER an await so
  // renders never cascade synchronously. `attempt` is the re-run trigger the
  // retry/refresh handlers bump.
  useEffect(() => {
    let alive = true
    ;(async () => {
      try {
        const prime = await fetchPrimeBrief(client)
        if (alive) setState({ phase: 'ready', prime, refreshing: false })
      } catch {
        if (alive) setState({ phase: 'error', message: 'Could not load tasks from your Barkpark.' })
      }
    })()
    return () => {
      alive = false
    }
  }, [client, attempt])

  // Live refresh: hold ONE listen() stream while the tab is mounted. The
  // welcome frame proves the streaming connect (the skeleton's criterion-3
  // gap — expoFetch's streaming response.body working on device); mutation
  // events for type:task re-prime silently (no spinner — the board just
  // updates). Mutations are debounced a beat so a burst of task events costs
  // one re-fetch.
  const refetchTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  useEffect(() => {
    const handle = client.listen('task')
    let alive = true
    ;(async () => {
      try {
        for await (const ev of handle) {
          if (!alive) break
          if (ev.type === 'welcome') {
            console.log('[barkpark-mobile] listen welcome frame:', JSON.stringify(ev))
          } else if (ev.type === 'mutation') {
            if (refetchTimer.current !== undefined) clearTimeout(refetchTimer.current)
            refetchTimer.current = setTimeout(() => {
              if (alive) setAttempt((a) => a + 1)
            }, 400)
          }
        }
      } catch (err) {
        // Honest degrade: the board still works on pull-to-refresh.
        if (alive) console.log('[barkpark-mobile] listen stream ended:', String(err))
      }
    })()
    return () => {
      alive = false
      if (refetchTimer.current !== undefined) clearTimeout(refetchTimer.current)
      handle.unsubscribe()
    }
  }, [client])

  const retry = useCallback(() => {
    setState({ phase: 'loading' })
    setAttempt((a) => a + 1)
  }, [])

  const refresh = useCallback(() => {
    setState((prev) => (prev.phase === 'ready' ? { ...prev, refreshing: true } : { phase: 'loading' }))
    setAttempt((a) => a + 1)
  }, [])

  if (state.phase === 'loading') {
    return (
      <View style={[styles.center, { backgroundColor: theme.bg }]}>
        <ActivityIndicator color={theme.accent} />
        <Text style={[styles.muted, { color: theme.textMuted }]}>Loading tasks…</Text>
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

  const { prime } = state
  const sections = [
    { title: 'In progress', data: prime.inProgress },
    { title: 'Ready', data: prime.ready },
  ].filter((s) => s.data.length > 0)

  if (sections.length === 0) {
    return (
      <View style={[styles.center, { backgroundColor: theme.bg }]}>
        <Text style={[styles.body, { color: theme.text }]}>No open work right now.</Text>
        <Text style={[styles.muted, { color: theme.textMuted }]}>Tasks claimed or ready to claim show up here.</Text>
        <Pressable accessibilityRole="button" onPress={retry}>
          <Text style={[styles.link, { color: theme.accent }]}>Refresh</Text>
        </Pressable>
      </View>
    )
  }

  return (
    <SectionList
      style={{ backgroundColor: theme.bg }}
      contentContainerStyle={styles.listContent}
      sections={sections}
      keyExtractor={(card) => card.doc_id}
      refreshControl={
        <RefreshControl
          refreshing={state.refreshing}
          onRefresh={refresh}
          tintColor={theme.accent}
        />
      }
      renderSectionHeader={({ section }) => (
        <Text style={[styles.sectionHeader, { color: theme.textMuted }]}>{section.title}</Text>
      )}
      renderItem={({ item }) => <TaskRow card={item} theme={theme} />}
    />
  )
}

function TaskRow({ card, theme }: { card: BriefTaskCard; theme: Theme }) {
  const nowText = card.claim?.now?.text
  const criteria =
    card.criteria_total !== undefined ? `${card.criteria_met ?? 0}/${card.criteria_total}` : undefined
  return (
    <View style={[styles.row, { backgroundColor: theme.surface, borderColor: theme.border }]}>
      <View style={styles.rowTop}>
        {card.priority !== undefined && (
          <Text style={[styles.priority, { color: theme.accent, borderColor: theme.accent }]}>P{card.priority}</Text>
        )}
        <Text numberOfLines={2} style={[styles.title, { color: theme.text }]}>
          {card.title}
        </Text>
      </View>
      <View style={styles.rowMeta}>
        {criteria !== undefined && (
          <Text style={[styles.metaText, { color: theme.textMuted }]}>{criteria} criteria</Text>
        )}
        {card.claim?.worker !== undefined && (
          <Text numberOfLines={1} style={[styles.metaText, { color: theme.textMuted }]}>
            {card.claim.worker}
          </Text>
        )}
      </View>
      {nowText !== undefined && nowText !== '' && (
        <Text numberOfLines={2} style={[styles.nowLine, { color: theme.textMuted }]}>
          {nowText}
        </Text>
      )}
    </View>
  )
}

const styles = StyleSheet.create({
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 10, padding: 24 },
  listContent: { padding: 16, gap: 10 },
  sectionHeader: {
    fontSize: 12,
    fontWeight: '700',
    textTransform: 'uppercase',
    letterSpacing: 1,
    marginTop: 10,
    marginBottom: 6,
  },
  row: { borderWidth: 1, borderRadius: 12, padding: 12, gap: 6, marginBottom: 8 },
  rowTop: { flexDirection: 'row', alignItems: 'flex-start', gap: 8 },
  priority: {
    fontSize: 11,
    fontWeight: '700',
    borderWidth: 1,
    borderRadius: 5,
    paddingHorizontal: 5,
    paddingVertical: 1,
    overflow: 'hidden',
  },
  title: { flex: 1, fontSize: 15, fontWeight: '600', lineHeight: 20 },
  rowMeta: { flexDirection: 'row', gap: 12 },
  metaText: { fontSize: 12 },
  nowLine: { fontSize: 13, fontStyle: 'italic', lineHeight: 18 },
  body: { fontSize: 15, textAlign: 'center' },
  muted: { fontSize: 13, textAlign: 'center' },
  link: { fontSize: 14, textDecorationLine: 'underline' },
})
