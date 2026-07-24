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
import { fetchPaper, type PaperDoc } from '../api/papers'
import { renderBlockNative, type BlockCtx } from '../papers/portabledoc/blocks'
import { isMap, str } from '../papers/portabledoc/model'
import { useTheme } from '../ui/theme'

type ReaderState =
  | { phase: 'loading' }
  | { phase: 'error'; message: string }
  | { phase: 'ready'; paper: PaperDoc }

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
      try {
        const paper = await fetchPaper(client, connection.dataset, paperId)
        if (alive) setState({ phase: 'ready', paper })
      } catch {
        if (alive) setState({ phase: 'error', message: 'Could not load this paper.' })
      }
    })()
    return () => {
      alive = false
    }
  }, [client, connection.dataset, paperId, attempt])

  const retry = useCallback(() => {
    setState({ phase: 'loading' })
    setAttempt((a) => a + 1)
  }, [])

  const ctx: BlockCtx = useMemo(() => ({ theme }), [theme])

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
    return (
      <View style={{ flex: 1, backgroundColor: theme.bg }}>
        {header}
        <View style={styles.center}>
          <Text style={[styles.body, { color: theme.danger }]}>{state.message}</Text>
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
  back: { fontSize: 15, fontWeight: '600' },
  headerTitle: { flex: 1, fontSize: 15, fontWeight: '700' },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 10, padding: 24 },
  listContent: { paddingHorizontal: 18, paddingTop: 8, paddingBottom: 40 },
  body: { fontSize: 15, textAlign: 'center' },
  muted: { fontSize: 13, textAlign: 'center' },
  link: { fontSize: 14, textDecorationLine: 'underline' },
})
