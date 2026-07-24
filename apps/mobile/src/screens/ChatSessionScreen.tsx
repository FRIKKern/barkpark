// One chat session — the full floor (charter crown R3): send, streamed
// assistant turns, interrupt, approve/deny. The transcript is the reducer's
// truth: settled rows (Postgres, via the turn-boundary refetch), optimistic
// local echoes (queued-badged mid-turn, D12), and the live streaming tail
// (D9). Cards (approval / plan / question) answer through the same
// allow/deny-only contract as the TUI and Studio — one row, one truth.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  ActivityIndicator,
  FlatList,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native'

import type { InstanceConnection } from '../api/instance'
import { answerable, approvalStatus, isCard, requestId, type ChatMessage } from '../chat/wire'
import { useChatSession } from '../chat/useChatSession'
import { useTheme, type Theme } from '../ui/theme'

const CARD_TITLES: Record<string, string> = {
  approval: 'Approval requested',
  question: 'Question',
  plan: 'Plan proposed',
}

type Row =
  | { key: string; kind: 'message'; message: ChatMessage }
  | { key: string; kind: 'local'; content: string; queued: boolean }
  | { key: string; kind: 'tail'; text: string }

export function ChatSessionScreen({
  connection,
  sessionId,
  sessionTitle,
  onBack,
}: {
  connection: InstanceConnection
  sessionId: string
  /** the list row's title — painted until the full GET lands its own. */
  sessionTitle?: string
  onBack: () => void
}) {
  const theme = useTheme()
  const { state, loading, loadError, transportError, streamStatus, send, interrupt, answer, retry } =
    useChatSession(connection, sessionId)
  const [draft, setDraft] = useState('')
  const listRef = useRef<FlatList<Row>>(null)

  const rows = useMemo<Row[]>(() => {
    const out: Row[] = state.messages.map((m) => ({
      key: `m-${m.seq}`,
      kind: 'message',
      message: m,
    }))
    state.local.forEach((l, i) => {
      out.push({ key: `l-${i}`, kind: 'local', content: l.content, queued: l.queued })
    })
    if (state.tail !== '') out.push({ key: 'tail', kind: 'tail', text: state.tail })
    return out
  }, [state.messages, state.local, state.tail])

  // Follow mode: keep the newest content in view as rows/tail grow.
  const scrollDown = useCallback(() => {
    listRef.current?.scrollToEnd({ animated: false })
  }, [])
  useEffect(() => {
    const t = setTimeout(scrollDown, 50)
    return () => clearTimeout(t)
  }, [rows.length, state.tail, scrollDown])

  const onSend = useCallback(() => {
    const content = draft.trim()
    if (content === '') return
    setDraft('')
    send(content)
  }, [draft, send])

  const title = state.title !== '' ? state.title : (sessionTitle ?? sessionId)
  const turnActive = state.phase !== 'idle'

  let body
  if (loading) {
    body = (
      <View style={styles.center}>
        <ActivityIndicator color={theme.accent} />
        <Text style={[styles.muted, { color: theme.textMuted }]}>Loading session…</Text>
      </View>
    )
  } else if (loadError !== undefined) {
    body = (
      <View style={styles.center}>
        <Text style={[styles.body, { color: theme.danger }]}>
          Could not load this session. {loadError}
        </Text>
        <Pressable accessibilityRole="button" onPress={retry}>
          <Text style={[styles.link, { color: theme.accent }]}>Try again</Text>
        </Pressable>
      </View>
    )
  } else {
    body = (
      <FlatList
        ref={listRef}
        data={rows}
        keyExtractor={(row) => row.key}
        contentContainerStyle={styles.listContent}
        onContentSizeChange={scrollDown}
        ListEmptyComponent={
          <View style={styles.center}>
            <Text style={[styles.muted, { color: theme.textMuted }]}>
              No messages yet — send one to start the session.
            </Text>
          </View>
        }
        renderItem={({ item }) => (
          <TranscriptRow
            row={item}
            theme={theme}
            inFlight={state.answerInFlight}
            onAnswer={answer}
          />
        )}
      />
    )
  }

  const notice = transportError ?? (state.notice !== '' ? state.notice : undefined)

  return (
    <KeyboardAvoidingView
      style={[styles.root, { backgroundColor: theme.bg }]}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
    >
      <View style={[styles.header, { borderBottomColor: theme.border, backgroundColor: theme.surface }]}>
        <Pressable accessibilityRole="button" onPress={onBack} hitSlop={12}>
          <Text style={[styles.back, { color: theme.accent }]}>‹ Sessions</Text>
        </Pressable>
        <Text numberOfLines={1} style={[styles.headerTitle, { color: theme.text }]}>
          {title}
        </Text>
        <View style={styles.headerMeta}>
          {state.mode !== '' && (
            <Text style={[styles.metaBadge, { color: theme.textMuted, borderColor: theme.border }]}>
              {state.mode}
            </Text>
          )}
          {streamStatus !== 'open' && (
            <Text style={[styles.metaBadge, { color: theme.textMuted, borderColor: theme.border }]}>
              {streamStatus}
            </Text>
          )}
        </View>
      </View>

      <View style={styles.transcript}>{body}</View>

      {notice !== undefined && (
        <Text style={[styles.notice, { color: theme.textMuted, backgroundColor: theme.surface }]}>
          {notice}
        </Text>
      )}

      <View style={[styles.composer, { borderTopColor: theme.border, backgroundColor: theme.surface }]}>
        <TextInput
          style={[styles.input, { color: theme.text, borderColor: theme.border }]}
          placeholder={state.exited ? 'Send to relaunch…' : 'Message…'}
          placeholderTextColor={theme.textMuted}
          value={draft}
          onChangeText={setDraft}
          multiline
          editable={!loading && loadError === undefined}
        />
        {turnActive ? (
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Stop the running turn"
            onPress={interrupt}
            style={[styles.actionBtn, { backgroundColor: theme.danger }]}
          >
            <Text style={[styles.actionText, { color: theme.accentText }]}>Stop</Text>
          </Pressable>
        ) : null}
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Send message"
          onPress={onSend}
          disabled={draft.trim() === '' || loading || loadError !== undefined}
          style={[
            styles.actionBtn,
            { backgroundColor: draft.trim() === '' ? theme.border : theme.accent },
          ]}
        >
          <Text style={[styles.actionText, { color: theme.accentText }]}>Send</Text>
        </Pressable>
      </View>
    </KeyboardAvoidingView>
  )
}

function TranscriptRow({
  row,
  theme,
  inFlight,
  onAnswer,
}: {
  row: Row
  theme: Theme
  inFlight: Record<string, string>
  onAnswer: (requestId: string, decision: 'allow' | 'deny') => void
}) {
  if (row.kind === 'local') {
    return (
      <View style={[styles.bubble, styles.userBubble, { backgroundColor: theme.accent }]}>
        <Text style={[styles.bubbleText, { color: theme.accentText }]}>{row.content}</Text>
        {row.queued && (
          <Text style={[styles.queuedBadge, { color: theme.accentText }]}>⧗ queued</Text>
        )}
      </View>
    )
  }
  if (row.kind === 'tail') {
    return (
      <View style={[styles.bubble, styles.assistantBubble, { backgroundColor: theme.surface, borderColor: theme.border }]}>
        <Text style={[styles.bubbleText, { color: theme.text }]}>{row.text}</Text>
        <Text style={[styles.streamingMark, { color: theme.textMuted }]}>▍streaming</Text>
      </View>
    )
  }

  const m = row.message
  if (isCard(m)) return <CardRow m={m} theme={theme} inFlight={inFlight} onAnswer={onAnswer} />

  const text = (m.source_markdown ?? '').trim()
  if (m.role === 'user') {
    return (
      <View style={[styles.bubble, styles.userBubble, { backgroundColor: theme.accent }]}>
        <Text style={[styles.bubbleText, { color: theme.accentText }]}>{text}</Text>
      </View>
    )
  }
  if (m.role === 'assistant') {
    return (
      <View style={[styles.bubble, styles.assistantBubble, { backgroundColor: theme.surface, borderColor: theme.border }]}>
        <Text style={[styles.bubbleText, { color: theme.text }]}>{text}</Text>
      </View>
    )
  }
  // Non-text rows (tool / todo / thinking / system): one honest muted line —
  // the typed-block richness stays a TUI/Studio surface this wave.
  if (text === '') return null
  return (
    <Text numberOfLines={3} style={[styles.systemLine, { color: theme.textMuted }]}>
      {m.role}: {text}
    </Text>
  )
}

function CardRow({
  m,
  theme,
  inFlight,
  onAnswer,
}: {
  m: ChatMessage
  theme: Theme
  inFlight: Record<string, string>
  onAnswer: (requestId: string, decision: 'allow' | 'deny') => void
}) {
  const rid = requestId(m)
  const status = approvalStatus(m)
  const pendingDecision = inFlight[rid]
  const canAnswer = answerable(m) && pendingDecision === undefined
  return (
    <View style={[styles.card, { borderColor: theme.accent, backgroundColor: theme.surface }]}>
      <Text style={[styles.cardTitle, { color: theme.accent }]}>
        {CARD_TITLES[m.role] ?? m.role}
      </Text>
      <Text style={[styles.bubbleText, { color: theme.text }]}>
        {(m.source_markdown ?? '').trim()}
      </Text>
      {pendingDecision !== undefined ? (
        <Text style={[styles.cardStatus, { color: theme.textMuted }]}>
          answering: {pendingDecision}…
        </Text>
      ) : status !== '' && status !== 'pending' ? (
        <Text
          style={[styles.cardStatus, { color: status === 'allowed' ? theme.success : theme.danger }]}
        >
          {status}
        </Text>
      ) : canAnswer ? (
        <View style={styles.cardActions}>
          <Pressable
            accessibilityRole="button"
            onPress={() => onAnswer(rid, 'allow')}
            style={[styles.actionBtn, { backgroundColor: theme.success }]}
          >
            <Text style={[styles.actionText, { color: theme.accentText }]}>Allow</Text>
          </Pressable>
          <Pressable
            accessibilityRole="button"
            onPress={() => onAnswer(rid, 'deny')}
            style={[styles.actionBtn, { backgroundColor: theme.danger }]}
          >
            <Text style={[styles.actionText, { color: theme.accentText }]}>Deny</Text>
          </Pressable>
        </View>
      ) : (
        <Text style={[styles.cardStatus, { color: theme.textMuted }]}>pending</Text>
      )}
    </View>
  )
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    paddingHorizontal: 14,
    paddingTop: 54,
    paddingBottom: 10,
    borderBottomWidth: 1,
  },
  back: { fontSize: 15, fontWeight: '600' },
  headerTitle: { flex: 1, fontSize: 15, fontWeight: '700' },
  headerMeta: { flexDirection: 'row', gap: 6 },
  metaBadge: {
    fontSize: 11,
    borderWidth: 1,
    borderRadius: 5,
    paddingHorizontal: 5,
    paddingVertical: 1,
    overflow: 'hidden',
  },
  transcript: { flex: 1 },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 10, padding: 24 },
  listContent: { padding: 14, gap: 8, flexGrow: 1 },
  bubble: { borderRadius: 14, padding: 10, maxWidth: '86%', marginBottom: 2 },
  userBubble: { alignSelf: 'flex-end' },
  assistantBubble: { alignSelf: 'flex-start', borderWidth: 1 },
  bubbleText: { fontSize: 15, lineHeight: 21 },
  queuedBadge: { fontSize: 11, marginTop: 4, opacity: 0.9 },
  streamingMark: { fontSize: 11, marginTop: 4 },
  systemLine: { fontSize: 12, fontStyle: 'italic', paddingHorizontal: 4, marginBottom: 2 },
  card: { borderWidth: 1.5, borderRadius: 12, padding: 12, gap: 8, alignSelf: 'stretch' },
  cardTitle: { fontSize: 12, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 0.5 },
  cardStatus: { fontSize: 13, fontWeight: '600' },
  cardActions: { flexDirection: 'row', gap: 10 },
  actionBtn: {
    borderRadius: 10,
    paddingHorizontal: 16,
    paddingVertical: 9,
    alignItems: 'center',
    justifyContent: 'center',
  },
  actionText: { fontSize: 14, fontWeight: '700' },
  notice: { fontSize: 12, paddingHorizontal: 14, paddingVertical: 6 },
  composer: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    gap: 8,
    padding: 10,
    borderTopWidth: 1,
  },
  input: {
    flex: 1,
    borderWidth: 1,
    borderRadius: 12,
    paddingHorizontal: 12,
    paddingVertical: 8,
    fontSize: 15,
    maxHeight: 120,
  },
  body: { fontSize: 15, textAlign: 'center' },
  muted: { fontSize: 13, textAlign: 'center' },
  link: { fontSize: 14, textDecorationLine: 'underline' },
})
