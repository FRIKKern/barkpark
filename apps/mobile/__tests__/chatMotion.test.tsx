// The motion layer (t3w2-s4): follow mode, the turn-scoped work log, the
// notify coalescer, and the memo that makes a streaming transcript cheap.
//
// FIVE law families are pinned here, each because a plausible future edit
// breaks it SILENTLY — the suite is the only thing that would notice:
//
//   1. FOLLOW IS THE USER'S. Scrolling up disengages; returning re-engages;
//      send and the pill are the ONLY things that scroll the transcript. The
//      removed behaviour (a 50 ms timer + onContentSizeChange yanking to the
//      end unconditionally) left no trace a type error would catch.
//   2. THE FOLD RUNS ON THE D77 CLOCK. A work-log group folds because `gen`
//      advanced, not because a second turn-boundary detector was invented.
//      reducer.ts is a read-only source here and its diff is empty.
//   3. THE COALESCER BATCHES ONLY TAIL GROWTH — and it is pinned through the
//      REAL store, driving real SSE frames into the real set()/notify seam,
//      because a pure-helper-only pin would stay green if the store stopped
//      calling it.
//   4. THE MEMO IS NOT DECORATION. memo(TranscriptRow) only pays if a settled
//      row's props survive a tail tick by IDENTITY — so the row-identity law
//      and the comparator are pinned together, and the render decision is
//      counted over a real tail tick.
//   5. THE BUBBLE LAW AT ROW LEVEL (#6126). The existing pins sit on
//      bodyRender, one level BELOW where a regression would land: a row that
//      resolves to text and then renders blocks anyway would pass those. This
//      walks the rendered `user` row itself.
import type { ReactElement, ReactNode } from 'react'

import { getChatSession, streamChatEvents, type ChatStreamOptions } from '../src/api/chat'
import type { InstanceConnection } from '../src/api/instance'
import {
  contentMark,
  distanceFromEnd,
  FOLLOW_THRESHOLD,
  initialFollowState,
  nearEnd,
  reduceFollow,
  showJumpPill,
} from '../src/chat/followScroll'
import {
  ChatSessionStore,
  createNotifyCoalescer,
  tailOnlyGrowth,
} from '../src/chat/sessionStore'
import { initialChatState, type ChatState } from '../src/chat/reducer'
import {
  foldWorkLog,
  initialWorkLogFold,
  isWorkLogRole,
  observeGroups,
  toggleWorkLog,
  workLogExpanded,
  workLogGroups,
  workLogSummary,
  WORK_LOG_ROLES,
  type WorkLogRow,
} from '../src/chat/workLog'
import type { ChatMessage, ChatSession } from '../src/chat/wire'
import {
  assembleRows,
  chatBlockCtx,
  TRANSCRIPT_FOLLOW,
  localRows,
  messageRows,
  MemoTranscriptRow,
  rowRole,
  TranscriptRow,
  transcriptItem,
  transcriptRowPropsEqual,
  workLogRows,
  type Row,
  type RowCtx,
  type TranscriptRowProps,
} from '../src/screens/ChatSessionScreen'
import { light, type Theme } from '../src/ui/theme'

// (hoisted by jest above the imports)
jest.mock('../src/api/chat', () => ({
  getChatSession: jest.fn(),
  sendChatMessage: jest.fn(),
  interruptChat: jest.fn(),
  respondChatApproval: jest.fn(),
  streamChatEvents: jest.fn(),
}))
// The transcript reaches MermaidIsland → react-native-webview, a native
// TurboModule with no jest mock of its own (the same null stub the sibling
// suites use — nothing here renders a diagram).
jest.mock('react-native-webview', () => ({ WebView: () => null }))
// Haptics are garnish; this suite asserts WHICH registry event fires, never
// the engine.
jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(() => Promise.resolve()),
  notificationAsync: jest.fn(() => Promise.resolve()),
  selectionAsync: jest.fn(() => Promise.resolve()),
  ImpactFeedbackStyle: { Light: 'light', Medium: 'medium', Heavy: 'heavy' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning', Error: 'error' },
}))

const theme: Theme = light

/* ── 1. follow mode ─────────────────────────────────────────────────────────── */

const VIEWPORT = 800
const band = VIEWPORT * FOLLOW_THRESHOLD // 80px — the engage/disengage band

describe('follow mode is a state the user owns', () => {
  it('nearEnd is the threshold band, and pre-layout counts as AT the end', () => {
    expect(nearEnd(0, VIEWPORT)).toBe(true)
    expect(nearEnd(band, VIEWPORT)).toBe(true) // inclusive — the boundary follows
    expect(nearEnd(band + 1, VIEWPORT)).toBe(false)
    // A viewport that has not measured itself is booting pinned; treating it
    // as disengaged would raise the pill over an empty transcript.
    expect(nearEnd(999, 0)).toBe(true)
  })

  it('the band is LegendList’s own default — one constant, two consumers', () => {
    // If these ever diverge the pill offers a jump the list has already made.
    expect(FOLLOW_THRESHOLD).toBe(0.1)
  })

  it('the list follows on ALL triggers — an explicit `on` would DISABLE footerLayout', () => {
    expect(TRANSCRIPT_FOLLOW).toEqual({ animated: true })
    // The absence is the law: LegendList reads an omitted `on` as every
    // trigger and a present one as an opt-in list, so adding the key that
    // *looks* more explicit silently drops the late-measurement re-pin.
    expect(Object.keys(TRANSCRIPT_FOLLOW)).not.toContain('on')
  })

  it('scrolling up disengages and returning to the bottom re-engages', () => {
    const up = reduceFollow(initialFollowState, {
      type: 'scrolled',
      distanceFromEnd: 600,
      viewportHeight: VIEWPORT,
      mark: '3:10',
    })
    expect(up.following).toBe(false)
    expect(up.mark).toBe('3:10') // frozen at the moment follow was lost

    const back = reduceFollow(up, {
      type: 'scrolled',
      distanceFromEnd: 12,
      viewportHeight: VIEWPORT,
      mark: '9:400',
    })
    expect(back).toEqual(initialFollowState)
  })

  it('the pill appears ONLY when disengaged AND content arrived since', () => {
    const reading = reduceFollow(initialFollowState, {
      type: 'scrolled',
      distanceFromEnd: 600,
      viewportHeight: VIEWPORT,
      mark: contentMark(4, 0),
    })
    // Scrolled up into a QUIET transcript — reading must not be nagged.
    expect(showJumpPill(reading, contentMark(4, 0))).toBe(false)
    // …a token lands below…
    expect(showJumpPill(reading, contentMark(4, 12))).toBe(true)
    // …and a whole new row does too.
    expect(showJumpPill(reading, contentMark(5, 0))).toBe(true)
    // While FOLLOWING there is never a pill, whatever the mark says.
    expect(showJumpPill(initialFollowState, contentMark(99, 99))).toBe(false)
  })

  it('send and the pill both re-follow', () => {
    const away = reduceFollow(initialFollowState, {
      type: 'scrolled',
      distanceFromEnd: 900,
      viewportHeight: VIEWPORT,
      mark: '1:0',
    })
    expect(reduceFollow(away, { type: 'sent' })).toEqual(initialFollowState)
    expect(reduceFollow(away, { type: 'jumped' })).toEqual(initialFollowState)
  })

  it('returns the SAME object when nothing changed — the memo depends on it', () => {
    const same = reduceFollow(initialFollowState, {
      type: 'scrolled',
      distanceFromEnd: 4,
      viewportHeight: VIEWPORT,
      mark: '2:0',
    })
    expect(same).toBe(initialFollowState)
    expect(reduceFollow(initialFollowState, { type: 'sent' })).toBe(initialFollowState)
  })

  it('overscroll rubber-band reads as AT the end, never as a jump', () => {
    // iOS reports a negative remainder while bouncing past the bottom.
    expect(distanceFromEnd({ contentHeight: 1000, offsetY: 260, viewportHeight: VIEWPORT })).toBe(0)
    expect(distanceFromEnd({ contentHeight: 2000, offsetY: 200, viewportHeight: VIEWPORT })).toBe(1000)
  })
})

/* ── 2. the turn-scoped work log, folded on the D77 clock ───────────────────── */

const wl = (key: string, role: string): WorkLogRow => ({ key, role })

describe('work-log grouping', () => {
  it('groups exactly the three apparatus roles', () => {
    expect([...WORK_LOG_ROLES].sort()).toEqual(['thinking', 'todo', 'tool'])
    for (const role of WORK_LOG_ROLES) expect(isWorkLogRole(role)).toBe(true)
    // user/assistant delimit turns; the cards stay first-class no matter how
    // old — an approval hidden behind a disclosure is one that never comes.
    for (const role of ['user', 'assistant', 'approval', 'question', 'plan', 'system'])
      expect(isWorkLogRole(role)).toBe(false)
  })

  it('only CONSECUTIVE apparatus rows group — an assistant turn separates two stretches', () => {
    const groups = workLogGroups([
      wl('m-1', 'user'),
      wl('m-2', 'tool'),
      wl('m-3', 'thinking'),
      wl('m-4', 'assistant'),
      wl('m-5', 'tool'),
      wl('m-6', 'todo'),
    ])
    expect(groups.map((g) => g.key)).toEqual(['m-2', 'm-5'])
    expect(groups[0]!.members).toEqual(['m-2', 'm-3'])
    expect(groups[1]!.members).toEqual(['m-5', 'm-6'])
    expect(groups[1]!.roles).toEqual(['tool', 'todo'])
  })

  it('a transcript with no apparatus has no groups at all', () => {
    expect(workLogGroups([wl('m-1', 'user'), wl('m-2', 'assistant')])).toEqual([])
  })

  it('the summary counts, and claims nothing else', () => {
    expect(workLogSummary({ key: 'a', members: ['a'], roles: ['tool'] })).toBe('1 step')
    expect(workLogSummary({ key: 'a', members: ['a', 'b', 'c'], roles: [] })).toBe('3 steps')
  })
})

describe('the fold runs on the D77 gen clock', () => {
  const rows = [wl('m-1', 'user'), wl('m-2', 'tool'), wl('m-3', 'todo')]
  const groups = workLogGroups(rows)

  it('the turn in flight is OPEN; the clock advancing folds it', () => {
    const fold = observeGroups(initialWorkLogFold, groups, 7)
    expect(fold.born['m-2']).toBe(7)
    // gen 7 — the turn that produced this work is still running.
    expect(workLogExpanded(fold, 'm-2', 7)).toBe(true)
    // gen 8 — a system/init frame advanced the FENCE's own generation, and the
    // fold rode it. No second turn-boundary detector exists.
    expect(workLogExpanded(fold, 'm-2', 8)).toBe(false)
  })

  it('an unobserved group reads as live — it can only have appeared under this clock', () => {
    expect(workLogExpanded(initialWorkLogFold, 'brand-new', 3)).toBe(true)
  })

  it('a hand beats the clock, permanently', () => {
    const born = observeGroups(initialWorkLogFold, groups, 7)
    // Someone opens a folded log at gen 9 to read it…
    const opened = toggleWorkLog(born, 'm-2', 9)
    expect(workLogExpanded(opened, 'm-2', 9)).toBe(true)
    // …and the next three turns must not slam it shut.
    expect(workLogExpanded(opened, 'm-2', 12)).toBe(true)
    // Collapsing a LIVE group also sticks (the toggle records the opposite of
    // what is shown, so the control always does something on first press).
    const shut = toggleWorkLog(born, 'm-2', 7)
    expect(workLogExpanded(shut, 'm-2', 7)).toBe(false)
  })

  it('the birth gen must be PERSISTED — a fold re-derived each render never folds', () => {
    // The live bug this caught, stated as a law. Feeding observeGroups its own
    // stored output (what the screen does with setFold) keeps the birth gen…
    let stored = observeGroups(initialWorkLogFold, groups, 3)
    stored = observeGroups(stored, groups, 4) // the clock advanced; the birth did not
    expect(stored.born['m-2']).toBe(3)
    expect(workLogExpanded(stored, 'm-2', 4)).toBe(false)

    // …whereas re-deriving from the INITIAL fold every render re-stamps the
    // group with the CURRENT gen, so its birth chases the clock and the work
    // log stays open forever.
    const rederived = observeGroups(initialWorkLogFold, groups, 4)
    expect(rederived.born['m-2']).toBe(4)
    expect(workLogExpanded(rederived, 'm-2', 4)).toBe(true)
  })

  it('the disclosure needs only the PERSISTED fold — never the per-tick group array', () => {
    const stored = observeGroups(initialWorkLogFold, groups, 3)
    // Re-observing before toggling changes nothing, because the birth is
    // already stored. THAT is what lets the screen's toggle handler drop
    // `groups` from its dependencies — groups is re-derived on every token
    // frame, and a handler that changed with it would re-mint every row's
    // props through rowCtx and make memo(TranscriptRow) inert all over again.
    expect(toggleWorkLog(stored, 'm-2', 4)).toEqual(
      toggleWorkLog(observeGroups(stored, groups, 4), 'm-2', 4),
    )
  })

  it('observeGroups keeps the birth gen of a group that GREW mid-turn', () => {
    const first = observeGroups(initialWorkLogFold, groups, 4)
    const grown = workLogGroups([...rows, wl('m-4', 'tool')])
    const second = observeGroups(first, grown, 5)
    // Same head key, so the run is the same run — its birth gen is untouched.
    expect(second.born['m-2']).toBe(4)
    expect(second).toBe(first) // nothing new to stamp → same object
  })
})

describe('foldWorkLog presentation order', () => {
  const rows = [wl('m-1', 'user'), wl('m-2', 'tool'), wl('m-3', 'todo'), wl('m-4', 'assistant')]
  const groups = workLogGroups(rows)
  const header = (g: { key: string }): WorkLogRow => ({ key: `log-${g.key}`, role: 'log' })

  it('a FOLDED group leaves exactly its header behind', () => {
    const out = foldWorkLog(rows, groups, (r) => r.key, () => false, header)
    expect(out.map((r) => r.key)).toEqual(['m-1', 'log-m-2', 'm-4'])
  })

  it('an OPEN group shows its header AND its members, in order', () => {
    const out = foldWorkLog(rows, groups, (r) => r.key, () => true, header)
    expect(out.map((r) => r.key)).toEqual(['m-1', 'log-m-2', 'm-2', 'm-3', 'm-4'])
  })

  it('rows outside every group pass through untouched, by reference', () => {
    const out = foldWorkLog(rows, groups, (r) => r.key, () => false, header)
    expect(out[0]).toBe(rows[0])
    expect(out[2]).toBe(rows[3])
  })
})

/* ── 3. the notify coalescer, through the REAL store ────────────────────────── */

const conn: InstanceConnection = {
  projectUrl: 'https://bp.example',
  token: 'tkn',
  dataset: 'production',
}

const delta = (text: string): string =>
  JSON.stringify({
    type: 'stream_event',
    event: { type: 'content_block_delta', delta: { type: 'text_delta', text } },
  })

const flushMicro = async () => {
  for (let i = 0; i < 10; i++) await Promise.resolve()
}

describe('createNotifyCoalescer', () => {
  it('N schedules in one tick collapse to ONE notify', () => {
    const queue: (() => void)[] = []
    const notify = jest.fn()
    const c = createNotifyCoalescer(notify, (run) => queue.push(run))
    for (let i = 0; i < 20; i++) c.schedule()
    expect(notify).not.toHaveBeenCalled()
    expect(queue).toHaveLength(1) // one deferral, not twenty
    queue.forEach((run) => run())
    expect(notify).toHaveBeenCalledTimes(1)
  })

  it('flush() announces NOW and swallows the coalesced one — never a duplicate', () => {
    const queue: (() => void)[] = []
    const notify = jest.fn()
    const c = createNotifyCoalescer(notify, (run) => queue.push(run))
    c.schedule()
    c.flush()
    expect(notify).toHaveBeenCalledTimes(1)
    queue.forEach((run) => run())
    expect(notify).toHaveBeenCalledTimes(1) // the pending one found nothing to say
  })

  it('cancel() drops a pending notify without announcing', () => {
    const queue: (() => void)[] = []
    const notify = jest.fn()
    const c = createNotifyCoalescer(notify, (run) => queue.push(run))
    c.schedule()
    c.cancel()
    queue.forEach((run) => run())
    expect(notify).not.toHaveBeenCalled()
  })
})

describe('tailOnlyGrowth — the ONE delta safe to batch', () => {
  const base: ChatState = initialChatState('s1')

  it('is true for pure tail growth', () => {
    expect(tailOnlyGrowth(base, { ...base, tail: 'hel' })).toBe(true)
  })

  it('is false when ANY other field moved — it fails toward MORE notifies', () => {
    const moves: Partial<ChatState>[] = [
      { phase: 'streaming' },
      { gen: 1 },
      { tailGen: 1 },
      { settling: true },
      { notice: 'x' },
      { exited: true },
      { lastSeq: 4 },
      { title: 'named' },
      { mode: 'plan' },
      { model: 'sonnet' },
      { wedgeAtMs: 5 },
      { messages: [] as ChatMessage[] }, // a NEW array, same contents
      { local: [] },
      { answerInFlight: {} },
    ]
    for (const move of moves) {
      expect(tailOnlyGrowth(base, { ...base, tail: 'hel', ...move })).toBe(false)
    }
  })

  it('is false when the tail did not grow at all', () => {
    expect(tailOnlyGrowth(base, base)).toBe(false)
    expect(tailOnlyGrowth(base, { ...base, notice: 'x' })).toBe(false)
  })
})

test('the STORE batches a burst of token frames into one notify (the real set/notify seam)', async () => {
  const mockGet = getChatSession as jest.Mock
  const mockStream = streamChatEvents as jest.Mock
  mockGet.mockReset()
  mockStream.mockReset()
  mockGet.mockResolvedValue({ id: 's1', title: 'A session', messages: [] } as ChatSession)

  let onFrame: ((f: { event: string; data: string }) => void) | undefined
  mockStream.mockImplementation((_c: unknown, _id: unknown, opts: ChatStreamOptions) => {
    onFrame = opts.onFrame
    return new Promise(() => {})
  })

  const queue: (() => void)[] = []
  const store = new ChatSessionStore(conn, 's1', (run) => queue.push(run))
  store.start()
  await flushMicro()

  const notified = jest.fn()
  store.subscribe(notified)
  queue.length = 0

  // stop() in a finally: the store owns a real setInterval, so a failing
  // expectation must not strand it and hang the whole run on an open handle.
  try {
    // Ten token frames land in one tick. The FIRST also flips phase idle →
    // streaming, which is not tail-only, so it flushes immediately and
    // honestly; the nine that follow are pure tail growth and collapse into one.
    for (let i = 0; i < 10; i++) onFrame!({ event: 'chat', data: delta('x') })
    expect(notified).toHaveBeenCalledTimes(1)
    expect(queue).toHaveLength(1)
    queue.forEach((run) => run())
    expect(notified).toHaveBeenCalledTimes(2)

    // The state itself is NOT batched — every frame ran through reduce(), so
    // the D77 fence saw the full sequence and the tail carries all ten chars.
    expect(store.getSnapshot().state.tail).toBe('xxxxxxxxxx')
  } finally {
    store.stop()
  }
})

test('a non-delta frame flushes immediately — the moments the user waits on are never deferred', async () => {
  const mockGet = getChatSession as jest.Mock
  const mockStream = streamChatEvents as jest.Mock
  mockGet.mockReset()
  mockStream.mockReset()
  mockGet.mockResolvedValue({ id: 's1', messages: [] } as ChatSession)

  let onFrame: ((f: { event: string; data: string }) => void) | undefined
  mockStream.mockImplementation((_c: unknown, _id: unknown, opts: ChatStreamOptions) => {
    onFrame = opts.onFrame
    return new Promise(() => {})
  })

  const queue: (() => void)[] = []
  const store = new ChatSessionStore(conn, 's1', (run) => queue.push(run))
  store.start()
  await flushMicro()

  const notified = jest.fn()
  store.subscribe(notified)
  queue.length = 0

  try {
    onFrame!({ event: 'chat', data: JSON.stringify({ type: 'system', subtype: 'init' }) })
    expect(notified).toHaveBeenCalledTimes(1) // synchronous — nothing deferred
    expect(queue).toHaveLength(0)
    expect(store.getSnapshot().state.gen).toBe(1)
  } finally {
    store.stop()
  }
})

/* ── 4. the memo, and the row identity that makes it real ───────────────────── */

const msg = (seq: number, role: string, extra: Partial<ChatMessage> = {}): ChatMessage => ({
  seq,
  role,
  source_markdown: `row ${seq}`,
  ...extra,
})

const ctx: RowCtx = {
  theme,
  blockCtx: chatBlockCtx(theme),
  inFlight: {},
  onAnswer: () => {},
  onToggleLog: () => {},
}

const props = (row: Row, over: Partial<RowCtx> = {}): TranscriptRowProps => ({
  row,
  ...ctx,
  ...over,
})

/** What React does with a memo: render only when the comparator says the props
 * are NOT equal. Counting this over a real tail tick IS the render count. */
function wouldRender(prev: TranscriptRowProps, next: TranscriptRowProps): boolean {
  return !transcriptRowPropsEqual(prev, next)
}

describe('memo(TranscriptRow) is not decoration', () => {
  const messages = [msg(1, 'user'), msg(2, 'assistant'), msg(3, 'tool')]

  it('a tail tick mints exactly ONE new row — every settled row keeps its identity', () => {
    // The screen memoizes these two halves on state.messages / state.local,
    // which a delta frame never re-mints (reducer.ts spreads the state, not
    // the arrays). assembleRows is where that survives into the list.
    const settled = messageRows(messages)
    const echoes = localRows([])
    const before = assembleRows(settled, echoes, 'hel')
    const after = assembleRows(settled, echoes, 'hell')

    for (let i = 0; i < settled.length; i++) expect(after[i]).toBe(before[i])
    expect(after[settled.length]).not.toBe(before[settled.length]) // the tail row IS new
  })

  it('render count over a tail tick: ZERO settled rows, one tail row', () => {
    const settled = messageRows(messages)
    const before = assembleRows(settled, [], 'hel')
    const after = assembleRows(settled, [], 'hell')

    const rendered = after.filter((row, i) => wouldRender(props(before[i]!), props(row)))
    expect(rendered).toHaveLength(1)
    expect(rendered[0]!.kind).toBe('tail')
  })

  it('the SAME transcript rebuilt from a new messages array re-renders everything', () => {
    // The mutant this kills: collapsing the three memos back into one keyed on
    // state.tail. Identical CONTENT is not identical identity, and the memo
    // reads identity — so the collapsed version renders every row, every frame.
    const before = assembleRows(messageRows(messages), [], 'hel')
    const after = assembleRows(messageRows(messages), [], 'hell')
    const rendered = after.filter((row, i) => wouldRender(props(before[i]!), props(row)))
    expect(rendered).toHaveLength(after.length)
  })

  it('the comparator is identity over EVERY prop — none may be dropped', () => {
    const row = messageRows(messages)[0]!
    const same = props(row)
    expect(transcriptRowPropsEqual(same, props(row))).toBe(true)

    expect(transcriptRowPropsEqual(same, props(messageRows(messages)[0]!))).toBe(false)
    expect(transcriptRowPropsEqual(same, props(row, { theme: { ...theme } }))).toBe(false)
    expect(transcriptRowPropsEqual(same, props(row, { blockCtx: chatBlockCtx(theme) }))).toBe(false)
    expect(transcriptRowPropsEqual(same, props(row, { inFlight: {} }))).toBe(false)
    expect(transcriptRowPropsEqual(same, props(row, { onAnswer: () => {} }))).toBe(false)
    expect(transcriptRowPropsEqual(same, props(row, { onToggleLog: () => {} }))).toBe(false)
  })

  it('the LIST renders through the memo — not the raw function', () => {
    // Reachability: this is the seam the screen’s renderItem calls, so an
    // edit that drops memo() (or re-inlines an arrow closure) reds here rather
    // than passing silently as a performance regression nobody measures.
    const item = transcriptItem(messageRows(messages)[0]!, ctx)
    expect(item.type).toBe(MemoTranscriptRow)
    expect((item.props as TranscriptRowProps).onToggleLog).toBe(ctx.onToggleLog)
    // React stores the comparator on the memo object; the public type does not
    // surface it, so the cast is the only way to assert the memo is EXPLICIT
    // rather than falling back to a shallow compare that would silently start
    // re-rendering the moment a prop shape changed.
    expect((MemoTranscriptRow as unknown as { compare: unknown }).compare).toBe(
      transcriptRowPropsEqual,
    )
  })
})

/* ── 5. row rendering: the bubble law at ROW level, and the log handle ──────── */

interface Walk {
  text: string
  styles: Record<string, unknown>[]
  presses: (() => void)[]
  labels: string[]
}

function isElement(node: unknown): node is ReactElement {
  return (
    !!node && typeof node === 'object' && 'props' in (node as object) && '$$typeof' in (node as object)
  )
}

function walkNode(node: ReactNode, acc: Walk): void {
  if (node === null || node === undefined || typeof node === 'boolean') return
  if (typeof node === 'string' || typeof node === 'number') {
    acc.text += String(node)
    return
  }
  if (Array.isArray(node)) {
    for (const child of node) walkNode(child as ReactNode, acc)
    return
  }
  if (!isElement(node)) return
  const p = node.props as Record<string, unknown>
  if (typeof p.onPress === 'function') acc.presses.push(p.onPress as () => void)
  if (typeof p.accessibilityLabel === 'string') acc.labels.push(p.accessibilityLabel)
  if (p.style !== undefined) {
    const parts = Array.isArray(p.style) ? p.style : [p.style]
    acc.styles.push(Object.assign({}, ...parts.filter((x) => !!x)) as Record<string, unknown>)
  }
  walkNode(p.children as ReactNode, acc)
}

function walk(node: ReactNode): Walk {
  const acc: Walk = { text: '', styles: [], presses: [], labels: [] }
  walkNode(node, acc)
  return acc
}

const toolBlock = [{ type: 'chat-tool-diff', lines: [{ op: '+', text: 'LEAKED_BLOCK' }], added: 1 }]

describe('the #6126 bubble law, pinned at ROW level', () => {
  it('a user row carrying blocks renders the BUBBLE and never the blocks', () => {
    const row: Row = {
      key: 'm-1',
      kind: 'message',
      message: msg(1, 'user', { blocks: toolBlock, source_markdown: 'what I typed' }),
    }
    const w = walk(TranscriptRow(props(row)))

    // The bubble is the STRUCTURE, not just the decision one level down: the
    // existing bodyRender pins would stay green if the row rendered blocks
    // anyway, which is precisely where a regression would land.
    expect(w.styles.some((s) => s.backgroundColor === theme.bubble)).toBe(true)
    expect(w.text).toBe('what I typed')
    expect(w.text).not.toContain('LEAKED_BLOCK')
  })

  it('a local echo takes the same bubble — the user’s own words, plain', () => {
    const w = walk(TranscriptRow(props({ key: 'l-0', kind: 'local', content: '**mine**', queued: true })))
    expect(w.styles.some((s) => s.backgroundColor === theme.bubble)).toBe(true)
    expect(w.text).toContain('**mine**') // never parsed as markup
  })

  it('an ASSISTANT row is unbubbled — the bubble is the user’s alone', () => {
    const row: Row = { key: 'm-2', kind: 'message', message: msg(2, 'assistant') }
    const w = walk(TranscriptRow(props(row)))
    expect(w.styles.some((s) => s.backgroundColor === theme.bubble)).toBe(false)
  })
})

describe('the work-log disclosure row', () => {
  const group = { key: 'm-2', members: ['m-2', 'm-3', 'm-4'], roles: ['tool', 'todo', 'thinking'] }

  it('folded: one honest handle carrying the count', () => {
    const w = walk(TranscriptRow(props({ key: 'log-m-2', kind: 'log', group, open: false })))
    expect(w.text).toBe('▸ 3 steps')
    expect(w.labels[0]).toContain('Show')
  })

  it('open: the chevron turns, and the label says what the tap does', () => {
    const w = walk(TranscriptRow(props({ key: 'log-m-2', kind: 'log', group, open: true })))
    expect(w.text).toBe('▾ 3 steps')
    expect(w.labels[0]).toContain('Hide')
  })

  it('the tap reaches the fold with the GROUP key, not the row key', () => {
    const toggled: string[] = []
    const w = walk(
      TranscriptRow(
        props({ key: 'log-m-2', kind: 'log', group, open: false }, { onToggleLog: (k) => toggled.push(k) }),
      ),
    )
    expect(w.presses).toHaveLength(1)
    w.presses[0]!()
    // The row key is `log-m-2`; the FOLD is keyed on the group's own head.
    expect(toggled).toEqual(['m-2'])
  })
})

describe('rowRole — what the fold sees', () => {
  it('reads the message role, and names the synthetic rows honestly', () => {
    expect(rowRole({ key: 'm-1', kind: 'message', message: msg(1, 'tool') })).toBe('tool')
    expect(rowRole({ key: 'l-0', kind: 'local', content: 'x', queued: false })).toBe('user')
    expect(rowRole({ key: 'tail', kind: 'tail', text: 'x' })).toBe('assistant')
    // The header is chrome: it belongs to no role, so it can never fold into a
    // group of its own on a second pass.
    expect(
      rowRole({ key: 'log-m-2', kind: 'log', group: { key: 'm-2', members: [], roles: [] }, open: true }),
    ).toBe('log')
  })

  it('the streaming tail never folds into the work log — it IS the answer', () => {
    const rows: Row[] = assembleRows(messageRows([msg(1, 'tool'), msg(2, 'tool')]), [], 'forming…')
    const groups = workLogGroups(workLogRows(rows))
    expect(groups).toHaveLength(1)
    expect(groups[0]!.members).toEqual(['m-1', 'm-2'])
    expect(groups[0]!.members).not.toContain('tail')
  })
})
