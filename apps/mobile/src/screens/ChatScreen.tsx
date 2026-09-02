// Chat tab — the sessions list, live on the minted token (charter D10: chat
// is workspace-scoped BY DESIGN — the workspace's sessions ARE the floor).
// Rows carry the herd truth (agent_state pill + stall badge) and sort by the
// ported attention order (herd.ts: blocked > stalled > working > idle >
// unknown). Selecting a row opens the full session floor. Honest states:
// loading, error-with-retry, empty, ready with pull-to-refresh — the same
// idiom as the Tasks tab.
//
// THREE ORTHOGONAL COLUMNS, and this screen must never conflate them:
//   • status      — liveness (active / working / exited), the runtime's word;
//   • agent_state — attention (working / blocked / idle / unknown), rendered
//     as the pill, where "blocked" ALWAYS reads "needs you";
//   • archived_at — DISMISSAL, and nothing else. Archiving never touches
//     liveness and never touches attention.
//
// Archive is expressed as WHICH SHELF YOU ASKED FOR, never as a per-row flag —
// and that is a CHOICE, not a limitation of the wire: the sidebar row does carry
// `archived_at` (sidebar_json emits it, and ChatSessionSummary now projects it),
// but `shelf` below stays the screen's archived truth. That is the reason a row
// that went stale in either direction can never claim the wrong shelf.
//
// The herd is PERSISTENT here (it used to be a throwaway per-render seed): one
// HerdState folds the cold list AND the live fleet stream, so a session's pill
// flips without a refetch and the attention sort re-orders under your thumb.
import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  ActivityIndicator,
  Animated,
  FlatList,
  PanResponder,
  Pressable,
  RefreshControl,
  StyleSheet,
  Text,
  View,
  type LayoutChangeEvent,
} from 'react-native'

import type { InstanceConnection } from '../api/instance'
import {
  archiveChatSession,
  listChatSessions,
  streamFleetEvents,
  unarchiveChatSession,
  type StreamStatus,
} from '../api/chat'
import {
  applyFleetFrame,
  emptyHerd,
  herdOrder,
  herdRowFor,
  herdSeed,
  herdStalled,
  herdTitleFor,
  type HerdState,
} from '../chat/herd'
import type { ChatSessionSummary } from '../chat/wire'
import type { ConnectionClaim } from '../chat/context'
import { ChatSessionScreen } from './ChatSessionScreen'
import { haptic } from '../ui/haptics'
import { useTheme, type Theme } from '../ui/theme'
import { roles, scale } from '../ui/typography'

/** Which shelf the list is showing — the archived truth this screen renders by
 * (charter D28): "is it archived" is answered by which list you asked for, not
 * by the row's own `archived_at` (which the wire does send, and which a stale
 * row could contradict). */
export type Shelf = 'active' | 'archived'

/** The server's sidebar cap (@sidebar_cap 50) with no pagination behind it, so
 * a full shelf is honestly labelled rather than silently truncated. */
export const SHELF_CAP = 50

/** How often the stall clock re-reads "now". Well under HERD_STALL_AFTER_MS
 * (150s) so a session crosses into stalled within one tick of actually doing
 * so — the badge is computed FRESH from lastFrameAtMs at render (D53h), and
 * this interval exists only to make render happen. */
export const STALL_TICK_MS = 15_000

/** The swipe distance that commits an archive. Deliberately generous: an
 * accidental dismissal costs a trip to the shelf, and there is no undo toast. */
export const SWIPE_COMMIT_PX = 96

/** The transient line a REFUSED lifecycle write paints (TUI parity: model.go's
 * `archive failed — …` picker error). PURE so the copy is pinnable, and phrased
 * as "still" because the row is coming BACK — the failure text and the restored
 * row are one message, not two.
 *
 * There is no undo toast and no retry button here on purpose: the recovery is
 * the shelf re-read that puts the row back, and the honest line's whole job is
 * to explain why a row the user just dismissed reappeared. */
export function lifecycleFailureLine(shelf: Shelf): string {
  return shelf === 'active'
    ? 'Archive failed — the session is still on this shelf.'
    : 'Unarchive failed — the session is still archived.'
}

/** Whether the stall badge may be trusted, given the fleet stream's own state
 * (PURE).
 *
 * The badge means "a working session has gone quiet". A 'refused' fleet stream
 * (any 4xx — signed out, chat unsupported) means NO frame will ever arrive
 * again, so lastFrameAtMs can only age and every working row would slowly wear
 * "stalled" — the badge reporting OUR dead stream as the fleet's silence. That
 * is the every-row-stalled lie, and transport truth outranks it: with the live
 * layer refused the screen says the live layer is down and shows no stall
 * badges. 'degraded' keeps them — that stream is still retrying and frames do
 * still land between blips. */
export function stallClockTrusted(status: StreamStatus): boolean {
  return status !== 'refused'
}

/** Whether a released horizontal drag commits the archive (PURE).
 *
 * Left-only by construction: a rightward drag has no verb behind it on either
 * shelf, so it must never commit — the sign test is the rule, not a detail of
 * the animation. */
export function swipeCommits(dx: number): boolean {
  return dx <= -SWIPE_COMMIT_PX
}

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

/** Where the open session goes when a session is archived (PURE, charter D28,
 * copied from Studio's kebab):
 *
 *   • archiving the session you are LOOKING AT pops you out — leaving you
 *     inside a session you just dismissed is the incoherent state;
 *   • archiving any OTHER session leaves you exactly where you are;
 *   • unarchive NEVER navigates, which is why it never calls this.
 *
 * Asymmetric on purpose: archive removes something from view (so the view must
 * cope), unarchive adds something back (so nothing needs to move). */
export function nextOpenAfterArchive(
  open: { id: string; title?: string } | undefined,
  archivedId: string,
): { id: string; title?: string } | undefined {
  if (open !== undefined && open.id === archivedId) return undefined
  return open
}

export function ChatScreen({
  connection,
  claim,
}: {
  connection: InstanceConnection
  /** The STORED config's claim about this connection — passed through to the
   * session screen's context band, which reconciles it against the connection
   * actually dialled. Threaded rather than read from storage here so the screen
   * stack stays free of IO and every arm is drivable from a fixture. */
  claim?: ConnectionClaim
}) {
  const theme = useTheme()
  const [state, setState] = useState<ListState>({ phase: 'loading' })
  const [attempt, setAttempt] = useState(0)
  const [shelf, setShelf] = useState<Shelf>('active')
  const [openSession, setOpenSession] = useState<{ id: string; title?: string } | undefined>(
    undefined,
  )
  // PERSISTENT across refreshes, shelf flips and session opens — the whole
  // point of connecting the reducer. herdSeed never regresses a live flip, so
  // a cold list landing after a flip cannot un-flip it.
  const [herd, setHerd] = useState<HerdState>(emptyHerd)
  // The stall clock. `nowMs` is state so a tick re-renders; the badge itself is
  // still computed fresh from lastFrameAtMs, never stored (D53h).
  const [nowMs, setNowMs] = useState(() => Date.now())
  // The fleet stream's OWN state (the D24 five-state vocabulary), which the
  // stall badge is only meaningful against — see stallClockTrusted.
  const [liveStatus, setLiveStatus] = useState<StreamStatus>('connecting')
  // A transient line for a REFUSED lifecycle write. Cleared when the user asks
  // for anything new (a fresh archive, a shelf flip, a refresh) — never by the
  // list load itself, since the failure path is what triggered that load.
  const [failureLine, setFailureLine] = useState<string | undefined>(undefined)

  useEffect(() => {
    const timer = setInterval(() => setNowMs(Date.now()), STALL_TICK_MS)
    return () => clearInterval(timer)
  }, [])

  useEffect(() => {
    let alive = true
    ;(async () => {
      try {
        const sessions = await listChatSessions(connection, shelf === 'archived')
        if (!alive) return
        setHerd((h) => herdSeed(h, sessions))
        setState({ phase: 'ready', sessions, refreshing: false, loadedAtMs: Date.now() })
      } catch {
        if (alive)
          setState({ phase: 'error', message: 'Could not load chat sessions from your Barkpark.' })
      }
    })()
    return () => {
      alive = false
    }
  }, [connection, shelf, attempt])

  // The ONE fleet stream (GET /v1/chat/events), held for the life of the tab —
  // never restarted on a shelf flip or a refresh, because the herd is the
  // whole fleet's truth and neither of those changes it. Frames that are not
  // herd-shaped are ignored by applyFleetFrame; a terminal refusal simply
  // stops the live layer and leaves the cold list fully usable.
  useEffect(() => {
    const controller = new AbortController()
    // The pump reports 'closed' AFTER the abort, so the status sink is fenced
    // the same way the list load is — a torn-down tab must not write state.
    let alive = true
    void streamFleetEvents(connection, {
      signal: controller.signal,
      // The pump has always emitted this vocabulary; the screen simply never
      // listened, which is what let a dead live layer masquerade as a silent
      // fleet. Nothing here restarts or retries — the transport owns the ladder;
      // this is only the truth the badge is read against.
      onStatus: (status) => {
        if (alive) setLiveStatus(status)
      },
      onFrame: (f) => {
        setHerd((h) => {
          const { state: next, ok } = applyFleetFrame(h, f.event, f.data)
          return ok ? next : h
        })
      },
    })
    return () => {
      alive = false
      controller.abort()
    }
  }, [connection])

  const retry = useCallback(() => {
    setFailureLine(undefined)
    setState({ phase: 'loading' })
    setAttempt((a) => a + 1)
  }, [])

  const refresh = useCallback(() => {
    setFailureLine(undefined)
    setState((prev) =>
      prev.phase === 'ready' ? { ...prev, refreshing: true } : { phase: 'loading' },
    )
    setAttempt((a) => a + 1)
  }, [])

  /** Drops a row from the shelf in view. The server emits NO fleet frame for an
   * archive flip (charter D28 — no broadcast path exists), so optimism is not a
   * latency trick here: it is the only removal signal that will ever arrive.
   * The next list poll reconciles. */
  const dropRow = useCallback((id: string) => {
    setState((prev) =>
      prev.phase === 'ready'
        ? { ...prev, sessions: prev.sessions.filter((s) => s.id !== id) }
        : prev,
    )
  }, [])

  const archive = useCallback(
    (id: string) => {
      setFailureLine(undefined)
      dropRow(id)
      setOpenSession((open) => nextOpenAfterArchive(open, id))
      archiveChatSession(connection, id).catch(() => {
        // The refused haptic is a NUDGE, not a message — a phone in a pocket or
        // on silent swallows it, and a row reappearing with no explanation reads
        // as a bug. So the failure is SAID as well as felt (TUI parity).
        haptic('refused')
        setFailureLine(lifecycleFailureLine('active'))
        // Put it back by re-reading the shelf — never by re-inserting a
        // guessed row at a guessed position.
        setAttempt((a) => a + 1)
      })
    },
    [connection, dropRow],
  )

  const unarchive = useCallback(
    (id: string) => {
      // Unarchive NEVER navigates (D28): the row leaves the archived shelf and
      // that is the whole of it.
      setFailureLine(undefined)
      dropRow(id)
      unarchiveChatSession(connection, id).catch(() => {
        haptic('refused')
        setFailureLine(lifecycleFailureLine('archived'))
        setAttempt((a) => a + 1)
      })
    },
    [connection, dropRow],
  )

  // The ported herd attention sort over the shelf's roster: order by rank /
  // freshest flip / id (deterministic — no jitter under refresh). `nowMs` is
  // the stall clock, so a session crossing 150s re-sorts itself.
  const ordered = useMemo(() => {
    if (state.phase !== 'ready') return []
    // The stall clock, switched OFF (0 — "no live clock") when the fleet stream
    // is refused. It feeds the SORT as well as the badge: promoting every
    // working row into the stalled band would be the same lie, just told
    // through the order instead of the label.
    const stallNowMs = stallClockTrusted(liveStatus) ? nowMs : 0
    const byId = new Map(state.sessions.map((s) => [s.id, s]))
    return herdOrder(
      herd,
      state.sessions.map((s) => s.id),
      stallNowMs,
    ).map((id) => ({
      session: byId.get(id) as ChatSessionSummary,
      stalled: herdStalled(herdRowFor(herd, id), stallNowMs),
      /** LIVE state wins over the list's point-in-time read — this is what the
       * fleet connection buys, and reading the summary here instead would make
       * the whole stream invisible. */
      agentState: herdRowFor(herd, id).agentState,
      /** Same law for the TITLE (D69h): the live `title` frame lands on the herd
       * row, so a session renamed elsewhere reads fresh here instead of wearing
       * the list read's stale title until the next refetch. */
      title: herdTitleFor(herd, id, byId.get(id)?.title),
    }))
  }, [state, herd, nowMs, liveStatus])

  if (openSession !== undefined) {
    return (
      <ChatSessionScreen
        connection={connection}
        claim={claim}
        sessionId={openSession.id}
        sessionTitle={openSession.title}
        onArchive={archive}
        onBack={() => {
          setOpenSession(undefined)
          refresh()
        }}
      />
    )
  }

  const shelfToggle = (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={shelf === 'active' ? 'Show archived sessions' : 'Show active sessions'}
      onPress={() => {
        setFailureLine(undefined)
        setState({ phase: 'loading' })
        setShelf((s) => (s === 'active' ? 'archived' : 'active'))
      }}
    >
      <Text style={[styles.link, { color: theme.accent }]}>
        {shelf === 'active' ? 'Archived' : 'Back to active'}
      </Text>
    </Pressable>
  )

  // The two honest transient lines, rendered wherever the list is: a refused
  // lifecycle write (danger — the user's action did not happen) and a refused
  // live layer (muted — the cold list is still entirely usable, only the live
  // flips are gone, which is exactly why the stall badges went with them).
  const transientLines =
    failureLine !== undefined || !stallClockTrusted(liveStatus) ? (
      <View style={styles.notices}>
        {failureLine !== undefined && (
          <Text style={[styles.notice, { color: theme.danger }]}>{failureLine}</Text>
        )}
        {!stallClockTrusted(liveStatus) && (
          <Text style={[styles.notice, { color: theme.textMuted }]}>
            Live updates are off — pull to refresh for the latest.
          </Text>
        )}
      </View>
    ) : null

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
        <Text style={[styles.body, { color: theme.text }]}>
          {shelf === 'active' ? 'No chat sessions yet.' : 'Nothing archived.'}
        </Text>
        <Text style={[styles.muted, { color: theme.textMuted }]}>
          {shelf === 'active'
            ? 'Sessions on this workspace show up here.'
            : 'Swipe a session left on the list to archive it.'}
        </Text>
        {transientLines}
        <Pressable accessibilityRole="button" onPress={retry}>
          <Text style={[styles.link, { color: theme.accent }]}>Refresh</Text>
        </Pressable>
        {shelfToggle}
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
        <RefreshControl refreshing={state.refreshing} onRefresh={refresh} tintColor={theme.accent} />
      }
      ListHeaderComponent={
        <View>
          <View style={styles.shelfBar}>
            <Text style={[styles.shelfTitle, { color: theme.text }]}>
              {shelf === 'active' ? 'Sessions' : 'Archived'}
            </Text>
            {shelfToggle}
          </View>
          {transientLines}
        </View>
      }
      ListFooterComponent={
        // The cap is honest or it is a lie: the server returns at most 50 rows
        // and has no pagination behind them, so a full shelf says so rather
        // than presenting a truncated list as the whole truth.
        ordered.length >= SHELF_CAP ? (
          <Text style={[styles.capNote, { color: theme.textMuted }]}>
            Showing the {SHELF_CAP} most recent — there is no older page.
          </Text>
        ) : null
      }
      renderItem={({ item }) => (
        <SwipeToArchive
          key={item.session.id}
          theme={theme}
          actionLabel={shelf === 'active' ? 'Archive' : 'Unarchive'}
          onCommit={() => (shelf === 'active' ? archive(item.session.id) : unarchive(item.session.id))}
        >
          <SessionRow
            session={item.session}
            agentState={item.agentState}
            title={item.title}
            stalled={item.stalled}
            nowMs={nowMs}
            theme={theme}
            onPress={() => setOpenSession({ id: item.session.id, title: item.title })}
          />
        </SwipeToArchive>
      )}
    />
  )
}

/** Swipe-left to archive, on RN core only.
 *
 * reanimated and gesture-handler are bill-REJECTED for this app, so this is
 * PanResponder + Animated and nothing else. The dismissal is a two-stage
 * animation — slide the row out, then collapse its measured height to zero —
 * rather than a LayoutAnimation.configureNext: under Fabric (newArchEnabled)
 * configureNext is a documented no-op on several paths, and a collapse that
 * silently does nothing would leave a hole in the list. Animating a MEASURED
 * height is dep-free, arch-independent, and cannot no-op.
 *
 * The responder only claims a gesture that is decisively horizontal, so a tap
 * still opens the session and a vertical drag still scrolls the list. */
export function SwipeToArchive({
  children,
  onCommit,
  actionLabel,
  theme,
}: {
  children: React.ReactNode
  onCommit: () => void
  actionLabel: string
  theme: Theme
}): React.ReactElement {
  // useState, not useRef: these are created-once values that render reads, and
  // a ref read during render is exactly what the hooks lint (rightly) rejects.
  const [dx] = useState(() => new Animated.Value(0))
  const [collapse] = useState(() => new Animated.Value(0))
  const [measured, setMeasured] = useState<number | undefined>(undefined)
  const [dismissing, setDismissing] = useState(false)

  const onLayout = useCallback((e: LayoutChangeEvent) => {
    const h = e.nativeEvent.layout.height
    // Latch the FIRST measurement: once the collapse starts, layout reports the
    // shrinking height, and adopting that would animate toward a moving target.
    setMeasured((prev) => (prev === undefined ? h : prev))
  }, [])

  // Rebuilt when its inputs change rather than pinned behind refs. The handlers
  // are read from props at dispatch time, so a rebuild mid-gesture hands the
  // gesture the NEWER closure — which is the one we want anyway.
  const responder = useMemo(
    () =>
      PanResponder.create({
        // Never claim on touch-down — that would eat the tap that opens a
        // session.
        onStartShouldSetPanResponder: () => false,
        onMoveShouldSetPanResponder: (_e, g) =>
          g.dx < -8 && Math.abs(g.dx) > Math.abs(g.dy) * 2,
        onPanResponderMove: (_e, g) => {
          // Left only: a rightward drag has no verb behind it, so it must not
          // move the row and pretend one exists.
          dx.setValue(Math.min(0, g.dx))
        },
        onPanResponderRelease: (_e, g) => {
          if (!swipeCommits(g.dx)) {
            Animated.spring(dx, { toValue: 0, useNativeDriver: true, bounciness: 0 }).start()
            return
          }
          // The dismissal-weight buzz (D43 archiveCommit) fires HERE — at the
          // release that decides the commit — and not from onCommit() below,
          // which the two-stage animation reaches 280ms later. A buzz that late
          // reads as the app confirming something back at you; the finger has
          // long since left the glass. Both shelves share this gesture (the
          // archived shelf's swipe is labelled Unarchive) and both are the same
          // felt moment: a row you swiped away, going away.
          haptic('archiveCommit')
          collapse.setValue(measured ?? 0)
          setDismissing(true)
          Animated.timing(dx, {
            toValue: -600,
            duration: 140,
            useNativeDriver: true,
          }).start(() => {
            Animated.timing(collapse, {
              toValue: 0,
              duration: 140,
              // Height is a layout prop — the native driver cannot carry it.
              useNativeDriver: false,
            }).start(() => onCommit())
          })
        },
        onPanResponderTerminate: () => {
          Animated.spring(dx, { toValue: 0, useNativeDriver: true, bounciness: 0 }).start()
        },
      }),
    [dx, collapse, measured, onCommit],
  )

  return (
    <Animated.View
      onLayout={onLayout}
      style={dismissing && measured !== undefined ? { height: collapse, overflow: 'hidden' } : null}
    >
      <View style={styles.swipeBack} pointerEvents="none">
        <Text style={[styles.swipeLabel, { color: theme.danger }]}>{actionLabel}</Text>
      </View>
      <Animated.View style={{ transform: [{ translateX: dx }] }} {...responder.panHandlers}>
        {children}
      </Animated.View>
    </Animated.View>
  )
}

/** The pill's copy law: the wire word is "blocked" and the screen NEVER prints
 * it — a session waiting on a human "needs you". The wire keeps the word (three
 * clients, the chat_blocked webhook family and BlockedSweeper all speak it);
 * only the rendering is translated. */
export function stateColors(theme: Theme, agentState: string): { fg: string; label: string } {
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
  agentState,
  title,
  stalled,
  nowMs,
  theme,
  onPress,
}: {
  session: ChatSessionSummary
  /** The HERD's state, not the summary's — the live flip is the fresher fact. */
  agentState: string
  /** The HERD's title (herdTitleFor), not the summary's — same law, D69h. */
  title: string
  stalled: boolean
  nowMs: number
  theme: Theme
  onPress: () => void
}) {
  const pill = stateColors(theme, agentState)
  const pending = session.pending_approvals ?? 0
  return (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
      style={[styles.row, { backgroundColor: theme.bg }]}
    >
      <View style={styles.rowTop}>
        <Text numberOfLines={2} style={[styles.title, { color: theme.text }]}>
          {title !== '' ? title : session.id}
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
  shelfBar: {
    flexDirection: 'row',
    alignItems: 'baseline',
    justifyContent: 'space-between',
    paddingBottom: 6,
  },
  shelfTitle: { ...roles.sectionTitle, fontWeight: '700' },
  notices: { gap: 3, paddingBottom: 8 },
  notice: { ...scale.xs, fontWeight: '600' },
  capNote: { ...scale.xs, paddingTop: 14, paddingBottom: 4 },
  // Borderless rows on the background — whitespace separates sessions, the
  // way the ChatGPT/Claude session lists do it.
  row: { paddingVertical: 14, gap: 5 },
  // The archive affordance sits BEHIND the row and is revealed by the slide,
  // so it costs no layout of its own.
  swipeBack: {
    position: 'absolute',
    top: 0,
    right: 0,
    bottom: 0,
    left: 0,
    alignItems: 'flex-end',
    justifyContent: 'center',
  },
  swipeLabel: { ...scale.sm, fontWeight: '700', letterSpacing: 0.4 },
  rowTop: { flexDirection: 'row', alignItems: 'flex-start', gap: 8 },
  title: { flex: 1, ...scale.lg, fontWeight: '600' },
  pendingBadge: {
    minWidth: 20,
    height: 20,
    borderRadius: 10,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 5,
  },
  pendingText: { ...scale.micro, color: '#ffffff', fontWeight: '700' },
  rowMeta: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  stateLabel: { ...scale.xs, fontWeight: '600' },
  metaText: { ...scale.xs },
  summary: { ...scale.base },
  body: { ...scale.md, textAlign: 'center' },
  muted: { ...scale.sm, textAlign: 'center' },
  link: { ...scale.base, textDecorationLine: 'underline' },
})
