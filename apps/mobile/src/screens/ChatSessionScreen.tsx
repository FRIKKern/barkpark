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
import type { StreamFailure, StreamStatus } from '../api/chat'
import { answerable, approvalStatus, isCard, requestId, type ChatMessage } from '../chat/wire'
import { useChatSession } from '../chat/useChatSession'
import { useTheme, type Theme } from '../ui/theme'

const CARD_TITLES: Record<string, string> = {
  approval: 'Approval requested',
  question: 'Question',
  plan: 'Plan proposed',
}

// ── header connection label (charter D24) ────────────────────────────────────

export interface HeaderStatus {
  text: string
  tone: 'muted' | 'danger'
  /** refused is actionable: 'retry' rebuilds the store (which re-reads the
   * stored token — the re-auth flow), 'back' leaves the dead session. */
  action?: 'retry' | 'back'
}

/** The label map — the raw StreamStatus enum NEVER reaches the UI. open and
 * closed render nothing (silence is the healthy state); degraded keeps the
 * transcript intact and the composer editable; refused names WHICH wall the
 * stream hit and what tapping it does. Pure, so it is jest-provable. */
export function headerStatus(
  status: StreamStatus,
  failure?: StreamFailure,
): HeaderStatus | undefined {
  switch (status) {
    case 'connecting':
      return { text: 'connecting…', tone: 'muted' }
    case 'degraded':
      return { text: 'reconnecting…', tone: 'muted' }
    case 'refused': {
      const http = failure?.httpStatus
      if (http === 401 || http === 403)
        return { text: 'signed out — sign in again', tone: 'danger', action: 'retry' }
      if (http === 404) return { text: 'session gone', tone: 'danger', action: 'back' }
      return { text: 'connection refused — tap to retry', tone: 'danger', action: 'retry' }
    }
    case 'open':
    case 'closed':
      return undefined
  }
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
  const {
    state,
    loading,
    loadError,
    transportError,
    streamStatus,
    streamFailure,
    send,
    interrupt,
    answer,
    retry,
  } = useChatSession(connection, sessionId)
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
  const connLabel = headerStatus(streamStatus, streamFailure)
  // The composer is DISABLED behind a refused wall (sending into a dead stream
  // would lie) but stays EDITABLE while degraded — the transcript is intact
  // and the retry loop is live.
  const composerBlocked = loading || loadError !== undefined || streamStatus === 'refused'

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
      <View style={[styles.header, { backgroundColor: theme.bg }]}>
        <Pressable accessibilityRole="button" onPress={onBack} hitSlop={12}>
          <Text style={[styles.back, { color: theme.text }]}>‹</Text>
        </Pressable>
        <Text numberOfLines={1} style={[styles.headerTitle, { color: theme.text }]}>
          {title}
        </Text>
        <View style={styles.headerMeta}>
          {state.mode !== '' && (
            <Text style={[styles.metaBadge, { color: theme.textMuted }]}>{state.mode}</Text>
          )}
          {connLabel !== undefined &&
            (connLabel.action !== undefined ? (
              <Pressable
                accessibilityRole="button"
                hitSlop={8}
                onPress={connLabel.action === 'back' ? onBack : retry}
              >
                <Text style={[styles.metaBadge, { color: theme.danger }]}>{connLabel.text}</Text>
              </Pressable>
            ) : (
              <Text
                style={[
                  styles.metaBadge,
                  { color: connLabel.tone === 'danger' ? theme.danger : theme.textMuted },
                ]}
              >
                {connLabel.text}
              </Text>
            ))}
        </View>
      </View>

      <View style={styles.transcript}>{body}</View>

      {notice !== undefined && (
        <Text style={[styles.notice, { color: theme.textMuted }]}>{notice}</Text>
      )}

      <View style={[styles.composer, { backgroundColor: theme.bg }]}>
        <TextInput
          style={[
            styles.input,
            { color: theme.text, backgroundColor: theme.surface, borderColor: theme.border },
          ]}
          placeholder={state.exited ? 'Send to relaunch…' : 'Message…'}
          placeholderTextColor={theme.textMuted}
          value={draft}
          onChangeText={setDraft}
          multiline
          editable={!composerBlocked}
        />
        {turnActive ? (
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Stop the running turn"
            onPress={interrupt}
            style={[styles.roundBtn, { backgroundColor: theme.surface, borderColor: theme.border, borderWidth: StyleSheet.hairlineWidth }]}
          >
            <Text style={[styles.stopGlyph, { color: theme.danger }]}>■</Text>
          </Pressable>
        ) : null}
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Send message"
          onPress={onSend}
          disabled={draft.trim() === '' || composerBlocked}
          style={[
            styles.roundBtn,
            { backgroundColor: draft.trim() === '' ? theme.border : theme.accent },
          ]}
        >
          <Text style={[styles.sendGlyph, { color: theme.accentText }]}>↑</Text>
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
      <View style={[styles.userBubble, { backgroundColor: theme.bubble }]}>
        <Text style={[styles.userText, { color: theme.text }]}>{row.content}</Text>
        {row.queued && (
          <Text style={[styles.queuedBadge, { color: theme.textMuted }]}>⧗ queued</Text>
        )}
      </View>
    )
  }
  if (row.kind === 'tail') {
    // The streaming tail is an assistant turn in progress: the same unbubbled
    // document text, with a quiet inline cursor as the only liveness mark.
    return (
      <Text style={[styles.assistantText, { color: theme.text }]}>
        {row.text}
        <Text style={{ color: theme.textMuted }}> ▍</Text>
      </Text>
    )
  }

  const m = row.message
  if (isCard(m)) return <CardRow m={m} theme={theme} inFlight={inFlight} onAnswer={onAnswer} />

  const text = (m.source_markdown ?? '').trim()
  if (m.role === 'user') {
    // The one structural law: the user speaks in a soft rounded bubble…
    return (
      <View style={[styles.userBubble, { backgroundColor: theme.bubble }]}>
        <Text style={[styles.userText, { color: theme.text }]}>{text}</Text>
      </View>
    )
  }
  if (m.role === 'assistant') {
    // …and the answer is a document: full-width flowing text directly on the
    // background — no bubble, no border, no chrome.
    return <Text style={[styles.assistantText, { color: theme.text }]}>{text}</Text>
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
    <View style={[styles.card, { borderColor: theme.border, backgroundColor: theme.surface }]}>
      <Text style={[styles.cardTitle, { color: theme.textMuted }]}>
        {CARD_TITLES[m.role] ?? m.role}
      </Text>
      <Text style={[styles.cardBody, { color: theme.text }]}>
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
            style={[styles.pillBtn, { backgroundColor: theme.accent }]}
          >
            <Text style={[styles.pillBtnText, { color: theme.accentText }]}>Allow</Text>
          </Pressable>
          <Pressable
            accessibilityRole="button"
            onPress={() => onAnswer(rid, 'deny')}
            style={[
              styles.pillBtn,
              { borderColor: theme.border, borderWidth: StyleSheet.hairlineWidth },
            ]}
          >
            <Text style={[styles.pillBtnText, { color: theme.danger }]}>Deny</Text>
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
  // The header sits on the background — no surface slab, no border. The
  // title and whitespace carry it (the ChatGPT/Claude register).
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    paddingHorizontal: 18,
    paddingTop: 54,
    paddingBottom: 12,
  },
  back: { fontSize: 26, fontWeight: '400', lineHeight: 28, marginTop: -2 },
  headerTitle: { flex: 1, fontSize: 16, fontWeight: '600' },
  headerMeta: { flexDirection: 'row', gap: 8 },
  metaBadge: { fontSize: 12 },
  transcript: { flex: 1 },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 10, padding: 24 },
  // Generous vertical rhythm between turns — whitespace is the hierarchy.
  listContent: { paddingHorizontal: 18, paddingTop: 10, paddingBottom: 20, gap: 18, flexGrow: 1 },
  // User turns: a soft rounded neutral bubble, right-aligned.
  userBubble: {
    alignSelf: 'flex-end',
    borderRadius: 22,
    paddingHorizontal: 16,
    paddingVertical: 10,
    maxWidth: '80%',
  },
  userText: { fontSize: 16, lineHeight: 23 },
  // Assistant turns: full-width document text on the background.
  assistantText: { fontSize: 16, lineHeight: 26, alignSelf: 'stretch' },
  queuedBadge: { fontSize: 11, marginTop: 4 },
  systemLine: { fontSize: 13, lineHeight: 18, fontStyle: 'italic' },
  card: {
    borderWidth: StyleSheet.hairlineWidth,
    borderRadius: 16,
    padding: 16,
    gap: 10,
    alignSelf: 'stretch',
  },
  cardTitle: { fontSize: 11, fontWeight: '600', textTransform: 'uppercase', letterSpacing: 1 },
  cardBody: { fontSize: 15, lineHeight: 22 },
  cardStatus: { fontSize: 13, fontWeight: '600' },
  cardActions: { flexDirection: 'row', gap: 10, marginTop: 2 },
  pillBtn: {
    borderRadius: 999,
    paddingHorizontal: 20,
    paddingVertical: 9,
    alignItems: 'center',
    justifyContent: 'center',
  },
  pillBtnText: { fontSize: 14, fontWeight: '600' },
  notice: { fontSize: 12, textAlign: 'center', paddingHorizontal: 18, paddingVertical: 4 },
  // The composer floats on the background: a pill input + a round send.
  composer: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    gap: 10,
    paddingHorizontal: 16,
    paddingTop: 8,
    paddingBottom: 14,
  },
  input: {
    flex: 1,
    borderWidth: StyleSheet.hairlineWidth,
    borderRadius: 22,
    paddingHorizontal: 18,
    paddingTop: 11,
    paddingBottom: 11,
    fontSize: 16,
    lineHeight: 21,
    maxHeight: 120,
  },
  roundBtn: {
    width: 40,
    height: 40,
    borderRadius: 20,
    alignItems: 'center',
    justifyContent: 'center',
  },
  sendGlyph: { fontSize: 20, fontWeight: '700', lineHeight: 24 },
  stopGlyph: { fontSize: 14, lineHeight: 16 },
  body: { fontSize: 15, textAlign: 'center' },
  muted: { fontSize: 13, textAlign: 'center' },
  link: { fontSize: 14, textDecorationLine: 'underline' },
})
