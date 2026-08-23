// THE STABLE CURSOR IS KEYED ON TURN, NEVER ON GENERATION
// (mob-lm-s7-go-residuals, criterion 4).
//
// WHAT THIS PROTECTS, and why it is a test rather than a diff. That row's other
// six criteria are internal/ work: a shared tail-append helper with a 262144-byte
// freeze latch in internal/chat/reduce.go, a `turn_started` arm advancing the
// generation on BOTH reducers, a two-turn codex interleave test per surface, the
// residual comments at reduce.go:528-533 and reducer.ts (now :855-858), and the
// TUI's boardColumns widening. Criterion 4 is the one that lands here, and it
// asks for something no mobile diff can show: that the slice adding a
// generation-advancing `turn_started` arm does NOT take the committed-bytes
// cursor with it.
//
// There is nothing to change today — mobile has no `turn_started` arm, and
// `adoptStableTurn` resets `committedBytes` only when `frame.turn` differs. A
// criterion whose evidence is "we looked and the code was already right" decays
// the moment someone edits the file. So the invariant is PINNED here instead,
// and it fails the day the Go-parity slice wires `turn_started` into this
// reducer and reaches for the cursor while it is there.
//
// THE TWO CLOCKS, which is the whole reason this can go wrong. `gen` is the
// CLIENT turn generation (D77) and advances on every system/init frame. `turn`
// is the SERVER-authored turn number carried on each stable frame. They are
// different clocks with different edges: reducer.ts's own comment at the
// `stableTurn` field says the cursor is fenced by the server turn "never the
// client `gen`", because gen "advances on system/init, not on the replay that
// causes a gap". Resetting the byte cursor on a gen edge would discard bytes the
// server still believes are committed, and the next stable frame's `from` would
// no longer equal `committedBytes` — the accept rule would reject the rest of a
// perfectly good turn and degrade it to plain text, silently.
import fixture from '../../../internal/pdrender/testdata/chat_stable_frames_real.json'

import {
  initialChatState,
  reduce,
  type ChatEvent,
  type ChatState,
} from '../src/chat/reducer'

interface RealFrame {
  event: string
  data: Record<string, unknown>
}
const fx = fixture as unknown as { captured_turn: number; frames: RealFrame[] }

const NOW = Date.UTC(2026, 7, 24, 12, 0, 0)

function frameEvent(e: RealFrame): ChatEvent {
  return { type: 'frame', name: e.event, data: JSON.stringify(e.data) }
}

/** A claude `system/init` frame — the ONE thing that advances `gen` (D77). */
function initEvent(): ChatEvent {
  return {
    type: 'frame',
    name: 'chat',
    data: JSON.stringify({ type: 'system', subtype: 'init', model: 'claude-opus-5' }),
  }
}

/** The frame vocabulary the Go-parity slice will add. It is INERT on mobile
 * today — the reducer has no arm for it — and this file's job is to make sure it
 * stays inert for the CURSOR specifically if an arm ever appears. */
function turnStartedEvent(turn: number): ChatEvent {
  return { type: 'frame', name: 'chat', data: JSON.stringify({ type: 'turn_started', turn }) }
}

/** Drive the capture's real stable frames until the cursor has advanced. */
function committedState(): ChatState {
  let st = initialChatState('session-cursor-pin')
  for (const f of fx.frames) {
    if (f.event !== 'stable') continue
    st = reduce(st, frameEvent(f), NOW).state
    if (st.committedBytes > 0) break
  }
  return st
}

describe('the stable cursor is keyed on TURN, not on generation', () => {
  it('drives the real capture far enough to have a cursor at all', () => {
    // Guard the instrument: every assertion below is vacuous if the cursor
    // never left 0, and a fixture reshape is exactly how that would happen
    // without anyone noticing.
    const st = committedState()
    expect(st.committedBytes).toBeGreaterThan(0)
    expect(st.stableTurn).toBe(fx.captured_turn)
  })

  it('a GENERATION advance leaves the committed-bytes cursor untouched', () => {
    const before = committedState()
    const after = reduce(before, initEvent(), NOW).state

    expect(after.gen).toBe(before.gen + 1) // the generation really did advance
    expect(after.committedBytes).toBe(before.committedBytes) // …and the cursor did not move
    expect(after.stableTurn).toBe(before.stableTurn)
    expect(after.committedChars).toBe(before.committedChars)
  })

  it('survives REPEATED generation advances — the cursor is not merely lagging one edge', () => {
    let st = committedState()
    const bytes = st.committedBytes
    for (let i = 0; i < 5; i++) st = reduce(st, initEvent(), NOW).state
    expect(st.gen).toBeGreaterThanOrEqual(5)
    expect(st.committedBytes).toBe(bytes)
  })

  it('a turn_started frame is INERT for the cursor — the arm the Go slice will add', () => {
    const before = committedState()
    const after = reduce(before, turnStartedEvent(before.stableTurn + 1), NOW).state
    // Whatever else that arm grows, it may not move the byte cursor: the cursor
    // belongs to the SERVER turn, and turn_started is a runtime boundary.
    expect(after.committedBytes).toBe(before.committedBytes)
    expect(after.stableTurn).toBe(before.stableTurn)
  })

  it('a genuine TURN CHANGE is what resets the cursor — the other half of the law', () => {
    // Without this the four assertions above would all pass on a reducer that
    // never resets the cursor at all, which would be a different bug.
    //
    // ASSERT THE ACCEPT, NOT ONLY THE NUMBER. The first draft of this test
    // replayed the FIRST stable frame under a new turn, and its `to` is exactly
    // the cursor that frame had just produced — so the expected byte count was
    // identical whether the reset happened or not, and deleting the reset from
    // adoptStableTurn left this test GREEN. A rejected frame is distinguishable
    // from an accepted one by its DEGRADE STATE, so that is what is checked: a
    // cursor mismatch records `stableGap` and latches `stableStopped`, and
    // neither may happen here. The frame is also taken from LATER in the
    // capture, so its `to` differs from the standing cursor and the byte
    // assertion is no longer self-satisfying.
    const before = committedState()
    const stables = fx.frames.filter((f) => f.event === 'stable')
    const later = stables[1] ?? stables[0]
    expect(later).toBeDefined()
    const to = later!.data.to as number
    expect(to).not.toBe(before.committedBytes) // the assertion below can now fail

    const nextTurn = { ...later!, data: { ...later!.data, turn: before.stableTurn + 1, from: 0 } }
    const after = reduce(before, frameEvent(nextTurn), NOW).state

    expect(after.stableTurn).toBe(before.stableTurn + 1)
    expect(after.stableGap).toBeNull() // ACCEPTED — no cursor mismatch
    expect(after.stableStopped).toBe(false)
    expect(after.committedBytes).toBe(to)
  })
})
