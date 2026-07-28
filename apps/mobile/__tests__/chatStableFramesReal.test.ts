// The REAL-BYTES leg of the chat live-document contract (mobile charter D59).
//
// Its sibling, stableFrameContract.test.ts, walks a HAND-AUTHORED fixture: it
// says what the wire is supposed to be, and it is the file both the emitter and
// the consumers were built against. This file answers the other question, which
// no hand-authored fixture can: did a PRODUCTION Barkpark actually put those
// bytes on a socket, and does the REAL reducer — the one the phone runs, not a
// walk written for a test — paint them progressively?
//
// The frames in internal/pdrender/testdata/chat_stable_frames_real.json were
// captured off guerrilla.barkpark.cloud by tooling/chat-drive/drive.sh (D41
// safety law: plan mode, no plan card ever allowed, session archived, minted
// token revoked by body) and re-checked against the contract offline by
// tooling/chat-drive/assert-stable-capture.py over the raw events.log.
//
// THE HONEST CEILING, and it is why this file exists rather than a claim: the
// capture proves the SERVER half (real production bytes, in order, mid-turn),
// and this replay proves the CLIENT half (the shipped reducer accepts them and
// commits them progressively). NOBODY has watched a phone paint one. That
// residual is a device gate, not a test — it rides mob-hg-device-boot.
import fixture from '../../../internal/pdrender/testdata/chat_stable_frames_real.json'

import {
  initialChatState,
  reduce,
  type ChatEvent,
  type ChatState,
} from '../src/chat/reducer'
import type { StableWireEvent } from '../src/chat/wire'
import { isStableEvent } from '../src/chat/wire'

/** The committed capture: provenance plus the analysed turn's frames, in the
 * order they arrived on the wire. */
interface RealCapture {
  scope: string
  capture: {
    server: string
    session_id: string
    captured_at: string
    slot: string
    slot_sha_before: string
    slot_sha_after: string
    ceiling: string
  }
  captured_turn: number
  mid_turn_frames: number
  committed_bytes: number
  frames: StableWireEvent[]
}

const fx = fixture as unknown as RealCapture

/** One captured envelope as the reducer's SSE frame event — the data string is
 * re-serialized from the recorded payload, so the reducer runs its own parser
 * over it exactly as it does on the device. */
function frameEvent(e: StableWireEvent): ChatEvent {
  return { type: 'frame', name: e.event, data: JSON.stringify(e.data) }
}

const t0 = Date.UTC(2026, 6, 28, 23, 0, 0)

function driveAll(): { states: ChatState[]; final: ChatState } {
  let st = initialChatState(fx.capture.session_id)
  const states: ChatState[] = []
  for (const f of fx.frames) {
    st = reduce(st, frameEvent(f), t0).state
    states.push(st)
  }
  return { states, final: st }
}

describe('a REAL captured turn replayed through the shipped reducer (D59)', () => {
  it('is a real capture and says where it came from', () => {
    expect(fx.scope).toBe('chat-stable-frame-wire-real-capture')
    for (const key of [
      'server',
      'session_id',
      'captured_at',
      'slot_sha_before',
      'slot_sha_after',
      'ceiling',
    ] as const) {
      expect(fx.capture[key] ?? '').not.toBe('')
    }
    // The one provenance fact that makes the capture a capture: the live slot
    // did not move under it. A redeploy mid-stream would have severed the
    // connection and spliced two different builds' bytes into one log.
    expect(fx.capture.slot_sha_after).toBe(fx.capture.slot_sha_before)
  })

  it('carries a MID-TURN frame, which is the whole point', () => {
    // One stable frame is what a single-shot turn also produces. Progressive
    // means content committed while the model was still talking.
    const stable = fx.frames.filter(isStableEvent)
    expect(stable.length).toBeGreaterThanOrEqual(2)
    expect(fx.mid_turn_frames).toBeGreaterThanOrEqual(1)
    expect(stable.every((f) => f.data.turn === fx.captured_turn)).toBe(true)
    const ends = fx.frames.filter((f) => !isStableEvent(f))
    expect(ends).toHaveLength(1)
    expect(ends[0]?.data.reason).toBe('settled')
  })

  it('paints segment by segment — the cursor advances on every real frame', () => {
    const { states } = driveAll()
    let painted = 0
    let bytes = 0

    fx.frames.forEach((f, i) => {
      const st = states[i]
      expect(st).toBeDefined()
      if (!st) return
      if (isStableEvent(f)) {
        painted += 1
        bytes = f.data.to
        // Accepted: one more segment on screen, cursor at the SOURCE offset.
        expect(st.segments).toHaveLength(painted)
        expect(st.committedBytes).toBe(bytes)
        expect(st.stableStopped).toBe(false)
        expect(st.stableGap).toBeNull()
        // Every committed segment renders something — an empty one would
        // advance the cursor while painting nothing.
        expect(st.segments[painted - 1]?.blocks.length).toBeGreaterThan(0)
      }
    })

    expect(painted).toBe(fx.frames.filter(isStableEvent).length)
    expect(bytes).toBe(fx.committed_bytes)
  })

  it('settles without popping: nothing already painted is dropped or reflowed', () => {
    const { states, final } = driveAll()
    const beforeEnd = states[states.length - 2]
    expect(beforeEnd).toBeDefined()

    expect(final.stableEnd).toBe('settled')
    expect(final.stableGap).toBeNull()
    // THE no-pop property: the settle adds nothing and removes nothing. The
    // segments a reader has already read are the SAME objects, in the same
    // order, after the turn is declared whole.
    expect(final.segments).toEqual(beforeEnd?.segments)
    expect(final.committedBytes).toBe(beforeEnd?.committedBytes)
    // And the duplicate persisted row the settle refetch is about to bring is
    // armed for suppression rather than drawn a second time (D61).
    expect(final.settleArm).toEqual({ turn: fx.captured_turn, afterSeq: 0 })
  })

  it('is byte-honest: the segments tile the turn with no gap and no overlap', () => {
    const { final } = driveAll()
    let cursor = 0
    for (const seg of final.segments) {
      expect(seg.turn).toBe(fx.captured_turn)
      expect(seg.from).toBe(cursor)
      expect(seg.to).toBeGreaterThan(seg.from)
      cursor = seg.to
    }
    expect(cursor).toBe(fx.committed_bytes)
    const end = fx.frames.find((f) => !isStableEvent(f))
    expect(end?.data.from).toBeGreaterThanOrEqual(cursor)
  })
})
