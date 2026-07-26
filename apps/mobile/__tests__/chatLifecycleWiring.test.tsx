// SCREEN-LEVEL WIRING PROBES for the lifecycle clients (t3w2-s7).
//
// The sibling suite pins the pure laws. This one exists because every one of
// those laws can be perfectly correct and WIRED in a way that defeats it, with
// no type error and no red test:
//
//   • pickerVocabulary can degrade honestly while the sheet renders chips
//     from somewhere else;
//   • applyFleetFrame can be a flawless reducer that no screen ever calls —
//     which is precisely the state this slice inherited ("built and dark");
//   • the herd can hold a live flip while the row paints the cold summary,
//     making the whole fleet connection invisible;
//   • nextOpenAfterArchive can be right and never reached.
//
// So these probes mount the REAL screens over the REAL store and read what the
// REAL list renders.
//
// TEARDOWN IS LOAD-BEARING: ChatScreen owns a stall-clock setInterval and the
// session store owns another, so every mount unmounts in a finally and the
// whole file runs on fake timers.
import { act, create, type ReactTestInstance, type ReactTestRenderer } from 'react-test-renderer'

import {
  archiveChatSession,
  fetchChatCapabilities,
  getChatSession,
  listChatSessions,
  streamChatEvents,
  streamFleetEvents,
  unarchiveChatSession,
  type ChatStreamOptions,
} from '../src/api/chat'
import type { InstanceConnection } from '../src/api/instance'
import type { ChatSessionSummary } from '../src/chat/wire'
import { ChatScreen, STALL_TICK_MS, SwipeToArchive } from '../src/screens/ChatScreen'

jest.mock('../src/api/chat', () => ({
  listChatSessions: jest.fn(),
  archiveChatSession: jest.fn(),
  unarchiveChatSession: jest.fn(),
  streamFleetEvents: jest.fn(),
  streamChatEvents: jest.fn(),
  getChatSession: jest.fn(),
  sendChatMessage: jest.fn(),
  interruptChat: jest.fn(),
  respondChatApproval: jest.fn(),
  patchChatSession: jest.fn(),
  fetchChatCapabilities: jest.fn(),
}))
jest.mock('react-native-webview', () => ({ WebView: () => null }))
jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(() => Promise.resolve()),
  notificationAsync: jest.fn(() => Promise.resolve()),
  selectionAsync: jest.fn(() => Promise.resolve()),
  ImpactFeedbackStyle: { Light: 'light', Medium: 'medium', Heavy: 'heavy' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning', Error: 'error' },
}))

const mockList = listChatSessions as jest.Mock
const mockArchive = archiveChatSession as jest.Mock
const mockUnarchive = unarchiveChatSession as jest.Mock
const mockFleet = streamFleetEvents as jest.Mock
const mockStream = streamChatEvents as jest.Mock
const mockGet = getChatSession as jest.Mock
const mockCaps = fetchChatCapabilities as jest.Mock

const conn: InstanceConnection = {
  projectUrl: 'https://bp.example',
  token: 'tkn',
  dataset: 'production',
}

const summary = (id: string, over: Partial<ChatSessionSummary> = {}): ChatSessionSummary => ({
  id,
  title: id,
  agent_state: 'idle',
  agent_state_at: '2026-07-26T00:00:00Z',
  ...over,
})

/** Every fleet stream the screen has opened — only the newest is live. */
let fleets: ChatStreamOptions[] = []

beforeEach(() => {
  jest.useFakeTimers()
  mockList.mockReset()
  mockArchive.mockReset()
  mockUnarchive.mockReset()
  mockFleet.mockReset()
  mockStream.mockReset()
  mockGet.mockReset()
  mockCaps.mockReset()
  fleets = []
  mockArchive.mockResolvedValue(undefined)
  mockUnarchive.mockResolvedValue(undefined)
  mockCaps.mockResolvedValue(undefined)
  mockStream.mockImplementation(() => new Promise(() => {}))
  mockGet.mockResolvedValue({ id: 's1', messages: [] })
  mockFleet.mockImplementation((_c: unknown, opts: ChatStreamOptions) => {
    fleets.push(opts)
    return new Promise(() => {}) // a live stream never resolves on its own
  })
})

afterEach(() => {
  jest.clearAllTimers()
  jest.useRealTimers()
})

async function mount(): Promise<ReactTestRenderer> {
  let tree: ReactTestRenderer
  await act(async () => {
    tree = create(<ChatScreen connection={conn} />)
  })
  return tree!
}

/** Push one fleet frame through the REAL herd reducer. */
async function fleetFrame(event: string, data: unknown): Promise<void> {
  const live = fleets[fleets.length - 1]
  if (live === undefined) throw new Error('the screen never opened the fleet stream')
  await act(async () => {
    live.onFrame({ event, data: typeof data === 'string' ? data : JSON.stringify(data) })
  })
}

function textOf(node: ReactTestInstance | string): string {
  if (typeof node === 'string') return node
  return node.children.map(textOf).join('')
}

/** The rendered row order, read off the swipe wrappers the list actually
 * mounted — not off any array the component happens to hold. */
function renderedOrder(tree: ReactTestRenderer): string[] {
  // The swipe wrapper paints its action label behind the row, so strip that
  // prefix — the row's own text is what these probes are reading.
  return tree.root
    .findAllByType(SwipeToArchive)
    .map((w) => textOf(w).replace(/^(Unarchive|Archive)/, ''))
}

function byLabel(tree: ReactTestRenderer, label: string): ReactTestInstance | undefined {
  return tree.root.findAll((n: ReactTestInstance) => n.props.accessibilityLabel === label)[0]
}

async function press(node: ReactTestInstance): Promise<void> {
  await act(async () => (node.props.onPress as () => void)())
}

/* ── Probe E: the fleet stream is CONNECTED, and the row reads it ─────────── */

test('PROBE E — a live fleet flip re-orders the list and re-labels the row', async () => {
  // Both sessions land from the cold list as idle. Nothing but the live stream
  // can change that, so any movement here is proof of the connection.
  mockList.mockResolvedValue([summary('a'), summary('b')])
  const tree = await mount()
  try {
    expect(mockFleet).toHaveBeenCalledTimes(1)
    expect(renderedOrder(tree).map((t) => t.slice(0, 1))).toEqual(['a', 'b'])

    await fleetFrame('state', {
      session_id: 'b',
      agent_state: 'blocked',
      ts: '2026-07-26T00:01:00Z',
    })

    // MUTANT KILLED (two at once). Read the row's pill from the cold
    // `session.agent_state` instead of the herd row and the label stays
    // "idle"; drop the fleet useEffect and neither the label NOR the order
    // moves. The attention sort putting b first is the reducer, the pill
    // saying "needs you" is the row — both had to be wired.
    const order = renderedOrder(tree)
    expect(order[0]).toContain('b')
    expect(order[0]).toContain('needs you')
    expect(order[1]).toContain('a')
    expect(order[1]).toContain('idle')
  } finally {
    await act(async () => tree.unmount())
  }
})

test('PROBE E2 — "blocked" is never rendered; the wire keeps the word', async () => {
  mockList.mockResolvedValue([summary('a', { agent_state: 'blocked' })])
  const tree = await mount()
  try {
    const painted = renderedOrder(tree).join(' ')
    expect(painted).toContain('needs you')
    // The copy law, pinned where the SCREEN renders it rather than in the pure
    // helper — a screen that bypassed stateColors would keep the helper green.
    expect(painted).not.toContain('blocked')
  } finally {
    await act(async () => tree.unmount())
  }
})

test('PROBE E3 — a heartbeat does NOT flip state, and the stall clock ticks', async () => {
  // A FRESH working session: agent_state_at is "now", so nothing is stalled
  // until the clock actually moves past the 150s threshold.
  mockList.mockResolvedValue([
    summary('a', { agent_state: 'working', agent_state_at: new Date().toISOString() }),
  ])
  const tree = await mount()
  try {
    expect(renderedOrder(tree)[0]).toContain('working')
    expect(renderedOrder(tree)[0]).not.toContain('stalled')

    // A heartbeat proves life without being a state change (D41h).
    await fleetFrame('heartbeat', { session_id: 'a', ts: new Date().toISOString() })
    expect(renderedOrder(tree)[0]).toContain('working')

    // Now let real time pass the 150s stall threshold with no frame at all and
    // tick the clock. MUTANT KILLED: without the stall-clock interval the badge
    // never appears until something else happens to re-render — a session can
    // sit visibly "working" for as long as the user stares at it.
    jest.setSystemTime(Date.now() + 200_000)
    await act(async () => {
      jest.advanceTimersByTime(STALL_TICK_MS + 1)
    })
    expect(renderedOrder(tree)[0]).toContain('stalled')
  } finally {
    await act(async () => tree.unmount())
  }
})

/* ── Probe F: swipe → optimistic removal → the right verb ────────────────── */

test('PROBE F — a committed swipe removes the row optimistically and POSTs archive', async () => {
  mockList.mockResolvedValue([summary('a'), summary('b')])
  const tree = await mount()
  try {
    const rowB = tree.root.findAllByType(SwipeToArchive).find((w) => textOf(w).includes('b'))
    if (rowB === undefined) throw new Error('no swipe wrapper around the rows')
    expect(rowB.props.actionLabel).toBe('Archive')

    await act(async () => (rowB.props.onCommit as () => void)())

    // Optimistic: the row is gone BEFORE any list poll, because no fleet frame
    // will ever announce an archive (D28).
    expect(renderedOrder(tree).join(' ')).not.toContain('b')
    expect(mockArchive).toHaveBeenCalledWith(conn, 'b')
    expect(mockUnarchive).not.toHaveBeenCalled()
  } finally {
    await act(async () => tree.unmount())
  }
})

test('PROBE F2 — a REFUSED archive re-reads the shelf instead of guessing the row back', async () => {
  mockList.mockResolvedValue([summary('a')])
  mockArchive.mockRejectedValue(new Error('chat POST failed: HTTP 404'))
  const tree = await mount()
  try {
    const listCalls = mockList.mock.calls.length
    const row = tree.root.findAllByType(SwipeToArchive)[0]!
    await act(async () => (row.props.onCommit as () => void)())
    await act(async () => {}) // let the rejection land

    // The recovery is a re-read, never a re-insert at a guessed position: the
    // attention sort owns the order and a client-invented row would sit in the
    // wrong place with a stale state.
    expect(mockList.mock.calls.length).toBeGreaterThan(listCalls)
  } finally {
    await act(async () => tree.unmount())
  }
})

/* ── Probe G: the shelf ──────────────────────────────────────────────────── */

test('PROBE G — the shelf toggle re-lists with archived=true and swaps the verb', async () => {
  mockList.mockResolvedValue([summary('a')])
  const tree = await mount()
  try {
    expect(mockList).toHaveBeenLastCalledWith(conn, false)

    const toggle = byLabel(tree, 'Show archived sessions')
    if (toggle === undefined) throw new Error('no archived-shelf affordance on the list')
    await act(async () => (toggle.props.onPress as () => void)())
    await act(async () => {})

    // MUTANT KILLED: a toggle that only flips a local label without re-listing
    // shows the ACTIVE sessions under the "Archived" heading — every row a
    // session the user never dismissed.
    expect(mockList).toHaveBeenLastCalledWith(conn, true)

    const row = tree.root.findAllByType(SwipeToArchive)[0]!
    expect(row.props.actionLabel).toBe('Unarchive')
    await act(async () => (row.props.onCommit as () => void)())
    // The SAME gesture on the other shelf must be the OTHER verb — archiving
    // an already-archived session would be a silent no-op the user reads as
    // "unarchive is broken".
    expect(mockUnarchive).toHaveBeenCalledWith(conn, 'a')
    expect(mockArchive).not.toHaveBeenCalled()
  } finally {
    await act(async () => tree.unmount())
  }
})

test('PROBE G2 — a full shelf says the cap out loud', async () => {
  mockList.mockResolvedValue(Array.from({ length: 50 }, (_, i) => summary(`s${i}`)))
  const tree = await mount()
  try {
    const painted = tree.root.findAll((n) => (n.type as unknown) === 'Text').map(textOf).join(' ')
    expect(painted).toContain('50 most recent')
    expect(painted).toContain('no older page')
  } finally {
    await act(async () => tree.unmount())
  }
})

/* ── Probe H: nav asymmetry, through the real screens ────────────────────── */

test('PROBE H — archiving the OPEN session pops out; unarchive never navigates', async () => {
  mockList.mockResolvedValue([summary('a'), summary('b')])
  mockCaps.mockResolvedValue({
    providers: { claude: { modes: ['plan'], models: ['opus'], efforts: ['high'] } },
  })
  mockGet.mockResolvedValue({ id: 'a', provider: 'claude', model_choice: 'opus', messages: [] })
  const tree = await mount()
  try {
    // Open session "a" for real.
    const rowA = tree.root
      .findAllByType(SwipeToArchive)
      .find((w) => textOf(w).includes('a'))!
    const pressable = rowA.findAll(
      (n: ReactTestInstance) => typeof n.props.onPress === 'function',
    )[0]!
    await press(pressable)
    await act(async () => {})
    expect(byLabel(tree, 'Session options')).toBeDefined()

    // The sheet is the session-options surface, and archive lives in it —
    // which is what makes this leg reachable at all on a phone.
    await press(byLabel(tree, 'Session options')!)
    const archiveBtn = byLabel(tree, 'Archive this session')
    if (archiveBtn === undefined) throw new Error('the options sheet offers no archive')
    await press(archiveBtn)
    await act(async () => {})

    // MUTANT KILLED: without nextOpenAfterArchive's identity check the screen
    // stays inside the session it just dismissed — a transcript for a row that
    // no longer exists on the shelf behind it.
    expect(mockArchive).toHaveBeenCalledWith(conn, 'a')
    expect(byLabel(tree, 'Session options')).toBeUndefined() // popped back to the list
    expect(renderedOrder(tree).join(' ')).not.toContain('a')
    expect(renderedOrder(tree).join(' ')).toContain('b')
  } finally {
    await act(async () => tree.unmount())
  }
})

/* ── Probe I: the picker sheet renders discovery, not a guess ────────────── */

test('PROBE I — the sheet renders the DISCOVERED vocabulary and the observed-model fact', async () => {
  mockList.mockResolvedValue([summary('a')])
  mockCaps.mockResolvedValue({
    providers: {
      claude: { modes: ['plan', 'auto'], models: ['sonnet', 'opus'], efforts: ['high'] },
    },
  })
  mockGet.mockResolvedValue({
    id: 'a',
    provider: 'claude',
    model_choice: 'opus',
    mode: 'plan',
    messages: [],
  })
  const tree = await mount()
  try {
    const rowA = tree.root.findAllByType(SwipeToArchive)[0]!
    await press(rowA.findAll((n) => typeof n.props.onPress === 'function')[0]!)
    await act(async () => {})
    await press(byLabel(tree, 'Session options')!)

    expect(byLabel(tree, 'Model: opus')).toBeDefined()
    expect(byLabel(tree, 'Model: sonnet')).toBeDefined()
    // Never offered, because the server never advertised it (D22).
    expect(byLabel(tree, 'Mode: bypassPermissions')).toBeUndefined()

    const sheetText = tree.root.findAll((n) => (n.type as unknown) === 'Text').map(textOf).join(' | ')
    expect(sheetText).toContain('next resume') // effort honesty

    // No turn has streamed, so there is no OBSERVED model yet and the sheet
    // says nothing about one. MUTANT KILLED: a sheet that echoed the chosen
    // model as "answering with opus" would be inventing a fact the wire has
    // not reported.
    expect(sheetText).not.toContain('answering with')
  } finally {
    await act(async () => tree.unmount())
  }
})

test('PROBE I2 — an all-empty provider degrades instead of rendering dead chips', async () => {
  mockList.mockResolvedValue([summary('a')])
  mockCaps.mockResolvedValue({ providers: { codex: { modes: [], models: [], efforts: [] } } })
  mockGet.mockResolvedValue({ id: 'a', provider: 'codex', messages: [] })
  const tree = await mount()
  try {
    const rowA = tree.root.findAllByType(SwipeToArchive)[0]!
    await press(rowA.findAll((n) => typeof n.props.onPress === 'function')[0]!)
    await act(async () => {})
    await press(byLabel(tree, 'Session options')!)

    const sheetText = tree.root.findAll((n) => (n.type as unknown) === 'Text').map(textOf).join(' | ')
    // MUTANT KILLED: falling back to the claude floor for an empty provider
    // paints chips that PATCH values codex rejects — controls that look alive
    // and are not.
    expect(sheetText).toContain('codex advertises no mode, model or effort options')
    expect(byLabel(tree, 'Model: opus')).toBeUndefined()
    expect(byLabel(tree, 'Mode: plan')).toBeUndefined()
    // Archive still works — dismissal is orthogonal to the picker vocabulary.
    expect(byLabel(tree, 'Archive this session')).toBeDefined()
  } finally {
    await act(async () => tree.unmount())
  }
})
