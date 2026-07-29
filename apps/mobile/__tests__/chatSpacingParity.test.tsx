// A LIVE TURN AND THE SAME TURN COLD ARE THE SAME DOCUMENT (mob-lm-s5).
//
// THE DEFECT. A turn that is still being written arrives as one committed
// SEGMENT row per settled segment (charter D59/D65); the same turn once settled
// is ONE row holding every block. The transcript's rhythm lived in
// `contentContainerStyle: { gap: 18 }`, and a list gap is paid at every ROW
// boundary — so while the turn streamed, every boundary that fell INSIDE it
// collected 18px the settled turn does not have. Two paragraphs read 30px apart
// live and 12px apart cold: the gap was never a replacement for the block
// rhythm, it was a second helping of it, and the turn visibly tightened at
// settle. That is the same class of dishonesty the rest of this wave is about —
// a surface showing a geometry it has not got.
//
// WHY THIS SUITE EXISTS RATHER THAN A DEVICE EYEBALL. "Does it look right on a
// phone" is not a claim this repo can back, so the claim is reshaped into one
// it can: for every adjacent block pair inside ONE turn, the separation the
// live rendering produces EQUALS the separation the cold rendering produces —
// asserted over the real screen's own renderItem seam, with the list's own
// contribution read out of the real list's props rather than assumed. Restore
// the gap to listContent and §2 reds, because the list's contribution is an
// INPUT to the arithmetic and not a constant in it.
//
// WHY IT NEVER SAYS 18. Block margins in the chat register span 2/4/6/8/10/14,
// so real cold separations range from about 8 to 28. A fix expressed as "18 less
// somewhere" would be a different lie at every pair. The invariant is that an
// intra-turn boundary contributes EXACTLY ZERO extra — the only value that makes
// the two renderings the same document.
//
// §1 MECHANISM — what legend-list 3.3.3 actually does with a container gap.
// §2 PARITY   — live vs cold, every adjacent pair, through the real renderItem.
// §3 RHYTHM   — the inter-TURN gap is untouched, and the boot estimate still
//               describes what it always described.
import { ScrollView, View } from 'react-native'
import { act, create, type ReactTestRenderer } from 'react-test-renderer'

import { LegendList } from '@legendapp/list/react-native'

import pkg from '../package.json'

import { getChatSession, streamChatEvents, type ChatStreamOptions } from '../src/api/chat'
import type { InstanceConnection } from '../src/api/instance'
import type { Block } from '../src/papers/portabledoc/model'
import type { ChatMessage } from '../src/chat/wire'
import {
  ChatSessionScreen,
  ESTIMATED_ROW_HEIGHT,
  TRANSCRIPT_ROW_GAP,
  rowLead,
  rowTurn,
  stableSegmentRows,
  type Row,
} from '../src/screens/ChatSessionScreen'

jest.mock('../src/api/chat', () => ({
  getChatSession: jest.fn(),
  sendChatMessage: jest.fn(),
  interruptChat: jest.fn(),
  respondChatApproval: jest.fn(),
  streamChatEvents: jest.fn(),
  patchChatSession: jest.fn(() => Promise.resolve()),
  fetchChatCapabilities: jest.fn(() => Promise.resolve(undefined)),
}))
jest.mock('react-native-webview', () => ({ WebView: () => null }))
jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(() => Promise.resolve()),
  notificationAsync: jest.fn(() => Promise.resolve()),
  selectionAsync: jest.fn(() => Promise.resolve()),
  ImpactFeedbackStyle: { Light: 'light', Medium: 'medium', Heavy: 'heavy' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning', Error: 'error' },
}))

const mockGet = getChatSession as jest.Mock
const mockStream = streamChatEvents as jest.Mock

const conn: InstanceConnection = {
  projectUrl: 'https://bp.example',
  token: 'tkn',
  dataset: 'production',
}

beforeEach(() => {
  // Fake timers are TEARDOWN, not speed — legend-list's bootstrap-reveal tick
  // never converges on a zero-sized test host and would outlive unmount().
  jest.useFakeTimers()
  mockGet.mockReset()
  mockStream.mockReset()
  mockStream.mockImplementation((_c: unknown, _id: unknown, _o: ChatStreamOptions) => {
    return new Promise(() => {})
  })
})

afterEach(() => {
  jest.clearAllTimers()
  jest.useRealTimers()
})

/* ── style arithmetic ────────────────────────────────────────────────────────── */

type Style = Record<string, unknown>

/** RN accepts a style, an array of styles, or nothing; flattening with
 * Object.assign is what the platform itself does, so this reads the value that
 * actually paints rather than the value that was written. */
function flat(raw: unknown): Style {
  if (raw === undefined || raw === null) return {}
  if (!Array.isArray(raw)) return raw as Style
  return Object.assign({}, ...raw.filter((p) => !!p).map((p) => flat(p))) as Style
}

const num = (v: unknown): number => (typeof v === 'number' ? v : 0)

/** A block's own contribution ABOVE it and BELOW it, honouring the shorthand —
 * marginVertical is what most of the chat register actually writes. */
const marginTop = (s: Style): number =>
  s.marginTop !== undefined ? num(s.marginTop) : num(s.marginVertical)
const marginBottom = (s: Style): number =>
  s.marginBottom !== undefined ? num(s.marginBottom) : num(s.marginVertical)

/* ── painting a row through the REAL renderItem ──────────────────────────────── */

interface RenderItemArg {
  item: Row
  index: number
  data: readonly Row[]
}
type RenderItem = (a: RenderItemArg) => React.ReactElement

interface PaintedRow {
  /** The bare space the row asks for above itself. */
  lead: number
  /** One flattened style per TOP-LEVEL block the row painted, in order. */
  blocks: Style[]
}

interface Json {
  type: string
  props: Record<string, unknown>
  children: Json[] | null
}

/** Paint one row through the screen's own renderItem and read back its geometry:
 * the wrapper's lead, and the top-level block styles inside the document view.
 *
 * Everything below the block roots is deliberately NOT read — a block's INTERNAL
 * spacing is the block's business and is identical in both renderings by
 * construction (it is the same renderer). What differs between live and cold is
 * only how the blocks are DISTRIBUTED over list rows. */
function paintRow(render: RenderItem, rows: readonly Row[], index: number): PaintedRow {
  let r!: ReactTestRenderer
  act(() => {
    r = create(render({ item: rows[index]!, index, data: rows }))
  })
  const json = r.toJSON() as unknown as Json
  const lead = marginTop(flat(json.props.style))
  // The wrapper's single child is the row; a document row's child is the
  // container whose children are the blocks. A row that paints no document
  // (a bubble, a bare line) contributes no block styles and no intra-turn pairs.
  const doc = (json.children ?? [])[0]
  const blocks = (doc?.children ?? []).map((c) => flat(c.props.style))
  act(() => r.unmount())
  return { lead, blocks }
}

/** THE ARITHMETIC. The separation between every pair of adjacent blocks in a
 * turn, in order — whatever rows those blocks happen to be distributed over.
 *
 * Three terms, and the middle one is why restoring the container gap reds this:
 *   • the blocks' own margins (always paid),
 *   • `listGap`, what the LIST puts between two rows (read from the real list),
 *   • the row's own lead (what this slice moved the rhythm onto).
 * A pair inside one row crosses no boundary and pays only the first term. */
function separations(painted: readonly PaintedRow[], listGap: number): number[] {
  const out: number[] = []
  let prev: Style | undefined
  for (const row of painted) {
    for (let i = 0; i < row.blocks.length; i++) {
      const block = row.blocks[i]!
      if (prev !== undefined) {
        const crossing = i === 0
        out.push(
          marginBottom(prev) +
            (crossing ? listGap + row.lead : 0) +
            marginTop(block),
        )
      }
      prev = block
    }
  }
  return out
}

/* ── the turn under test ─────────────────────────────────────────────────────── */

/** Six blocks, chosen so the pairs do NOT share a margin: paragraph is
 * marginVertical 6, ingress 8, quote 10, and a heading carries a scale-derived
 * marginTop against a marginBottom of 6. Any fix expressed as one subtracted
 * constant is wrong for at least three of these five pairs. */
const TURN: Block[] = [
  { type: 'paragraph', text: 'The first thing the answer says.' },
  { type: 'paragraph', text: 'And the second thing, still prose.' },
  { type: 'ingress', text: 'A lead-in, spaced differently.' },
  { type: 'quote', text: 'Something quoted, spaced differently again.' },
  { type: 'heading', level: 2, text: 'A section opens' },
  { type: 'paragraph', text: 'The last paragraph of the turn.' },
] as unknown as Block[]

/** The same turn, cold: ONE persisted row carrying every block. */
function coldRows(): Row[] {
  const message = {
    seq: 2,
    role: 'assistant',
    source_markdown: 'irrelevant — the blocks are what paints',
    blocks: TURN,
  } as unknown as ChatMessage
  return [{ key: 'm-2', kind: 'message', message }]
}

/** The same turn, live: the SAME blocks, distributed over four committed
 * segments — a 2/1/2/1 split, so the parity claim covers boundaries that fall
 * between every kind of pair rather than only between paragraphs. */
function liveRows(): Row[] {
  const cuts: [number, number][] = [
    [0, 2],
    [2, 3],
    [3, 5],
    [5, 6],
  ]
  return stableSegmentRows(
    new Map(),
    cuts.map(([from, to]) => ({
      turn: 7,
      from,
      to,
      blocks: TURN.slice(from, to),
    })),
  )
}

/* ── the mounted screen: the real list, the real renderItem ──────────────────── */

interface Harness {
  tree: ReactTestRenderer
  render: RenderItem
  /** What the REAL list puts between two rows, read off the REAL list's props
   * — an input to the arithmetic, never a constant in it. legend-list strips a
   * container `gap` before the ScrollView sees it, so this reads the prop the
   * screen passed, which is the thing an edit would change. */
  listGap: number
}

async function mount(): Promise<Harness> {
  mockGet.mockResolvedValue({
    id: 's1',
    messages: [{ seq: 1, role: 'user', source_markdown: 'hi' }],
  })
  let tree!: ReactTestRenderer
  await act(async () => {
    tree = create(<ChatSessionScreen connection={conn} sessionId="s1" onBack={() => {}} />)
  })
  const list = tree.root.findByType(LegendList)
  const content = flat(list.props.contentContainerStyle)
  const listGap = num(content.rowGap ?? content.gap)
  return { tree, render: list.props.renderItem as RenderItem, listGap }
}

/* ══ 1. MECHANISM — a container gap is LIST-OWNED and uniform ═══════════════════ */

describe('1. what legend-list does with a contentContainerStyle gap', () => {
  // Version-specific behaviour, so the version is part of the claim: this suite
  // is only evidence about the list the app actually ships.
  it('rests on legend-list 3.3.3, exactly', () => {
    expect((pkg as { dependencies: Record<string, string> }).dependencies['@legendapp/list']).toBe(
      '3.3.3',
    )
  })

  function mountRaw(gap: boolean): ReactTestRenderer {
    let t!: ReactTestRenderer
    act(() => {
      t = create(
        <LegendList
          data={[1, 2, 3]}
          keyExtractor={(n: number) => String(n)}
          estimatedItemSize={40}
          recycleItems={false}
          contentContainerStyle={
            gap ? { paddingTop: 10, gap: 18, flexGrow: 1 } : { paddingTop: 10, flexGrow: 1 }
          }
          renderItem={({ item }: { item: number }) => <View testID={`r${item}`} />}
        />,
      )
    })
    const sv = t.root.findByType(ScrollView)
    act(() => {
      sv.props.onLayout?.({ nativeEvent: { layout: { x: 0, y: 0, width: 390, height: 800 } } })
    })
    return t
  }

  /** Every absolutely-positioned item container the list emitted. */
  function containers(t: ReactTestRenderer): Style[] {
    const out: Style[] = []
    const walk = (n: Json | null): void => {
      if (n === null) return
      const s = flat(n.props.style)
      if (s.position === 'absolute' && s.left === 0 && s.right === 0) out.push(s)
      for (const c of n.children ?? []) walk(c)
    }
    walk(t.toJSON() as unknown as Json)
    return out
  }

  it('STRIPS the gap out of the container and re-emits it as padding on EVERY item', () => {
    const t = mountRaw(true)
    try {
      // The ScrollView never sees it — so "the gap is between rows" was never
      // how this worked.
      const sv = flat(t.root.findByType(ScrollView).props.contentContainerStyle)
      expect(sv.gap).toBeUndefined()
      expect(sv.rowGap).toBeUndefined()
      expect(sv.paddingTop).toBe(10)

      const items = containers(t)
      expect(items.length).toBeGreaterThan(1)
      // UNIFORM BY CONSTRUCTION: every container, not the ones between turns —
      // which is the whole reason no listContent edit could tighten an
      // intra-turn boundary alone.
      for (const c of items) {
        expect(c.paddingBottom).toBe(18)
        expect(c.boxSizing).toBe('border-box')
      }
    } finally {
      act(() => t.unmount())
    }
  })

  it('contributes NOTHING between rows once the gap is gone', () => {
    const t = mountRaw(false)
    try {
      const items = containers(t)
      expect(items.length).toBeGreaterThan(1)
      for (const c of items) {
        expect(c.paddingBottom).toBeUndefined()
        expect(c.paddingTop).toBeUndefined()
      }
    } finally {
      act(() => t.unmount())
    }
  })

  // THE ASSUMPTION THE WHOLE FIX RESTS ON, pinned rather than assumed.
  //
  // §2 below calls the screen's renderItem with `{item, index, data}` by hand,
  // which proves what the seam DOES with an ordering but not that the list ever
  // hands it one. If legend-list stopped passing `data`, `rowLead` would answer
  // 0 for every row and the transcript would silently lose ALL of its rhythm —
  // turn to turn as well as inside a turn — with every other probe in this file
  // still green. So the list itself is asked.
  it('HANDS renderItem the ordering — `data` and `index`, not just the item', () => {
    const seen: { keys: string[]; index: unknown; data: unknown }[] = []
    let t!: ReactTestRenderer
    act(() => {
      t = create(
        <LegendList
          data={['a', 'b', 'c']}
          keyExtractor={(n: string) => n}
          estimatedItemSize={40}
          recycleItems={false}
          renderItem={(args: { item: string; index?: number; data?: readonly string[] }) => {
            seen.push({ keys: Object.keys(args), index: args.index, data: args.data })
            return <View />
          }}
        />,
      )
    })
    try {
      act(() => {
        t.root
          .findByType(ScrollView)
          .props.onLayout?.({ nativeEvent: { layout: { x: 0, y: 0, width: 390, height: 800 } } })
      })
      expect(seen.length).toBeGreaterThan(1)
      seen.forEach((call, i) => {
        expect(call.keys).toEqual(expect.arrayContaining(['item', 'index', 'data']))
        expect(call.index).toBe(i)
        expect(call.data).toEqual(['a', 'b', 'c'])
      })
    } finally {
      act(() => t.unmount())
    }
  })
})

/* ══ 2. PARITY — the same turn, live and cold ══════════════════════════════════ */

describe('2. a live turn and the same turn cold are geometrically identical', () => {
  it('every adjacent intra-turn pair is separated by exactly the same space', async () => {
    const h = await mount()
    try {
      const cold = coldRows()
      const live = liveRows()
      // The split is real: cold is one row, live is four, same six blocks.
      expect(cold).toHaveLength(1)
      expect(live).toHaveLength(4)

      const coldSeps = separations(
        cold.map((_, i) => paintRow(h.render, cold, i)),
        h.listGap,
      )
      const liveSeps = separations(
        live.map((_, i) => paintRow(h.render, live, i)),
        h.listGap,
      )

      // Five pairs from six blocks — proof the paint found the whole turn on
      // both sides and is not comparing two empty lists.
      expect(coldSeps).toHaveLength(TURN.length - 1)
      expect(liveSeps).toHaveLength(TURN.length - 1)

      // THE INVARIANT.
      expect(liveSeps).toEqual(coldSeps)

      // …and it is not vacuously true by everything being one number: the pairs
      // really do carry different margins, so no single subtracted constant
      // could have produced this.
      expect(new Set(coldSeps).size).toBeGreaterThanOrEqual(3)
      expect(Math.min(...coldSeps)).toBeGreaterThan(0)
    } finally {
      await act(async () => h.tree.unmount())
    }
  })

  it('the boundary INSIDE a turn contributes exactly zero, whatever the blocks are', async () => {
    const h = await mount()
    try {
      const live = liveRows()
      // Said directly, so the law is readable without the arithmetic: the list
      // contributes nothing, and a continuing segment asks for nothing.
      expect(h.listGap).toBe(0)
      for (let i = 1; i < live.length; i++) {
        expect(rowLead(live, i)).toBe(0)
        expect(paintRow(h.render, live, i).lead).toBe(0)
      }
    } finally {
      await act(async () => h.tree.unmount())
    }
  })
})

/* ══ 3. RHYTHM — what must NOT have changed ════════════════════════════════════ */

describe('3. the transcript is not silently restyled whole', () => {
  it('keeps the full gap between TURNS — including between two turns of segments', async () => {
    const h = await mount()
    try {
      const a = stableSegmentRows(new Map(), [
        { turn: 7, from: 0, to: 1, blocks: [TURN[0]!] },
      ])
      const b = stableSegmentRows(new Map(), [
        { turn: 8, from: 0, to: 1, blocks: [TURN[1]!] },
      ])
      const user: Row = { key: 'm-9', kind: 'local', content: 'and then?', queued: false }
      const rows: Row[] = [...a, user, ...b]

      // Turn 7 → the user's line → turn 8: two turn boundaries, both full.
      expect(rowLead(rows, 1)).toBe(TRANSCRIPT_ROW_GAP)
      expect(rowLead(rows, 2)).toBe(TRANSCRIPT_ROW_GAP)
      expect(paintRow(h.render, rows, 1).lead).toBe(TRANSCRIPT_ROW_GAP)
      expect(paintRow(h.render, rows, 2).lead).toBe(TRANSCRIPT_ROW_GAP)
      // The head of the transcript is flush, exactly as a container gap was.
      expect(rowLead(rows, 0)).toBe(0)
      expect(paintRow(h.render, rows, 0).lead).toBe(0)
    } finally {
      await act(async () => h.tree.unmount())
    }
  })

  it('reads the turn off the row key, and refuses to guess for rows without one', () => {
    const [seg] = stableSegmentRows(new Map(), [
      { turn: 12, from: 40, to: 60, blocks: [TURN[0]!] },
    ])
    expect(rowTurn(seg!)).toBe(12)
    // A RESUMED stream's first held segment does not start at byte 0 — so
    // "opens the turn" can never be inferred from `from === 0`, and the lead is
    // derived from the ORDERING instead.
    expect(seg!.key).toBe('s-12-40')
    expect(rowTurn({ key: 'tail', kind: 'tail', text: 'x' })).toBeUndefined()
    expect(rowTurn({ key: 'skeleton', kind: 'skeleton', label: 'table', prose: '' })).toBeUndefined()
  })

  it('leaves the boot estimate describing exactly what it described', () => {
    // ESTIMATED_ROW_HEIGHT sizes the ITEM CONTAINER, which used to be the row
    // plus a list-injected 18 and is now the row plus its own 18. Those agree
    // for every row a BOOT frame can hold, because a boot frame is settled
    // message rows and a settled row always opens a turn — so the number is
    // unchanged on purpose, and the anchor has nothing to drift against.
    const boot: Row[] = [1, 2, 3].map((seq) => ({
      key: `m-${seq}`,
      kind: 'message',
      message: { seq, role: seq === 1 ? 'user' : 'assistant', source_markdown: 'x' } as ChatMessage,
    }))
    for (let i = 1; i < boot.length; i++) expect(rowLead(boot, i)).toBe(TRANSCRIPT_ROW_GAP)
    expect(ESTIMATED_ROW_HEIGHT).toBe(180)
  })

  it('claims nothing about neighbours it was not shown', () => {
    // The hook-free row seam is called from jest with the row alone; a missing
    // ordering means no lead, never a guessed one.
    expect(rowLead(undefined, undefined)).toBe(0)
    expect(rowLead(liveRows(), 99)).toBe(0)
  })
})
