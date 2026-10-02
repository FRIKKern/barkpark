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
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

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

// ---------------------------------------------------------------------------
// THE PRESERVATION GUARD (task-4d809f850c8c322a).
//
// Everything above asserts what the capture MEANS. This asserts that it still
// IS — byte for byte. chat_stable_frames_real.json is not a fixture anyone can
// re-cut: it is a real 2026-07-28 production turn against the live green slot
// (session 34a0246f-4acd-4df2-8f8f-bd42fa9624f4, $0.107 of billed provider
// spend). Nothing regenerates it and nothing could without buying another live
// paid turn, so a prettifier, a re-serialization or a routine "refresh the
// stale fixture" pass destroys it exactly as completely as `rm` does — and the
// diff would look like tidying. Hence a hash over the WHOLE file, not a shape
// check: the bytes are the artifact.
//
// PRESERVATION IS NOT A DRIFT LOCK. A drifting consumer fixture is normally
// fixed by making its producer regenerate it; that keeps it honest against the
// emitter. That remedy is unavailable here by construction, so this file gets
// preservation instead — frozen, explicitly NOT kept current. The staleness
// that buys is accepted and recorded (the `_preservation.accepted_risk` field
// in the file itself, and task-4d809f850c8c322a criterion 3): if the emitter
// renames a frame key, this suite keeps replaying July bytes and stays green.
// The check that DOES track the emitter is the hand-authored sibling
// chat_stable_frames.json.
const CAPTURE_PATH = join(
  __dirname,
  '..',
  '..',
  '..',
  'internal',
  'pdrender',
  'testdata',
  'chat_stable_frames_real.json',
)

/** SHA-256 of the capture as committed. Read the failure message before you
 * touch this constant. */
const CAPTURE_SHA256 =
  'cd82e151344435c2e7a8ccff88bed22886f35f3a9a25d3e06172664add6ef49a'

describe('the capture is PRESERVED, byte for byte (task-4d809f850c8c322a)', () => {
  it('has not been refreshed, rewritten, prettified or reformatted', () => {
    const raw = readFileSync(CAPTURE_PATH, 'utf8')
    const actual = createHash('sha256').update(raw).digest('hex')

    expect(
      actual === CAPTURE_SHA256
        ? 'preserved'
        : [
            'internal/pdrender/testdata/chat_stable_frames_real.json HAS CHANGED.',
            `  pinned: ${CAPTURE_SHA256}`,
            `  actual: ${actual}`,
            '',
            'This file is a PRESERVED PRODUCTION CAPTURE, not a regenerable fixture.',
            'It is a real chat turn recorded on 2026-07-28 against the live green',
            'production slot and it cost real money. NOTHING regenerates it and',
            'nothing could without spending another paid live production turn.',
            'Reformatting it, re-serializing it, prettifying it or "refreshing"',
            'it is as destructive as deleting it, because the bytes ARE the',
            'artifact.',
            '',
            'REVERT YOUR CHANGE TO THE CAPTURE. Do NOT update this constant.',
            'Re-pinning the hash is the same irreversible loss with an extra',
            'step, and it is the exact reaction this guard exists to stop. The',
            'only legitimate reason to move this pin is a NEW capture bought',
            'with a NEW paid production turn, added deliberately and reviewed',
            'as such.',
          ].join('\n'),
    ).toBe('preserved')
  })

  it('names its consumers, so a reducer change knows what depends on it', () => {
    const note = (fixture as unknown as { _preservation?: Record<string, unknown> })
      ._preservation
    expect(note).toBeDefined()
    const consumers = (note?.consumers ?? []) as string[]
    // This file, and the function it actually drives the capture through.
    expect(
      consumers.some(
        (c) =>
          c.includes('apps/mobile/__tests__/chatStableFramesReal.test.ts') &&
          c.includes('reduce()'),
      ),
    ).toBe(true)
    expect(
      consumers.some((c) =>
        c.includes('apps/mobile/__tests__/chatCursorTurnKeyed.test.ts'),
      ),
    ).toBe(true)
    expect(consumers.some((c) => c.includes('internal/chat/stable_test.go'))).toBe(
      true,
    )
    // Preservation is distinguished from a drift lock, and the staleness it
    // buys is written down rather than silently carried.
    expect(String(note?.preservation_not_a_drift_lock ?? '')).toContain(
      'drift lock',
    )
    expect(String(note?.accepted_risk ?? '')).toContain('task-4d809f850c8c322a')
    expect(String(note?.cannot_be_regenerated ?? '')).toContain('paid')
  })
})
