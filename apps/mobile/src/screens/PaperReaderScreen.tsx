// Paper reader — the NATIVE PortableDoc renderer over a virtualized FlatList
// (task mob-w2-paper-reader; crown cr-059 fast-path, promoted into v1 by the
// user ruling after the WebView spike's D11 scroll FAIL).
//
// VIRTUALIZATION (criterion 4): the block array IS the FlatList data — one
// list row per top-level block, so a 104-block capstone (and the growing
// corpus behind it) never mounts as one monolithic ScrollView. Container
// blocks (section/steps/columns/figure) recurse internally; they are single
// rows. Mermaid diagrams mount as per-diagram WebView islands
// (MermaidIsland.tsx carries the strategy justification).
//
// Honest states: loading, error-with-retry, empty (a paper with no blocks
// says so instead of rendering blank).
import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  ActivityIndicator,
  FlatList,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native'

import { makeInstanceClient, type InstanceConnection } from '../api/instance'
import {
  classifyPaperFailure,
  fetchPaper,
  type PaperDoc,
  type PaperFetchFailure,
} from '../api/papers'
import { renderBlockNative, type BlockCtx } from '../papers/portabledoc/blocks'
import { isMap, str } from '../papers/portabledoc/model'
import { readCachedPaper, writeCachedPaper } from '../state/cache'
import { relativeTime } from './ChatScreen'
import { useTheme } from '../ui/theme'
import { scale } from '../ui/typography'

// Distinct copy per failure class (D42) — see PapersScreen for the law.
// Exported so the offline probes assert the distinction.
export const READER_OFFLINE_COPY = "You're offline — this paper isn't cached on this device yet."
export const READER_FAILED_COPY = 'Could not load this paper.'

type ReaderState =
  | { phase: 'loading' }
  | { phase: 'error'; failure: PaperFetchFailure }
  | {
      phase: 'ready'
      paper: PaperDoc
      /** present = painting the CACHED body (stale badge shown). Cleared the
       * moment the network replaces or confirms the body. paintedAtMs is the
       * badge's "now" — captured at paint time (render must stay pure). */
      cached?: { rev?: string; cachedAtMs: number; paintedAtMs: number }
    }

export function PaperReaderScreen({
  connection,
  paperId,
  paperTitle,
  onBack,
}: {
  connection: InstanceConnection
  paperId: string
  paperTitle?: string
  onBack: () => void
}) {
  const theme = useTheme()
  const [state, setState] = useState<ReaderState>({ phase: 'loading' })
  const [attempt, setAttempt] = useState(0)
  const client = useMemo(() => makeInstanceClient(connection), [connection])

  useEffect(() => {
    let alive = true
    ;(async () => {
      // Read-through on open (D42): the cached body paints instantly with a
      // stale badge; the network then replaces it (a NEWER _updatedAt lands
      // here — the next-open rev-compare) or, offline, the badge stands.
      const cached = readCachedPaper(connection, paperId)
      if (alive && cached !== undefined) {
        const badge: { rev?: string; cachedAtMs: number; paintedAtMs: number } = {
          cachedAtMs: cached.cachedAtMs,
          paintedAtMs: Date.now(),
        }
        if (cached.rev !== undefined) badge.rev = cached.rev
        setState({ phase: 'ready', paper: cached.data, cached: badge })
      }
      try {
        const paper = await fetchPaper(client, connection.dataset, paperId)
        writeCachedPaper(connection, paper) // write-through: survives the next cold open
        if (alive) setState({ phase: 'ready', paper })
      } catch (err) {
        if (!alive) return
        if (cached !== undefined) return // stale body + badge stand — never blank a readable paper
        setState({ phase: 'error', failure: classifyPaperFailure(err) })
      }
    })()
    return () => {
      alive = false
    }
  }, [client, connection, connection.dataset, paperId, attempt])

  const retry = useCallback(() => {
    setState({ phase: 'loading' })
    setAttempt((a) => a + 1)
  }, [])

  // serverBase resolves root-relative media srcs (/media/files/…) against the
  // connected instance — the dominant live image shape (review F2).
  const ctx: BlockCtx = useMemo(
    () => ({ theme, serverBase: connection.projectUrl }),
    [theme, connection.projectUrl],
  )

  const header = (
    <View style={[styles.header, { borderBottomColor: theme.border, backgroundColor: theme.bg }]}>
      <Pressable accessibilityRole="button" onPress={onBack} hitSlop={12}>
        <Text style={[styles.back, { color: theme.accent }]}>‹ Papers</Text>
      </Pressable>
      <Text numberOfLines={1} style={[styles.headerTitle, { color: theme.text }]}>
        {paperTitle ?? paperId}
      </Text>
    </View>
  )

  if (state.phase === 'loading') {
    return (
      <View style={{ flex: 1, backgroundColor: theme.bg }}>
        {header}
        <View style={styles.center}>
          <ActivityIndicator color={theme.accent} />
          <Text style={[styles.muted, { color: theme.textMuted }]}>Loading paper…</Text>
        </View>
      </View>
    )
  }

  if (state.phase === 'error') {
    const offline = state.failure === 'offline'
    return (
      <View style={{ flex: 1, backgroundColor: theme.bg }}>
        {header}
        <View style={styles.center}>
          <Text style={[styles.body, { color: offline ? theme.text : theme.danger }]}>
            {offline ? READER_OFFLINE_COPY : READER_FAILED_COPY}
          </Text>
          {offline && (
            <Text style={[styles.muted, { color: theme.textMuted }]}>
              Open it once while online and it stays readable here.
            </Text>
          )}
          <Pressable accessibilityRole="button" onPress={retry}>
            <Text style={[styles.link, { color: theme.accent }]}>Try again</Text>
          </Pressable>
        </View>
      </View>
    )
  }

  const { paper } = state
  if (paper.blocks.length === 0) {
    return (
      <View style={{ flex: 1, backgroundColor: theme.bg }}>
        {header}
        <View style={styles.center}>
          <Text style={[styles.body, { color: theme.text }]}>This paper has no content yet.</Text>
        </View>
      </View>
    )
  }

  return (
    <View style={{ flex: 1, backgroundColor: theme.bg }}>
      {header}
      {state.cached !== undefined && (
        <View style={[styles.staleBadge, { backgroundColor: theme.warnSoft, borderBottomColor: theme.warn }]}>
          <Text style={[styles.staleText, { color: theme.text }]}>
            Cached copy · updated{' '}
            {relativeTime(
              state.cached.rev ?? new Date(state.cached.cachedAtMs).toISOString(),
              state.cached.paintedAtMs,
            )}
          </Text>
        </View>
      )}
      <FlatList
        style={{ backgroundColor: theme.bg }}
        contentContainerStyle={styles.listContent}
        data={paper.blocks}
        keyExtractor={(block, index) => {
          const id = isMap(block) ? str(block.id) : ''
          return id !== '' ? id : `block-${index}`
        }}
        renderItem={({ item, index }) => <>{renderBlockNative(item, ctx, index)}</>}
        // 104-block docs: keep a generous render window so fast flings hit
        // painted rows, but let far-off blocks (and their mermaid islands)
        // unmount — the D11 memory axis stays bounded.
        initialNumToRender={12}
        windowSize={9}
        maxToRenderPerBatch={16}
        removeClippedSubviews
      />
    </View>
  )
}

const styles = StyleSheet.create({
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    paddingHorizontal: 16,
    paddingTop: 54,
    paddingBottom: 10,
    borderBottomWidth: 1,
  },
  back: { ...scale.md, fontWeight: '600' },
  headerTitle: { flex: 1, ...scale.md, fontWeight: '700' },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 10, padding: 24 },
  staleBadge: {
    borderBottomWidth: 1,
    paddingVertical: 5,
    paddingHorizontal: 16,
    alignItems: 'center',
  },
  staleText: { ...scale.xs, fontWeight: '600' },
  listContent: { paddingHorizontal: 18, paddingTop: 8, paddingBottom: 40 },
  body: { ...scale.md, textAlign: 'center' },
  muted: { ...scale.sm, textAlign: 'center' },
  link: { ...scale.base, textDecorationLine: 'underline' },
})
