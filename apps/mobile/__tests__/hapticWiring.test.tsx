// CALL-SITE PINS for the three D43 haptic events (closing wave round 2).
//
// The sibling suite (haptics.test.ts) pins the REGISTRY: which events exist and
// what feedback each one is. That is exactly half the claim. A registry can be
// perfectly ratified while every new event is dead code — which is the state
// this slice inherited: `archiveCommit` and `optionPick` did not exist, and the
// jump pill was buzzing under a borrowed name (`disclosureToggle`) that a
// registry test can never catch, because the borrowed event is a real event.
//
// So these probes drive the REAL components and read the EVENT NAME the call
// site chose. Asserting the name (not `selectionAsync`) is the whole point: the
// pill's mislabel emitted byte-identical feedback, so a probe reading the
// expo-haptics mock would have stayed green through it.
//
// `../src/ui/haptics` is mocked rather than expo-haptics for that reason — the
// registry suite already proves name → feedback, and pinning the name here
// means these two suites together pin the chain end to end.
import { act, create, type ReactTestInstance, type ReactTestRenderer } from 'react-test-renderer'
import { PanResponder } from 'react-native'

import { LegendList } from '@legendapp/list/react-native'

import { getChatSession, streamChatEvents, type ChatStreamOptions } from '../src/api/chat'
import type { InstanceConnection } from '../src/api/instance'
import type { ChatMessage } from '../src/chat/wire'
import { PickerSheet } from '../src/chat/PickerSheet'
import { emptyChoices } from '../src/chat/sessionStore'
import { ChatScreen, SwipeToArchive, swipeCommits } from '../src/screens/ChatScreen'
import { ChatSessionScreen } from '../src/screens/ChatSessionScreen'
import { haptic } from '../src/ui/haptics'
import { light } from '../src/ui/theme'

jest.mock('../src/api/chat', () => ({
  listChatSessions: jest.fn(() => Promise.resolve([])),
  archiveChatSession: jest.fn(() => Promise.resolve()),
  unarchiveChatSession: jest.fn(() => Promise.resolve()),
  streamFleetEvents: jest.fn(() => new Promise(() => {})),
  streamChatEvents: jest.fn(),
  getChatSession: jest.fn(),
  sendChatMessage: jest.fn(),
  interruptChat: jest.fn(),
  respondChatApproval: jest.fn(),
  patchChatSession: jest.fn(() => Promise.resolve()),
  fetchChatCapabilities: jest.fn(() => Promise.resolve(undefined)),
}))
jest.mock('react-native-webview', () => ({ WebView: () => null }))
jest.mock('../src/ui/haptics', () => ({ haptic: jest.fn() }))

const mockHaptic = haptic as jest.Mock
const mockGet = getChatSession as jest.Mock
const mockStream = streamChatEvents as jest.Mock

/** Every event the component under test emitted, in order. */
const fired = (): string[] => mockHaptic.mock.calls.map((call) => call[0] as string)

const conn: InstanceConnection = {
  projectUrl: 'https://bp.example',
  token: 'tkn',
  dataset: 'production',
}

let streams: ChatStreamOptions[] = []

beforeEach(() => {
  // FAKE TIMERS ARE TEARDOWN, not speed (the precedent the sibling wiring
  // suites set): LegendList's bootstrap-reveal tick never converges on a
  // zero-sized host, and the swipe row's Animated timings are timers too.
  jest.useFakeTimers()
  mockHaptic.mockClear()
  mockGet.mockReset()
  mockStream.mockReset()
  streams = []
  mockGet.mockResolvedValue({ id: 's1', messages: [] })
  mockStream.mockImplementation((_c: unknown, _id: unknown, opts: ChatStreamOptions) => {
    streams.push(opts)
    return new Promise(() => {}) // a live stream never resolves on its own
  })
})

afterEach(() => {
  jest.clearAllTimers()
  jest.useRealTimers()
})

/* ── archiveCommit: the swipe, at the moment it is DECIDED ──────────────────── */

/** The PanResponder config the row built — the only way to drive a release with
 * a chosen dx. PanResponder assembles gestureState from internal touch history,
 * so a synthetic dx cannot travel through panHandlers (the sibling suite's
 * PROBE J says so and splits its claim for exactly this reason). Reaching the
 * config directly drives the REAL release branch with the REAL threshold. */
function releaseWith(dx: number): void {
  const spy = PanResponder.create as unknown as jest.Mock
  const config = spy.mock.calls[spy.mock.calls.length - 1]![0] as {
    onPanResponderRelease: (e: unknown, g: { dx: number; dy: number }) => void
  }
  // A committing release flips `dismissing`, so the call is a state update and
  // belongs inside act — without it the row's collapse renders after the
  // assertions and React (rightly) complains.
  act(() => config.onPanResponderRelease({}, { dx, dy: 0 }))
}

describe('archiveCommit — the archive swipe (ChatScreen)', () => {
  const createSpy = jest.spyOn(PanResponder, 'create')

  afterAll(() => createSpy.mockRestore())

  function row(onCommit: () => void = () => {}): ReactTestRenderer {
    let tree: ReactTestRenderer
    act(() => {
      tree = create(
        <SwipeToArchive theme={light} actionLabel="Archive" onCommit={onCommit}>
          {null}
        </SwipeToArchive>,
      )
    })
    return tree!
  }

  it('fires on a committing release — and BEFORE onCommit, which the animation defers', () => {
    const onCommit = jest.fn()
    const tree = row(onCommit)
    try {
      // Well past the threshold, and `swipeCommits` (the pure rule, pinned in
      // its own suite) is asked rather than a copy of the constant.
      expect(swipeCommits(-1000)).toBe(true)
      releaseWith(-1000)

      // MUTANT KILLED: move haptic('archiveCommit') down into onCommit() and
      // this flips — the buzz would land 280ms after the finger left, reading
      // as the app answering back instead of the gesture landing.
      expect(fired()).toEqual(['archiveCommit'])
      expect(onCommit).not.toHaveBeenCalled()
    } finally {
      act(() => tree.unmount())
    }
  })

  it('is silent on a release that springs back — no verb, no buzz', () => {
    const tree = row()
    try {
      expect(swipeCommits(-4)).toBe(false)
      releaseWith(-4)
      // A twitch that commits nothing must not feel like it did.
      expect(fired()).toEqual([])
      // Rightward has no verb on either shelf, so it never commits either.
      expect(swipeCommits(300)).toBe(false)
      releaseWith(300)
      expect(fired()).toEqual([])
    } finally {
      act(() => tree.unmount())
    }
  })

  it('emits exactly once per commit — the restraint law forbids a haptic in a loop', () => {
    const tree = row()
    try {
      releaseWith(-1000)
      expect(fired()).toHaveLength(1)
    } finally {
      act(() => tree.unmount())
    }
  })
})

/* ── optionPick: the chip inside the sheet (PickerSheet) ────────────────────── */

describe('optionPick — a picker chip (PickerSheet)', () => {
  function sheet(onPick: () => void = () => {}): ReactTestRenderer {
    let tree: ReactTestRenderer
    act(() => {
      tree = create(
        <PickerSheet
          visible
          onClose={() => {}}
          theme={light}
          capabilities={{ providers: { claude: { modes: ['plan'], models: ['opus'], efforts: [] } } }}
          choices={{ ...emptyChoices(), provider: 'claude' }}
          observedModel=""
          onPick={onPick}
        />,
      )
    })
    return tree!
  }

  function chip(tree: ReactTestRenderer, label: string): ReactTestInstance {
    const found = tree.root.find(
      (n: ReactTestInstance) => n.props.accessibilityLabel === label,
    )
    return found
  }

  it('fires optionPick — NOT the sheet-level disclosureToggle it borrowed', () => {
    const onPick = jest.fn()
    const tree = sheet(onPick)
    try {
      act(() => chip(tree, 'Model: opus').props.onPress())
      // MUTANT KILLED: restore haptic('disclosureToggle') here and this flips
      // while every other test in the repo stays green — the two events emit
      // byte-identical selection feedback, so only the NAME can catch it.
      expect(fired()).toEqual(['optionPick'])
      expect(onPick).toHaveBeenCalledWith('modelChoice', 'opus')
    } finally {
      act(() => tree.unmount())
    }
  })

  it('is one tick per chip press, on every row', () => {
    const tree = sheet()
    try {
      act(() => chip(tree, 'Mode: plan').props.onPress())
      act(() => chip(tree, 'Model: opus').props.onPress())
      expect(fired()).toEqual(['optionPick', 'optionPick'])
    } finally {
      act(() => tree.unmount())
    }
  })

  it('renders no chip haptic on mount — no haptic on render (restraint law)', () => {
    const tree = sheet()
    try {
      // Two chips are on screen; a registry call from a render body would show
      // up here as two silent buzzes on open.
      expect(fired()).toEqual([])
    } finally {
      act(() => tree.unmount())
    }
  })
})

/* ── jumpToLatest: the pill (ChatSessionScreen) ─────────────────────────────── */

describe('jumpToLatest — the jump-to-latest pill (ChatSessionScreen)', () => {
  const msg = (seq: number, role: string): ChatMessage => ({
    seq,
    role,
    source_markdown: `row ${seq}`,
  })

  async function session(): Promise<ReactTestRenderer> {
    let tree: ReactTestRenderer
    await act(async () => {
      tree = create(<ChatSessionScreen connection={conn} sessionId="s1" onBack={() => {}} />)
    })
    return tree!
  }

  function pill(tree: ReactTestRenderer): ReactTestInstance | undefined {
    return tree.root.findAll(
      (n: ReactTestInstance) => n.props.accessibilityLabel === 'Jump to the latest message',
      { deep: false },
    )[0]
  }

  it('fires jumpToLatest — the borrowed disclosureToggle name is gone', async () => {
    mockGet.mockResolvedValue({ id: 's1', messages: [msg(1, 'user'), msg(2, 'assistant')] })
    const tree = await session()
    try {
      // Raise the pill the only honest way: a dragged scroll disengages follow,
      // then one token lands below (the two conditions showJumpPill reads).
      const list = tree.root.findByType(LegendList)
      await act(async () => list.props.onScrollBeginDrag())
      await act(async () => {
        list.props.onScroll({
          nativeEvent: {
            contentOffset: { y: 0 },
            contentSize: { height: 5000 },
            layoutMeasurement: { height: 800 },
          },
        })
      })
      await act(async () => {
        streams[streams.length - 1]!.onFrame({
          event: 'chat',
          data: JSON.stringify({
            type: 'stream_event',
            event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'x' } },
          }),
        })
      })
      const p = pill(tree)
      expect(p).toBeDefined()

      mockHaptic.mockClear()
      await act(async () => p!.props.onPress())
      // MUTANT KILLED: the pill shipped on 'disclosureToggle' — a jump is a
      // position choice, not a disclosure, and the feedback is identical.
      expect(fired()).toEqual(['jumpToLatest'])
      // Re-engaged: the pill's own presence is the follow state (sibling PROBE
      // E's argument), so the press did the work as well as the buzz.
      expect(pill(tree)).toBeUndefined()
    } finally {
      await act(async () => tree.unmount())
    }
  })
})

/* ── the negative half: nothing else borrows the new names ──────────────────── */

describe('the shelf itself stays quiet', () => {
  it('mounting ChatScreen emits nothing — no haptic on render', async () => {
    let tree: ReactTestRenderer
    await act(async () => {
      tree = create(<ChatScreen connection={conn} />)
    })
    try {
      expect(fired()).toEqual([])
    } finally {
      await act(async () => tree!.unmount())
    }
  })
})
