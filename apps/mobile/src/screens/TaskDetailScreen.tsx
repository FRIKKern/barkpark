// Task detail — the board row opened up, plus the fence-free triage bar.
//
// Renders: title · lifecycle_status · priority · assignee · parent · the
// acceptance criteria with met/total (each row's wording, evidence and the
// last honest attempts) · one level of children · and the CLAIM STATE — holder,
// epoch, and the now-line WITH its own timestamp, because a stale pulse must
// READ stale (that is the board convention, not decoration).
//
// The triage bar only ever offers what the claim-epoch law allows this device
// to do (src/tasks/triage.ts owns that judgement). A fenced action is refused
// here, before any request — the button is disabled and says who holds it.
// When the SERVER refuses something we could not have foreseen, its own words
// are what appears in the notice line, verbatim.
import { useCallback, useState } from 'react'
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native'

import type { InstanceConnection } from '../api/instance'
import type { TaskChild } from '../api/tasks'
import {
  criteriaView,
  fenceCheck,
  nowView,
  progressView,
  type CriterionView,
  type TriageState,
} from '../tasks/triage'
import { useTaskTriage } from '../tasks/useTaskTriage'
import { useTheme, type Theme } from '../ui/theme'
import { scale } from '../ui/typography'

export function TaskDetailScreen({
  connection,
  docId,
  fallbackTitle,
  onBack,
  onOpenTask,
}: {
  connection: InstanceConnection
  docId: string
  fallbackTitle?: string
  onBack: () => void
  /** Navigate to another task (parent / child) — the list screen owns the
   * stack, so this screen just asks. */
  onOpenTask?: (docId: string, title?: string) => void
}) {
  const theme = useTheme()
  const { state, refresh, stamp, pulse, claim, release, dismissNotice } = useTaskTriage(
    connection,
    docId,
  )
  const [pulseDraft, setPulseDraft] = useState('')
  const [evidenceFor, setEvidenceFor] = useState<{ index: number; met: boolean } | undefined>(
    undefined,
  )
  const [evidenceDraft, setEvidenceDraft] = useState('')

  const submitStamp = useCallback(() => {
    if (evidenceFor === undefined) return
    stamp(evidenceFor.index, evidenceFor.met, evidenceDraft)
    setEvidenceFor(undefined)
    setEvidenceDraft('')
  }, [evidenceFor, evidenceDraft, stamp])

  const submitPulse = useCallback(() => {
    const text = pulseDraft.trim()
    if (text === '') return
    pulse(text)
    setPulseDraft('')
  }, [pulseDraft, pulse])

  const doc = state.detail?.doc
  const title = doc?.title ?? fallbackTitle ?? docId

  let body
  if (state.phase === 'loading') {
    body = (
      <View style={styles.center}>
        <ActivityIndicator color={theme.accent} />
        <Text style={[styles.muted, { color: theme.textMuted }]}>Loading task…</Text>
      </View>
    )
  } else if (state.phase === 'error') {
    body = (
      <View style={styles.center}>
        <Text style={[styles.body, { color: theme.danger }]}>{state.message}</Text>
        <Pressable accessibilityRole="button" onPress={refresh}>
          <Text style={[styles.link, { color: theme.accent }]}>Try again</Text>
        </Pressable>
      </View>
    )
  } else {
    body = (
      <ScrollView
        style={styles.scroll}
        contentContainerStyle={styles.scrollContent}
        refreshControl={
          <RefreshControl refreshing={state.refreshing} onRefresh={refresh} tintColor={theme.accent} />
        }
      >
        <FactsBlock state={state} theme={theme} onOpenTask={onOpenTask} />
        <ClaimBlock state={state} theme={theme} />
        <CriteriaBlock
          state={state}
          theme={theme}
          onStampRequested={(index, met) => {
            setEvidenceFor({ index, met })
            setEvidenceDraft('')
          }}
        />
        <ChildrenBlock state={state} theme={theme} onOpenTask={onOpenTask} />
      </ScrollView>
    )
  }

  const stampFence = fenceCheck(doc, state.worker, 'stamp')
  const claimFence = fenceCheck(doc, state.worker, 'claim')
  const holdsIt = stampFence.allowed
  const busy = state.pending !== undefined

  return (
    <KeyboardAvoidingView
      style={[styles.root, { backgroundColor: theme.bg }]}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
    >
      <View style={[styles.header, { borderBottomColor: theme.border, backgroundColor: theme.surface }]}>
        <Pressable accessibilityRole="button" onPress={onBack} hitSlop={12}>
          <Text style={[styles.back, { color: theme.accent }]}>‹ Tasks</Text>
        </Pressable>
        <Text numberOfLines={2} style={[styles.headerTitle, { color: theme.text }]}>
          {title}
        </Text>
      </View>

      {body}

      {state.notice !== undefined && (
        <Pressable accessibilityRole="button" onPress={dismissNotice}>
          <Text
            style={[
              styles.notice,
              {
                backgroundColor: theme.surface,
                color: state.notice.tone === 'ok' ? theme.success : theme.danger,
              },
            ]}
          >
            {state.notice.text}
          </Text>
        </Pressable>
      )}

      {state.phase === 'ready' && (
        <View style={[styles.actionBar, { borderTopColor: theme.border, backgroundColor: theme.surface }]}>
          {evidenceFor !== undefined ? (
            <View style={styles.stampRow}>
              <TextInput
                style={[styles.input, { color: theme.text, borderColor: theme.border }]}
                placeholder={
                  evidenceFor.met
                    ? 'Evidence for the met flip (required)…'
                    : 'What was tried, honestly (required)…'
                }
                placeholderTextColor={theme.textMuted}
                value={evidenceDraft}
                onChangeText={setEvidenceDraft}
                multiline
                autoFocus
              />
              <Pressable accessibilityRole="button" onPress={submitStamp} disabled={busy}>
                <Text style={[styles.action, { color: busy ? theme.textMuted : theme.accent }]}>
                  {evidenceFor.met ? 'Stamp met' : 'Record miss'}
                </Text>
              </Pressable>
              <Pressable accessibilityRole="button" onPress={() => setEvidenceFor(undefined)}>
                <Text style={[styles.action, { color: theme.textMuted }]}>Cancel</Text>
              </Pressable>
            </View>
          ) : holdsIt ? (
            <View style={styles.stampRow}>
              <TextInput
                style={[styles.input, { color: theme.text, borderColor: theme.border }]}
                placeholder="Pulse: what are you doing right now?"
                placeholderTextColor={theme.textMuted}
                value={pulseDraft}
                onChangeText={setPulseDraft}
                multiline
              />
              <Pressable accessibilityRole="button" onPress={submitPulse} disabled={busy}>
                <Text style={[styles.action, { color: busy ? theme.textMuted : theme.accent }]}>
                  Pulse
                </Text>
              </Pressable>
              <Pressable accessibilityRole="button" onPress={release} disabled={busy}>
                <Text style={[styles.action, { color: busy ? theme.textMuted : theme.textMuted }]}>
                  Release
                </Text>
              </Pressable>
            </View>
          ) : (
            <View style={styles.stampRow}>
              <Text style={[styles.fenceLine, { color: theme.textMuted }]}>
                {stampFence.allowed ? '' : stampFence.reason}
              </Text>
              {claimFence.allowed ? (
                <Pressable accessibilityRole="button" onPress={claim} disabled={busy}>
                  <Text style={[styles.action, { color: busy ? theme.textMuted : theme.accent }]}>
                    Claim
                  </Text>
                </Pressable>
              ) : (
                // Fenced: no button at all. The app must never attempt a write
                // it can already see the server would refuse.
                <Text style={[styles.action, { color: theme.textMuted }]}>Fenced</Text>
              )}
            </View>
          )}
        </View>
      )}
    </KeyboardAvoidingView>
  )
}

// ── blocks ───────────────────────────────────────────────────────────────────

function FactsBlock({
  state,
  theme,
  onOpenTask,
}: {
  state: TriageState
  theme: Theme
  onOpenTask?: (docId: string, title?: string) => void
}) {
  const doc = state.detail?.doc
  if (doc === undefined) return null
  const progress = progressView(state)
  return (
    <View style={[styles.card, { backgroundColor: theme.surface, borderColor: theme.border }]}>
      <View style={styles.chips}>
        <Chip theme={theme} label={doc.lifecycleStatus ?? 'open'} />
        {doc.priority !== undefined && <Chip theme={theme} label={`P${doc.priority}`} />}
        {progress.total > 0 && (
          <Chip theme={theme} label={`${progress.met}/${progress.total} criteria`} />
        )}
        {doc.labels.map((label) => (
          <Chip key={label} theme={theme} label={label} />
        ))}
      </View>
      <Fact theme={theme} label="Assignee" value={doc.assignee ?? '—'} />
      <Fact theme={theme} label="Worker (this device)" value={state.worker} />
      {doc.parentId !== undefined && (
        <Pressable
          accessibilityRole="button"
          onPress={onOpenTask === undefined ? undefined : () => onOpenTask(doc.parentId ?? '')}
        >
          <Fact theme={theme} label="Parent" value={doc.parentId} linked={onOpenTask !== undefined} />
        </Pressable>
      )}
      {doc.updatedAt !== undefined && (
        <Fact theme={theme} label="Updated" value={doc.updatedAt} />
      )}
    </View>
  )
}

function ClaimBlock({ state, theme }: { state: TriageState; theme: Theme }) {
  const claim = state.detail?.doc.claim
  const now = nowView(state)
  return (
    <View style={[styles.card, { backgroundColor: theme.surface, borderColor: theme.border }]}>
      <Text style={[styles.cardTitle, { color: theme.textMuted }]}>Claim</Text>
      {claim?.worker === undefined ? (
        <Text style={[styles.body, { color: theme.textMuted }]}>Unclaimed.</Text>
      ) : (
        <>
          <Fact theme={theme} label="Holder" value={claim.worker} />
          <Fact theme={theme} label="Epoch" value={claim.epoch !== undefined ? String(claim.epoch) : '—'} />
          <Fact theme={theme} label="Claimed at" value={claim.tsIso ?? '—'} />
        </>
      )}
      {now !== undefined && (
        <View style={styles.nowBlock}>
          <Text style={[styles.nowText, { color: theme.text }]}>
            {now.text}
            {now.pending ? ' …' : ''}
          </Text>
          {/* The now-line's OWN timestamp: this is what makes a stale pulse
              read as stale instead of looking like live work. */}
          <Text style={[styles.metaText, { color: theme.textMuted }]}>
            {now.pending ? 'sending…' : (now.ts ?? 'no timestamp')}
            {now.criterion !== undefined ? ` · criterion ${now.criterion}` : ''}
          </Text>
        </View>
      )}
      {state.staleEpoch && (
        <Text style={[styles.metaText, { color: theme.danger }]}>
          The claim moved under us — re-reading before any fenced write.
        </Text>
      )}
    </View>
  )
}

function CriteriaBlock({
  state,
  theme,
  onStampRequested,
}: {
  state: TriageState
  theme: Theme
  onStampRequested: (index: number, met: boolean) => void
}) {
  const rows = criteriaView(state)
  if (rows.length === 0) return null
  const progress = progressView(state)
  const canStamp = fenceCheck(state.detail?.doc, state.worker, 'stamp').allowed
  return (
    <View style={[styles.card, { backgroundColor: theme.surface, borderColor: theme.border }]}>
      <Text style={[styles.cardTitle, { color: theme.textMuted }]}>
        Acceptance criteria · {progress.met}/{progress.total} met
      </Text>
      {rows.map((row, index) => (
        <CriterionRow
          key={index}
          row={row}
          index={index}
          theme={theme}
          canStamp={canStamp}
          onStampRequested={onStampRequested}
        />
      ))}
    </View>
  )
}

function CriterionRow({
  row,
  index,
  theme,
  canStamp,
  onStampRequested,
}: {
  row: CriterionView
  index: number
  theme: Theme
  canStamp: boolean
  onStampRequested: (index: number, met: boolean) => void
}) {
  return (
    <View style={[styles.criterion, { borderTopColor: theme.border }]}>
      <View style={styles.criterionTop}>
        <Text style={[styles.mark, { color: row.met ? theme.success : theme.textMuted }]}>
          {row.met ? '✓' : '○'}
        </Text>
        <Text style={[styles.criterionText, { color: theme.text, opacity: row.pending ? 0.6 : 1 }]}>
          {row.criterion}
        </Text>
      </View>
      {row.evidence !== undefined && row.evidence !== '' && (
        <Text style={[styles.metaText, { color: theme.textMuted }]}>evidence: {row.evidence}</Text>
      )}
      {row.attempts.map((attempt, i) => (
        <Text key={i} style={[styles.metaText, { color: theme.textMuted }]}>
          miss: {attempt.note}
          {attempt.ts !== undefined ? ` · ${attempt.ts}` : ''}
        </Text>
      ))}
      {canStamp && !row.pending && (
        <View style={styles.criterionActions}>
          {!row.met && (
            <Pressable accessibilityRole="button" onPress={() => onStampRequested(index, true)}>
              <Text style={[styles.action, { color: theme.accent }]}>Mark met</Text>
            </Pressable>
          )}
          {/* There is deliberately no "un-met": the server has no such verb.
              A miss records an honest attempt WITHOUT flipping met. */}
          <Pressable accessibilityRole="button" onPress={() => onStampRequested(index, false)}>
            <Text style={[styles.action, { color: theme.textMuted }]}>Record miss</Text>
          </Pressable>
        </View>
      )}
      {row.pending && (
        <Text style={[styles.metaText, { color: theme.textMuted }]}>sending…</Text>
      )}
    </View>
  )
}

function ChildrenBlock({
  state,
  theme,
  onOpenTask,
}: {
  state: TriageState
  theme: Theme
  onOpenTask?: (docId: string, title?: string) => void
}) {
  const detail = state.detail
  if (detail === undefined || detail.childCount === 0) return null
  return (
    <View style={[styles.card, { backgroundColor: theme.surface, borderColor: theme.border }]}>
      <Text style={[styles.cardTitle, { color: theme.textMuted }]}>
        Children · {detail.childCount}
      </Text>
      {detail.children.map((child) => (
        <ChildRow key={child.doc_id} child={child} theme={theme} onOpenTask={onOpenTask} />
      ))}
    </View>
  )
}

function ChildRow({
  child,
  theme,
  onOpenTask,
}: {
  child: TaskChild
  theme: Theme
  onOpenTask?: (docId: string, title?: string) => void
}) {
  const progress = child.criteria_progress
  return (
    <Pressable
      accessibilityRole="button"
      onPress={onOpenTask === undefined ? undefined : () => onOpenTask(child.doc_id, child.title)}
      style={[styles.criterion, { borderTopColor: theme.border }]}
    >
      <Text style={[styles.criterionText, { color: theme.text }]}>
        {child.title ?? child.doc_id}
      </Text>
      <Text style={[styles.metaText, { color: theme.textMuted }]}>
        {child.lifecycle_status ?? 'open'}
        {progress !== undefined ? ` · ${progress.met}/${progress.total}` : ''}
      </Text>
    </Pressable>
  )
}

function Chip({ theme, label }: { theme: Theme; label: string }) {
  return (
    <Text style={[styles.chip, { color: theme.textMuted, borderColor: theme.border }]}>{label}</Text>
  )
}

function Fact({
  theme,
  label,
  value,
  linked,
}: {
  theme: Theme
  label: string
  value: string
  linked?: boolean
}) {
  return (
    <View style={styles.fact}>
      <Text style={[styles.factLabel, { color: theme.textMuted }]}>{label}</Text>
      <Text
        numberOfLines={2}
        style={[styles.factValue, { color: linked === true ? theme.accent : theme.text }]}
      >
        {value}
      </Text>
    </View>
  )
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  header: { borderBottomWidth: 1, paddingHorizontal: 16, paddingTop: 52, paddingBottom: 10, gap: 6 },
  back: { ...scale.base },
  // RATIFIED DRIFT (the wave's ONE deliberate size change): 17 was the only
  // 17 pt in the app and sat off every rung of the scale. It lands on lg,
  // which keeps the 22 lead exactly and drops the size by 1 pt.
  headerTitle: { ...scale.lg, fontWeight: '700' },
  scroll: { flex: 1 },
  scrollContent: { padding: 16, gap: 12, paddingBottom: 32 },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 10, padding: 24 },
  card: { borderWidth: 1, borderRadius: 12, padding: 12, gap: 8 },
  cardTitle: { ...scale.xs, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 1 },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: 6 },
  chip: {
    ...scale.micro,
    borderWidth: 1,
    borderRadius: 5,
    paddingHorizontal: 6,
    paddingVertical: 2,
    overflow: 'hidden',
  },
  fact: { flexDirection: 'row', gap: 10, alignItems: 'flex-start' },
  factLabel: { ...scale.xs, width: 120 },
  factValue: { flex: 1, ...scale.sm },
  nowBlock: { gap: 2, marginTop: 4 },
  nowText: { ...scale.base, fontStyle: 'italic' },
  criterion: { borderTopWidth: 1, paddingTop: 8, gap: 4 },
  criterionTop: { flexDirection: 'row', gap: 8, alignItems: 'flex-start' },
  mark: { ...scale.md, width: 16 },
  criterionText: { flex: 1, ...scale.base },
  criterionActions: { flexDirection: 'row', gap: 16, marginTop: 2 },
  metaText: { ...scale.xs },
  actionBar: { borderTopWidth: 1, padding: 10, paddingBottom: 26 },
  stampRow: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  input: {
    flex: 1,
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 10,
    paddingVertical: 8,
    maxHeight: 96,
    ...scale.base,
  },
  action: { ...scale.base, fontWeight: '600' },
  fenceLine: { flex: 1, ...scale.xs },
  notice: { ...scale.xs, paddingHorizontal: 16, paddingVertical: 8 },
  body: { ...scale.md, textAlign: 'center' },
  muted: { ...scale.sm, textAlign: 'center' },
  link: { ...scale.base, textDecorationLine: 'underline' },
})
