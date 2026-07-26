// Tasks tab — live GET /v1/tasks/prime?view=brief through @barkpark/core
// (charter D14: the SDK's RN maiden voyage, expoFetch injected via
// config.fetch). Honest states: loading, error-with-retry, empty, and the two
// prime sections (in progress / ready) with pull-to-refresh.
//
// Tapping a row opens TaskDetailScreen — the full dossier plus FENCE-FREE
// triage (claim · pulse · criterion stamp · release, all via /v1/tasks, all
// refusing anything the claim-epoch law says is not ours to take). This
// screen owns that one-level stack itself, the same way ChatScreen owns the
// session stack; the app shell stays a three-tab switch.
//
// Live refresh rides the SDK's listen() SSE stream (/v1/data/listen/:dataset,
// types=task) — the D14 expoFetch streaming seam doing its load-bearing job
// on device: the welcome frame is logged as the connect proof, and every task
// mutation event triggers a silent re-prime. That includes OUR OWN triage
// writes: a stamp or pulse emits task.criterion / task.pulse, so the list
// behind the detail screen is already fresh when you navigate back.
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
import { TaskDetailScreen } from './TaskDetailScreen'
import { useTheme, type Theme } from '../ui/theme'
import { scale } from '../ui/typography'

type TasksState =
  | { phase: 'loading' }
  | { phase: 'error'; message: string }
  | { phase: 'ready'; prime: PrimeBrief; refreshing: boolean }

/** The stale-board affordance's one truth, pure so it is jest-provable: the
 * banner shows ONLY when a painted board (ready) has lost its live stream —
 * loading/error screens carry their own honesty already. */
export function staleBoardNotice(
  phase: TasksState['phase'],
  streamDown: boolean,
): string | undefined {
  return phase === 'ready' && streamDown
    ? 'Live updates paused — the board may be stale. Tap to refresh.'
    : undefined
}

export function TasksScreen({ connection }: { connection: InstanceConnection }) {
  const theme = useTheme()
  const [state, setState] = useState<TasksState>({ phase: 'loading' })
  const [streamDown, setStreamDown] = useState(false)
  const [attempt, setAttempt] = useState(0)
  const [openTask, setOpenTask] = useState<{ docId: string; title?: string } | undefined>(undefined)
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
    // maxReconnects: 'unbounded' (charter D23): a board that sits open all day
    // must survive sleep/wake cycles and server restarts — the SDK retries
    // transient failures forever (jittered, 16s-capped) instead of dying after
    // five. Only a terminal failure (signed out, revoked token, repeated
    // refusals) ends the stream, and that flips the stale-board banner below.
    const handle = client.listen('task', undefined, { maxReconnects: 'unbounded' })
    let alive = true
    // No eager reset here: after a connection change the board genuinely IS
    // possibly stale until the new stream's welcome frame proves it live —
    // the reset below is the honest one.
    ;(async () => {
      try {
        for await (const ev of handle) {
          if (!alive) break
          if (ev.type === 'welcome') {
            setStreamDown(false) // the connect proof — the board is live again
          } else if (ev.type === 'mutation') {
            if (refetchTimer.current !== undefined) clearTimeout(refetchTimer.current)
            refetchTimer.current = setTimeout(() => {
              if (alive) setAttempt((a) => a + 1)
            }, 400)
          }
        }
        // The iterator ending without an unmount means the stream is gone.
        if (alive) setStreamDown(true)
      } catch {
        // Honest degrade: live updates are dead — SAY so (the stale-board
        // banner) instead of a console.log nobody sees; pull-to-refresh works.
        if (alive) setStreamDown(true)
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

  // Detail is a one-level stack over the list: back always returns here, and
  // opening a parent/child REPLACES the open task rather than growing a stack
  // this screen would then have to unwind honestly.
  if (openTask !== undefined) {
    return (
      <TaskDetailScreen
        connection={connection}
        docId={openTask.docId}
        {...(openTask.title !== undefined ? { fallbackTitle: openTask.title } : {})}
        onBack={() => setOpenTask(undefined)}
        onOpenTask={(docId, title) =>
          setOpenTask(title !== undefined ? { docId, title } : { docId })
        }
      />
    )
  }

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

  const notice = staleBoardNotice(state.phase, streamDown)

  return (
    <View style={[styles.listRoot, { backgroundColor: theme.bg }]}>
      {notice !== undefined && (
        <Pressable
          accessibilityRole="button"
          onPress={refresh}
          style={[styles.staleBanner, { borderColor: theme.border, backgroundColor: theme.surface }]}
        >
          <Text style={[styles.staleText, { color: theme.textMuted }]}>{notice}</Text>
        </Pressable>
      )}
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
        renderItem={({ item }) => (
          <TaskRow
            card={item}
            theme={theme}
            onOpen={() => setOpenTask({ docId: item.doc_id, title: item.title })}
          />
        )}
      />
    </View>
  )
}

function TaskRow({
  card,
  theme,
  onOpen,
}: {
  card: BriefTaskCard
  theme: Theme
  onOpen: () => void
}) {
  const nowText = card.claim?.now?.text
  const criteria =
    card.criteria_total !== undefined ? `${card.criteria_met ?? 0}/${card.criteria_total}` : undefined
  return (
    <Pressable
      accessibilityRole="button"
      onPress={onOpen}
      style={[styles.row, { backgroundColor: theme.surface, borderColor: theme.border }]}
    >
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
    </Pressable>
  )
}

const styles = StyleSheet.create({
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 10, padding: 24 },
  listRoot: { flex: 1 },
  staleBanner: {
    borderWidth: 1,
    borderRadius: 10,
    marginHorizontal: 16,
    marginTop: 10,
    paddingHorizontal: 12,
    paddingVertical: 8,
  },
  staleText: { ...scale.xs, textAlign: 'center' },
  listContent: { padding: 16, gap: 10 },
  sectionHeader: {
    ...scale.xs,
    fontWeight: '700',
    textTransform: 'uppercase',
    letterSpacing: 1,
    marginTop: 10,
    marginBottom: 6,
  },
  row: { borderWidth: 1, borderRadius: 12, padding: 12, gap: 6, marginBottom: 8 },
  rowTop: { flexDirection: 'row', alignItems: 'flex-start', gap: 8 },
  priority: {
    ...scale.micro,
    fontWeight: '700',
    borderWidth: 1,
    borderRadius: 5,
    paddingHorizontal: 5,
    paddingVertical: 1,
    overflow: 'hidden',
  },
  title: { flex: 1, ...scale.md, fontWeight: '600' },
  rowMeta: { flexDirection: 'row', gap: 12 },
  metaText: { ...scale.xs },
  nowLine: { ...scale.sm, fontStyle: 'italic' },
  body: { ...scale.md, textAlign: 'center' },
  muted: { ...scale.sm, textAlign: 'center' },
  link: { ...scale.base, textDecorationLine: 'underline' },
})
