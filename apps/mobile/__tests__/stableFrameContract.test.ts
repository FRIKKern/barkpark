// The MOBILE leg of the chat live-document wire contract (charter D59).
//
// Its Go twin is internal/pdrender/chat_stable_frames_test.go, and the two read
// the SAME recorded file: internal/pdrender/testdata/chat_stable_frames.json.
// That directory is the one path bound by mobile.yml, go-tests.yml and the
// Elixir dispatcher at once, so a regen re-fires every consumer instead of
// leaving one surface quietly on an older contract.
//
// The point of this test is parallel construction: the server emitter
// (mob-rt-s7) and the progressive consumer (mob-rt-s8) both build against these
// recorded frames rather than against each other. If the two legs ever reach
// DIFFERENT outcomes for the same sequence, one of the surfaces is wrong about
// the wire — and this file is where that shows up.
//
// An ESM default import straight from the Go testdata mirror — NOT fs/path
// (@types/node is absent, so the fs form does not typecheck) and strictly
// test-side, so metro never bundles the fixture into the app.
import fixture from '../../../internal/pdrender/testdata/chat_stable_frames.json'

import type {
  StableEndFrame,
  StableFrame,
  StableWireEvent,
} from '../src/chat/wire'
import { isStableEvent } from '../src/chat/wire'
import { BLOCK_RENDERERS } from '../src/papers/portabledoc/registry'

// The registry import above is what forces this mock (babel hoists it over the
// imports): BLOCK_RENDERERS transitively loads MermaidIsland, whose WebView
// native module does not exist under jest.
jest.mock('react-native-webview', () => ({ WebView: () => null }))

/** The outcome a client reaches after walking one recorded sequence — the
 * shape the fixture records under `expected` / `expected_from_only`. */
interface StableWalk {
  outcome: string
  accepted_stable_frames: number
  committed_bytes: number
  final_turn: number
  gap: StableGap | null
}

interface StableGap {
  frame_index: number
  turn: number
  expected_from: number
  actual_from: number
}

interface StableSequence {
  name: string
  title: string
  why: string
  sources: Record<string, string>
  skeleton_at_frame?: number
  drops_segments?: boolean
  frames: StableWireEvent[]
  expected: StableWalk
  /** Present ONLY where the naive from-only predicate disagrees. */
  expected_from_only?: StableWalk
}

interface StableFixture {
  scope: string
  contract: Record<string, string>
  sequences: StableSequence[]
}

// The JSON import is structurally inferred (a union across heterogeneous
// frames), so it is asserted onto the declared contract types once, here. That
// assertion IS the mobile projection of the wire: if wire.ts ever stops
// describing what the fixture records, the walk below stops typechecking.
const fx = fixture as unknown as StableFixture

/**
 * Walk one sequence exactly as the Go twin does.
 *
 * `useTurn` picks the predicate: true is the D59 contract (a turn change resets
 * the byte cursor), false is the naive from-only client D59 exists to rule out.
 */
function walk(seq: StableSequence, useTurn: boolean): StableWalk {
  const res: StableWalk = {
    outcome: 'streaming',
    accepted_stable_frames: 0,
    committed_bytes: 0,
    final_turn: 0,
    gap: null,
  }
  let turn = -1
  let committed = 0

  for (let i = 0; i < seq.frames.length; i++) {
    const f = seq.frames[i]
    if (!f) continue
    res.final_turn = f.data.turn
    if (useTurn && f.data.turn !== turn) {
      turn = f.data.turn
      committed = 0
    }

    if (isStableEvent(f)) {
      const d: StableFrame = f.data
      if (d.from !== committed) {
        res.outcome = 'gap'
        res.committed_bytes = committed
        res.gap = {
          frame_index: i,
          turn: d.turn,
          expected_from: committed,
          actual_from: d.from,
        }
        return res
      }
      committed = d.to
      res.accepted_stable_frames += 1
      continue
    }

    const end: StableEndFrame = f.data
    // A SERVER-declared degrade is categorically different from a
    // client-detected gap: the client throws its segments away and renders the
    // persisted row, so `from` is not cursor-checked.
    if (end.reason === 'degraded') {
      committed = 0
      res.outcome = 'degraded'
      continue
    }
    if (end.from !== committed) {
      res.outcome = 'gap'
      res.committed_bytes = committed
      res.gap = {
        frame_index: i,
        turn: end.turn,
        expected_from: committed,
        actual_from: end.from,
      }
      return res
    }
    res.outcome = end.reason
  }

  res.committed_bytes = committed
  return res
}

describe('chat stable-frame wire contract (D59)', () => {
  it('reads the recorded fixture, not a local copy of it', () => {
    expect(fx.scope).toBe('chat-stable-frame-wire')
    // The file must state the contract on its own — a cold reader (or the
    // emitter author) needs no second document.
    for (const key of ['stable', 'stable_end', 'why_to', 'why_turn']) {
      expect(fx.contract[key] ?? '').not.toBe('')
    }
    expect(fx.sequences.length).toBeGreaterThanOrEqual(7)
  })

  it.each(fx.sequences.map((s) => [s.name, s] as const))(
    'reaches the recorded outcome for %s',
    (_name, seq) => {
      expect(walk(seq, true)).toEqual(seq.expected)

      if (seq.skeleton_at_frame !== undefined) {
        const f = seq.frames[seq.skeleton_at_frame]
        expect(f && isStableEvent(f) ? f.data.skeleton : null).not.toBeNull()
      }
      if (seq.drops_segments) {
        expect(walk(seq, true).committed_bytes).toBe(0)
      }
    },
  )

  it('covers every terminal reason plus a client-detected gap', () => {
    const outcomes = new Set(fx.sequences.map((s) => s.expected.outcome))
    for (const want of ['settled', 'capped', 'degraded', 'gap']) {
      expect(outcomes).toContain(want)
    }
    // The capped case must be the ZERO-stable-frame one: that is the state
    // reachable with no stable frame to hang a terminal field on, and the
    // reason stable_end is its own event.
    const capped = fx.sequences.filter((s) => s.expected.outcome === 'capped')
    expect(capped.length).toBeGreaterThanOrEqual(1)
    expect(capped.some((s) => s.expected.accepted_stable_frames === 0)).toBe(true)
  })

  // The run proof for why `turn` is on the wire at all. Both predicates walk
  // the same recorded frames; on exactly one sequence they disagree, and the
  // from-only client is the one that swallows a spliced turn.
  it('proves `turn` discriminates where `from` alone false-accepts', () => {
    const diverging = fx.sequences.filter((s) => s.expected_from_only)
    expect(diverging).toHaveLength(1)

    for (const seq of fx.sequences) {
      if (!seq.expected_from_only) {
        // No recorded divergence => the predicates MUST agree, which is what
        // makes the one divergence meaningful rather than incidental.
        expect(walk(seq, false)).toEqual(seq.expected)
        continue
      }
      const strict = walk(seq, true)
      const fromOnly = walk(seq, false)
      expect(fromOnly).toEqual(seq.expected_from_only)
      expect(strict.outcome).toBe('gap')
      expect(fromOnly.outcome).not.toBe('gap')
      expect(fromOnly.accepted_stable_frames).toBeGreaterThan(
        strict.accepted_stable_frames,
      )
    }
  })

  // The mobile counterpart of the Go leg's zero-unknown-box proof: a frame is
  // only useful if this surface can actually draw it, so every block type the
  // fixture carries must be a registered renderer.
  it('renders every block type the fixture carries', () => {
    let blocks = 0
    let skeletons = 0
    for (const seq of fx.sequences) {
      for (const f of seq.frames) {
        if (!isStableEvent(f)) continue
        if (f.data.skeleton) skeletons += 1
        expect(f.data.blocks.length).toBeGreaterThan(0)
        for (const b of f.data.blocks) {
          expect(Object.keys(BLOCK_RENDERERS)).toContain(b.type)
          blocks += 1
        }
      }
    }
    expect(blocks).toBeGreaterThanOrEqual(10)
    expect(skeletons).toBeGreaterThanOrEqual(1)
  })

  // Offsets are UTF-8 byte offsets; every recorded source is deliberately pure
  // ASCII so a JS string length is the same number the Go leg asserts against.
  it('keeps every window inside its turn ASCII source', () => {
    for (const seq of fx.sequences) {
      for (const src of Object.values(seq.sources)) {
        expect(src).toMatch(/^[\x00-\x7F]*$/)
      }
      for (const f of seq.frames) {
        if (!isStableEvent(f)) continue
        expect(f.data.to).toBeGreaterThan(f.data.from)
        expect(f.data.from).toBeGreaterThanOrEqual(0)
        const src = seq.sources[String(f.data.turn)]
        if (src !== undefined) expect(f.data.to).toBeLessThanOrEqual(src.length)
      }
    }
  })
})
