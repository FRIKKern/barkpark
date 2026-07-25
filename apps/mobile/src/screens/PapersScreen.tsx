// Papers tab — the list screen, live on the minted token via
// GET /v1/data/query/:dataset/paper (fields-projected light; newest-updated
// first). PAGED (review F3): the live corpus is 537 papers and growing — the
// list loads 100 at a time and fetches the next page as the scroll nears the
// end, until the server's total is reached. Selecting a row opens the native
// reader. Honest states: loading, error-with-retry, empty, ready with
// pull-to-refresh (refresh restarts from page one), and a footer spinner
// while a page is in flight. Read-only against production by construction.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  ActivityIndicator,
  FlatList,
  Pressable,
  RefreshControl,
  StyleSheet,
  Text,
  View,
} from 'react-native'

import { makeInstanceClient, type InstanceConnection } from '../api/instance'
import { fetchPaperPage, type PaperListItem } from '../api/papers'
import { relativeTime } from './ChatScreen'
import { PaperReaderScreen } from './PaperReaderScreen'
import { useTheme, type Theme } from '../ui/theme'

type ListState =
  | { phase: 'loading' }
  | { phase: 'error'; message: string }
  | {
      phase: 'ready'
      papers: PaperListItem[]
      /** the server's total match count — papers.length < total means more pages */
      total: number
      refreshing: boolean
      loadingMore: boolean
      loadedAtMs: number
    }

export function PapersScreen({ connection }: { connection: InstanceConnection }) {
  const theme = useTheme()
  const [state, setState] = useState<ListState>({ phase: 'loading' })
  const [attempt, setAttempt] = useState(0)
  const [openPaper, setOpenPaper] = useState<{ id: string; title?: string } | undefined>(undefined)
  const client = useMemo(() => makeInstanceClient(connection), [connection])
  // One page-fetch in flight at a time; onEndReached can fire in bursts.
  const pageInFlight = useRef(false)

  useEffect(() => {
    let alive = true
    ;(async () => {
      try {
        const page = await fetchPaperPage(client, connection.dataset, 0)
        if (alive)
          setState({
            phase: 'ready',
            papers: page.items,
            total: page.total,
            refreshing: false,
            loadingMore: false,
            loadedAtMs: Date.now(),
          })
      } catch {
        if (alive) setState({ phase: 'error', message: 'Could not load papers from your Barkpark.' })
      }
    })()
    return () => {
      alive = false
    }
  }, [client, connection.dataset, attempt])

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

  const loadMore = useCallback(() => {
    if (pageInFlight.current) return
    setState((prev) => {
      if (prev.phase !== 'ready' || prev.loadingMore || prev.refreshing) return prev
      if (prev.papers.length >= prev.total) return prev
      pageInFlight.current = true
      const offset = prev.papers.length
      ;(async () => {
        try {
          const page = await fetchPaperPage(client, connection.dataset, offset)
          setState((cur) => {
            if (cur.phase !== 'ready') return cur
            // Dedupe on _id: a paper updated between page fetches can shift
            // pages under order=_updatedAt:desc.
            const seen = new Set(cur.papers.map((p) => p._id))
            const fresh = page.items.filter((p) => !seen.has(p._id))
            return {
              ...cur,
              papers: [...cur.papers, ...fresh],
              total: page.total,
              loadingMore: false,
            }
          })
        } catch {
          // Honest degrade: stop the spinner; the next end-reach retries.
          setState((cur) => (cur.phase === 'ready' ? { ...cur, loadingMore: false } : cur))
        } finally {
          pageInFlight.current = false
        }
      })()
      return { ...prev, loadingMore: true }
    })
  }, [client, connection.dataset])

  if (openPaper !== undefined) {
    return (
      <PaperReaderScreen
        connection={connection}
        paperId={openPaper.id}
        paperTitle={openPaper.title}
        onBack={() => setOpenPaper(undefined)}
      />
    )
  }

  if (state.phase === 'loading') {
    return (
      <View style={[styles.center, { backgroundColor: theme.bg }]}>
        <ActivityIndicator color={theme.accent} />
        <Text style={[styles.muted, { color: theme.textMuted }]}>Loading papers…</Text>
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

  if (state.papers.length === 0) {
    return (
      <View style={[styles.center, { backgroundColor: theme.bg }]}>
        <Text style={[styles.body, { color: theme.text }]}>No papers yet.</Text>
        <Text style={[styles.muted, { color: theme.textMuted }]}>
          Published papers on this Barkpark show up here.
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
      data={state.papers}
      keyExtractor={(paper) => paper._id}
      refreshControl={
        <RefreshControl
          refreshing={state.refreshing}
          onRefresh={refresh}
          tintColor={theme.accent}
        />
      }
      onEndReached={loadMore}
      onEndReachedThreshold={0.6}
      ListFooterComponent={
        state.loadingMore ? (
          <View style={styles.footer}>
            <ActivityIndicator color={theme.accent} />
          </View>
        ) : state.papers.length < state.total ? (
          <Pressable accessibilityRole="button" onPress={loadMore} style={styles.footer}>
            <Text style={[styles.link, { color: theme.accent }]}>
              Load more ({state.papers.length} of {state.total})
            </Text>
          </Pressable>
        ) : null
      }
      renderItem={({ item }) => (
        <PaperRow
          paper={item}
          nowMs={state.loadedAtMs}
          theme={theme}
          onPress={() => setOpenPaper({ id: item._id, title: item.title })}
        />
      )}
    />
  )
}

function PaperRow({
  paper,
  nowMs,
  theme,
  onPress,
}: {
  paper: PaperListItem
  nowMs: number
  theme: Theme
  onPress: () => void
}) {
  return (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
      style={[styles.row, { backgroundColor: theme.surface, borderColor: theme.border }]}
    >
      <Text numberOfLines={2} style={[styles.title, { color: theme.text }]}>
        {paper.title}
      </Text>
      {paper.description !== undefined && (
        <Text numberOfLines={2} style={[styles.description, { color: theme.textMuted }]}>
          {paper.description}
        </Text>
      )}
      <View style={styles.rowMeta}>
        {paper.main_tag !== undefined && (
          <Text style={[styles.pill, { color: theme.accent, borderColor: theme.accent }]}>
            {paper.main_tag}
          </Text>
        )}
        {paper._updatedAt !== undefined && (
          <Text style={[styles.metaText, { color: theme.textMuted }]}>
            {relativeTime(paper._updatedAt, nowMs)}
          </Text>
        )}
      </View>
    </Pressable>
  )
}

const styles = StyleSheet.create({
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 10, padding: 24 },
  listContent: { padding: 16, gap: 10 },
  footer: { paddingVertical: 16, alignItems: 'center' },
  row: { borderWidth: 1, borderRadius: 12, padding: 12, gap: 6, marginBottom: 8 },
  title: { fontSize: 15, fontWeight: '600', lineHeight: 20 },
  description: { fontSize: 13, lineHeight: 18 },
  rowMeta: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  pill: {
    fontSize: 11,
    fontWeight: '700',
    borderWidth: 1,
    borderRadius: 5,
    paddingHorizontal: 5,
    paddingVertical: 1,
    overflow: 'hidden',
  },
  metaText: { fontSize: 12 },
  body: { fontSize: 15, textAlign: 'center' },
  muted: { fontSize: 13, textAlign: 'center' },
  link: { fontSize: 14, textDecorationLine: 'underline' },
})
