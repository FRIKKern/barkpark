// Papers tab — the list screen, live on the minted token via
// GET /v1/data/query/:dataset/paper (fields-projected light; newest-updated
// first). PAGED (review F3 + verify-round): the live corpus is 537 papers
// and growing — 100 at a time via the pure paperPager accumulator. The stop
// condition is the pager's hasMore (short page = end of corpus, jest-pinned);
// the corpus total from `count=true` feeds the honest "N of M" footer only.
// Selecting a row opens the native reader. Honest states: loading,
// error-with-retry, empty, ready with pull-to-refresh (refresh restarts from
// page one), footer spinner / "Load more" / all-loaded end label. Read-only
// against production by construction.
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
import {
  classifyPaperFailure,
  fetchPaperPage,
  PAPER_PAGE_SIZE,
  type PaperFetchFailure,
  type PaperListItem,
} from '../api/papers'
import { EMPTY_PAGER, appendPage, hydrate, shouldLoadMore, type PagerState } from '../papers/paperPager'
import { readCachedPaperList, writeCachedPaperList } from '../state/cache'
import { relativeTime } from './ChatScreen'
import { PaperReaderScreen } from './PaperReaderScreen'
import { useTheme, type Theme } from '../ui/theme'
import { scale } from '../ui/typography'

// Distinct copy per failure class (D42): offline is a DEVICE condition,
// failure is a BARKPARK condition — collapsing them lies to the user about
// what to fix. Exported so the offline probes assert the distinction.
export const PAPERS_OFFLINE_COPY = "You're offline — papers can't load right now."
export const PAPERS_FAILED_COPY = 'Could not load papers from your Barkpark.'

type ListState =
  | { phase: 'loading' }
  | { phase: 'error'; failure: PaperFetchFailure }
  | {
      phase: 'ready'
      pager: PagerState
      refreshing: boolean
      loadingMore: boolean
      loadedAtMs: number
      /** present = painting the CACHED page (stale badge shown): when the
       * cache row was written. Cleared the moment the network confirms. */
      cachedAtMs?: number
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
      // Read-through on open (D42): paint the cached page-0 fold instantly
      // with the stale badge, then let the network confirm or replace it.
      const cached = readCachedPaperList(connection)
      if (alive && cached !== undefined) {
        setState({
          phase: 'ready',
          pager: hydrate(cached.data),
          refreshing: false,
          loadingMore: false,
          loadedAtMs: Date.now(),
          cachedAtMs: cached.cachedAtMs,
        })
      }
      try {
        const page = await fetchPaperPage(client, connection.dataset, 0)
        writeCachedPaperList(connection, page) // write-through: next open paints this
        if (alive)
          setState({
            phase: 'ready',
            pager: appendPage(EMPTY_PAGER, page),
            refreshing: false,
            loadingMore: false,
            loadedAtMs: Date.now(),
          })
      } catch (err) {
        if (!alive) return
        // Cached content already painted stands, badge and all — a failed
        // refresh must not blank a readable list.
        if (cached !== undefined) {
          setState((cur) => (cur.phase === 'ready' ? { ...cur, refreshing: false } : cur))
          return
        }
        setState({ phase: 'error', failure: classifyPaperFailure(err) })
      }
    })()
    return () => {
      alive = false
    }
  }, [client, connection, connection.dataset, attempt])

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
      if (!shouldLoadMore(prev.pager)) return prev
      pageInFlight.current = true
      const offset = prev.pager.offset
      ;(async () => {
        try {
          const page = await fetchPaperPage(client, connection.dataset, offset)
          setState((cur) => {
            if (cur.phase !== 'ready') return cur
            return { ...cur, pager: appendPage(cur.pager, page), loadingMore: false }
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
    const offline = state.failure === 'offline'
    return (
      <View style={[styles.center, { backgroundColor: theme.bg }]}>
        <Text style={[styles.body, { color: offline ? theme.text : theme.danger }]}>
          {offline ? PAPERS_OFFLINE_COPY : PAPERS_FAILED_COPY}
        </Text>
        {offline && (
          <Text style={[styles.muted, { color: theme.textMuted }]}>
            Papers you have opened before stay readable offline once cached.
          </Text>
        )}
        <Pressable accessibilityRole="button" onPress={retry}>
          <Text style={[styles.link, { color: theme.accent }]}>Try again</Text>
        </Pressable>
      </View>
    )
  }

  if (state.pager.papers.length === 0) {
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
      data={state.pager.papers}
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
      ListHeaderComponent={
        state.cachedAtMs !== undefined ? (
          <View style={[styles.staleBadge, { backgroundColor: theme.warnSoft, borderColor: theme.warn }]}>
            <Text style={[styles.staleText, { color: theme.text }]}>
              Cached list · updated {relativeTime(new Date(state.cachedAtMs).toISOString(), state.loadedAtMs)}
            </Text>
          </View>
        ) : null
      }
      ListFooterComponent={
        state.loadingMore ? (
          <View style={styles.footer}>
            <ActivityIndicator color={theme.accent} />
          </View>
        ) : shouldLoadMore(state.pager) ? (
          <Pressable accessibilityRole="button" onPress={loadMore} style={styles.footer}>
            <Text style={[styles.link, { color: theme.accent }]}>
              {state.pager.total !== undefined
                ? `Load more (${state.pager.papers.length} of ${state.pager.total})`
                : `Load more (${state.pager.papers.length} loaded)`}
            </Text>
          </Pressable>
        ) : state.pager.papers.length > PAPER_PAGE_SIZE ? (
          <View style={styles.footer}>
            <Text style={[styles.muted, { color: theme.textMuted }]}>
              All {state.pager.papers.length} papers loaded.
            </Text>
          </View>
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
  staleBadge: {
    borderWidth: 1,
    borderRadius: 8,
    paddingVertical: 6,
    paddingHorizontal: 10,
    marginBottom: 10,
    alignItems: 'center',
  },
  staleText: { ...scale.xs, fontWeight: '600' },
  row: { borderWidth: 1, borderRadius: 12, padding: 12, gap: 6, marginBottom: 8 },
  title: { ...scale.md, fontWeight: '600' },
  description: { ...scale.sm },
  rowMeta: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  pill: {
    ...scale.micro,
    fontWeight: '700',
    borderWidth: 1,
    borderRadius: 5,
    paddingHorizontal: 5,
    paddingVertical: 1,
    overflow: 'hidden',
  },
  metaText: { ...scale.xs },
  body: { ...scale.md, textAlign: 'center' },
  muted: { ...scale.sm, textAlign: 'center' },
  link: { ...scale.base, textDecorationLine: 'underline' },
})
