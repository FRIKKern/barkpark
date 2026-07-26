// The triage state-machine proofs — the fence-free half of the Tasks tab.
// Every load-bearing invariant (optimistic apply, rollback on failure, the
// pre-emptive fence refusal, the pulse-bumps-the-epoch restaleness trap, and
// the met-flip's verbatim criterion-text guard) is driven by feeding reduce()
// the shapes the server actually emits — no device, no server, no clock.
import { TaskApiError, type TaskDetail, type TaskDoc } from '../src/api/tasks'
import {
  criteriaView,
  currentEpoch,
  fenceCheck,
  initialTriageState,
  nowView,
  progressView,
  PULSE_MAX_BYTES,
  reduce,
  utf8Bytes,
  type TriageEffect,
  type TriageEvent,
  type TriageState,
} from '../src/tasks/triage'

const WORKER = 'mobile-abc12345'
const OTHER = 'loop-builder-7'

function doc(over: Partial<TaskDoc> = {}): TaskDoc {
  return {
    docId: 't1',
    title: 'Ship the triage',
    labels: [],
    papers: [],
    lifecycleStatus: 'in_progress',
    criteria: [
      { criterion: 'gate passes', met: false, attempts: [] },
      { criterion: 'evidence recorded', met: false, attempts: [] },
    ],
    claim: { worker: WORKER, epoch: 4, tsIso: '2026-07-25T08:00:00Z' },
    ...over,
  }
}

function detail(over: Partial<TaskDoc> = {}): TaskDetail {
  return { doc: doc(over), children: [], childCount: 0 }
}

function ready(over: Partial<TaskDoc> = {}): TriageState {
  const { state } = reduce(initialTriageState('t1', WORKER), {
    type: 'loaded',
    detail: detail(over),
  })
  return state
}

function drive(st: TriageState, ...evs: TriageEvent[]): { state: TriageState; effects: TriageEffect[] } {
  let state = st
  let effects: TriageEffect[] = []
  for (const ev of evs) ({ state, effects } = reduce(state, ev))
  return { state, effects }
}

// ── optimistic apply ─────────────────────────────────────────────────────────

test('a met stamp paints instantly and emits the write with the epoch it can see', () => {
  const { state, effects } = drive(ready(), {
    type: 'stamp',
    criterion: 0,
    met: true,
    text: 'jest 121/121',
  })

  // The paint is immediate — before any server round trip.
  expect(criteriaView(state)[0]?.met).toBe(true)
  expect(criteriaView(state)[0]?.evidence).toBe('jest 121/121')
  expect(criteriaView(state)[0]?.pending).toBe(true)
  expect(progressView(state)).toEqual({ met: 1, total: 2 })
  // But server truth is untouched — the overlay is derived, never written in.
  expect(state.detail?.doc.criteria[0]?.met).toBe(false)

  expect(effects).toHaveLength(1)
  const eff = effects[0]
  expect(eff?.type).toBe('stamp')
  if (eff?.type !== 'stamp') throw new Error('unreachable')
  expect(eff.observedEpoch).toBe(4)
  expect(eff.met).toBe(true)
  expect(eff.evidence).toBe('jest 121/121')
  // The met-flip guard, honoured client-side: the STORED wording, verbatim.
  // An index alone is unverifiable — the server answers criterion_text_required.
  expect(eff.criterionText).toBe('gate passes')
})

test('a miss paints an attempt without flipping met — there is no un-met verb', () => {
  const { state, effects } = drive(ready(), {
    type: 'stamp',
    criterion: 1,
    met: false,
    text: 'flaky under the sandbox',
  })
  const row = criteriaView(state)[1]
  expect(row?.met).toBe(false)
  expect(row?.attempts.map((a) => a.note)).toEqual(['flaky under the sandbox'])
  const eff = effects[0]
  if (eff?.type !== 'stamp') throw new Error('expected a stamp effect')
  expect(eff.met).toBe(false)
  expect(eff.note).toBe('flaky under the sandbox')
  expect(eff.evidence).toBeUndefined()
})

test('a pulse paints the now-line as pending, without a timestamp it has not earned', () => {
  const { state, effects } = drive(ready(), { type: 'pulse', text: 'rerunning the gate' })
  expect(nowView(state)).toEqual({ text: 'rerunning the gate', pending: true })
  const eff = effects[0]
  if (eff?.type !== 'pulse') throw new Error('expected a pulse effect')
  expect(eff.now).toBe('rerunning the gate')
  expect(eff.worker).toBe(WORKER)
})

// ── rollback ─────────────────────────────────────────────────────────────────

test('a failed stamp rolls the paint back and quotes the server verbatim', () => {
  const started = drive(ready(), { type: 'stamp', criterion: 0, met: true, text: 'PR #1' })
  expect(criteriaView(started.state)[0]?.met).toBe(true)
  const opId = started.state.pending?.opId
  expect(opId).toBeDefined()

  const failed = drive(started.state, {
    type: 'opFailed',
    opId: opId ?? 0,
    error: new TaskApiError(409, 'evidence_required', '--met requires non-empty --evidence'),
  })

  // Rolled back to server truth.
  expect(criteriaView(failed.state)[0]?.met).toBe(false)
  expect(criteriaView(failed.state)[0]?.pending).toBe(false)
  expect(progressView(failed.state)).toEqual({ met: 0, total: 2 })
  expect(failed.state.pending).toBeUndefined()
  // The server's own words, not ours.
  expect(failed.state.notice).toEqual({
    tone: 'failed',
    text: 'evidence_required: --met requires non-empty --evidence',
  })
  // A plain refusal that says nothing about our claim does NOT force a re-read.
  expect(failed.effects).toHaveLength(0)
  expect(failed.state.staleEpoch).toBe(false)
})

test('a failed pulse rolls the now-line back to the last confirmed one', () => {
  const withNow = ready({
    claim: {
      worker: WORKER,
      epoch: 4,
      tsIso: '2026-07-25T08:00:00Z',
      now: { text: 'previous line', ts: '2026-07-25T08:05:00Z' },
    },
  })
  const started = drive(withNow, { type: 'pulse', text: 'new line' })
  expect(nowView(started.state)?.text).toBe('new line')

  const failed = drive(started.state, {
    type: 'opFailed',
    opId: started.state.pending?.opId ?? 0,
    error: new TaskApiError(500, 'http_500'),
  })
  expect(nowView(failed.state)).toEqual({
    text: 'previous line',
    ts: '2026-07-25T08:05:00Z',
    pending: false,
  })
})

test('a late answer for an op we already dropped changes nothing', () => {
  const started = drive(ready(), { type: 'stamp', criterion: 0, met: true, text: 'PR #1' })
  const failed = drive(started.state, {
    type: 'opFailed',
    opId: started.state.pending?.opId ?? 0,
    error: new TaskApiError(500, 'http_500'),
  })
  const late = drive(failed.state, {
    type: 'opSucceeded',
    opId: started.state.pending?.opId ?? 0,
    doc: doc({ criteria: [{ criterion: 'gate passes', met: true, attempts: [] }] }),
  })
  expect(late.state).toBe(failed.state)
})

// ── the fence, refused BEFORE the wire ───────────────────────────────────────

test('a stamp on someone else’s claim is refused locally — nothing is attempted', () => {
  const foreign = ready({ claim: { worker: OTHER, epoch: 9, tsIso: '2026-07-24T22:00:00Z' } })
  const { state, effects } = drive(foreign, {
    type: 'stamp',
    criterion: 0,
    met: true,
    text: 'evidence',
  })
  expect(effects).toHaveLength(0)
  expect(state.pending).toBeUndefined()
  expect(criteriaView(state)[0]?.met).toBe(false)
  expect(state.notice?.tone).toBe('refused')
  expect(state.notice?.text).toContain(OTHER)
  expect(state.notice?.text).toContain('2026-07-24T22:00:00Z')
})

test('pulse and release are equally holder-only; claim is refused only when held', () => {
  const foreign = doc({ claim: { worker: OTHER, epoch: 9 } })
  expect(fenceCheck(foreign, WORKER, 'pulse').allowed).toBe(false)
  expect(fenceCheck(foreign, WORKER, 'release').allowed).toBe(false)
  expect(fenceCheck(foreign, WORKER, 'claim').allowed).toBe(false)

  // Unclaimed: claiming steals no fence, but the holder-only verbs still bounce.
  const free = doc({ lifecycleStatus: 'open', claim: undefined })
  expect(fenceCheck(free, WORKER, 'claim').allowed).toBe(true)
  expect(fenceCheck(free, WORKER, 'stamp').allowed).toBe(false)

  // A same-worker re-claim is a RENEWAL, not a theft.
  expect(fenceCheck(doc(), WORKER, 'claim').allowed).toBe(true)

  // A stale claim row on a task nobody is working (lifecycle back to open) is
  // not a live fence — claiming is allowed.
  const stale = doc({ lifecycleStatus: 'open', claim: { worker: OTHER, epoch: 9 } })
  expect(fenceCheck(stale, WORKER, 'claim').allowed).toBe(true)
})

test('writes are single-flight: a second intent while one is in the air is refused', () => {
  const first = drive(ready(), { type: 'stamp', criterion: 0, met: true, text: 'a' })
  const second = drive(first.state, { type: 'pulse', text: 'b' })
  expect(second.effects).toHaveLength(0)
  expect(second.state.notice?.tone).toBe('refused')
  expect(second.state.pending?.opId).toBe(first.state.pending?.opId)
})

test('the local shape guards mirror the server’s 400s instead of spending a round trip', () => {
  const empty = drive(ready(), { type: 'stamp', criterion: 0, met: true, text: '   ' })
  expect(empty.effects).toHaveLength(0)
  expect(empty.state.notice?.text).toContain('evidence')

  const missNoNote = drive(ready(), { type: 'stamp', criterion: 1, met: false, text: '' })
  expect(missNoNote.effects).toHaveLength(0)

  const gone = drive(ready(), { type: 'stamp', criterion: 7, met: true, text: 'x' })
  expect(gone.effects).toHaveLength(0)
  expect(gone.state.notice?.text).toContain('7')

  const tooLong = drive(ready(), { type: 'pulse', text: 'x'.repeat(PULSE_MAX_BYTES + 1) })
  expect(tooLong.effects).toHaveLength(0)
  expect(tooLong.state.notice?.text).toContain(String(PULSE_MAX_BYTES))
})

test('utf8Bytes counts bytes, not code units — a 500-char emoji line is over cap', () => {
  expect(utf8Bytes('abc')).toBe(3)
  expect(utf8Bytes('æ')).toBe(2)
  expect(utf8Bytes('→')).toBe(3)
  expect(utf8Bytes('🐕')).toBe(4)
  expect(utf8Bytes('🐕'.repeat(200))).toBe(800)
})

// ── the epoch-restaleness trap ───────────────────────────────────────────────

test('a pulse bumps the epoch, and the NEXT stamp carries the new one', () => {
  // This is the trap recorded in the wave log: pulses bump the claim epoch, so
  // a stamp built from a remembered epoch 409s. Closed structurally — the
  // epoch is only ever read from the current doc, which every 200 replaces.
  const pulsed = drive(ready(), { type: 'pulse', text: 'working' })
  expect(currentEpoch(pulsed.state)).toBe(4)

  const confirmed = drive(pulsed.state, {
    type: 'opSucceeded',
    opId: pulsed.state.pending?.opId ?? 0,
    doc: doc({
      claim: { worker: WORKER, epoch: 5, tsIso: '2026-07-25T08:00:00Z', now: { text: 'working', ts: '2026-07-25T08:10:00Z' } },
    }),
  })
  expect(currentEpoch(confirmed.state)).toBe(5)
  expect(confirmed.state.notice).toEqual({ tone: 'ok', text: 'Pulsed — claim epoch is now 5.' })
  // The now-line is confirmed truth now, WITH its own timestamp: a pulse that
  // stops being renewed reads stale on the board instead of looking live.
  expect(nowView(confirmed.state)).toEqual({
    text: 'working',
    ts: '2026-07-25T08:10:00Z',
    pending: false,
  })

  const stamped = drive(confirmed.state, { type: 'stamp', criterion: 0, met: true, text: 'ev' })
  const eff = stamped.effects[0]
  if (eff?.type !== 'stamp') throw new Error('expected a stamp effect')
  expect(eff.observedEpoch).toBe(5)
})

test('a fenced_off refusal brakes the fenced actions and forces a re-read', () => {
  const started = drive(ready(), { type: 'stamp', criterion: 0, met: true, text: 'ev' })
  const failed = drive(started.state, {
    type: 'opFailed',
    opId: started.state.pending?.opId ?? 0,
    error: new TaskApiError(409, 'fenced_off'),
  })

  expect(failed.state.staleEpoch).toBe(true)
  expect(failed.state.refreshing).toBe(true)
  expect(failed.effects).toEqual([{ type: 'fetch', generation: failed.state.writeGeneration }])
  expect(failed.state.notice).toEqual({ tone: 'failed', text: 'fenced_off' })
  // Retrying blind on the epoch we know is stale is exactly the bug — refuse.
  const retried = drive(failed.state, { type: 'stamp', criterion: 0, met: true, text: 'ev' })
  expect(retried.effects).toHaveLength(0)
  expect(retried.state.notice?.tone).toBe('refused')

  // The re-read clears the brake.
  const reloaded = drive(failed.state, { type: 'loaded', detail: detail({ claim: { worker: WORKER, epoch: 6 } }) })
  expect(reloaded.state.staleEpoch).toBe(false)
  expect(currentEpoch(reloaded.state)).toBe(6)
  const ok = drive(reloaded.state, { type: 'stamp', criterion: 0, met: true, text: 'ev' })
  const eff = ok.effects[0]
  if (eff?.type !== 'stamp') throw new Error('expected a stamp effect')
  expect(eff.observedEpoch).toBe(6)
})

test('criterion_text_required and criteria_mismatch also force a re-read — our copy is stale', () => {
  for (const reason of ['criterion_text_required', 'criteria_mismatch', 'not_holder', 'stale_claim']) {
    const started = drive(ready(), { type: 'stamp', criterion: 0, met: true, text: 'ev' })
    const failed = drive(started.state, {
      type: 'opFailed',
      opId: started.state.pending?.opId ?? 0,
      error: new TaskApiError(409, reason),
    })
    expect(failed.effects).toEqual([{ type: 'fetch', generation: failed.state.writeGeneration }])
    expect(failed.state.staleEpoch).toBe(true)
  }
})

// ── load / refresh honesty ───────────────────────────────────────────────────

test('a failed refresh keeps the truth already on screen', () => {
  const loaded = ready()
  const refreshed = drive(loaded, { type: 'refresh' })
  expect(refreshed.effects).toEqual([{ type: 'fetch', generation: 0 }])
  expect(refreshed.state.refreshing).toBe(true)

  const failed = drive(refreshed.state, { type: 'loadFailed', message: 'offline' })
  expect(failed.state.phase).toBe('ready')
  expect(failed.state.detail).toBeDefined()
  expect(failed.state.refreshing).toBe(false)
  expect(failed.state.notice).toEqual({ tone: 'failed', text: 'offline' })
})

test('a failed FIRST load is an honest error screen, not an empty task', () => {
  const { state } = drive(initialTriageState('t1', WORKER), {
    type: 'loadFailed',
    message: 'HTTP 404',
  })
  expect(state.phase).toBe('error')
  expect(state.message).toBe('HTTP 404')
})

// ── the write/read reorder (task-67b2f856b4984382, found by the #6118 review) ─
//
// PINNED REGRESSION. The interleaving that used to reinstall older truth:
// pull-to-refresh dispatches a fetch → a pulse 200 lands and installs epoch
// N+1 → the SLOW fetch answer (server read taken PRE-pulse) arrives carrying
// epoch N. Before generation tagging that answer became current truth, and the
// next stamp then carried the pre-pulse epoch → server 409 stale_claim.

test('a refresh answer that a write outran is DROPPED, not installed as truth', () => {
  // 1. pull-to-refresh: the read is issued at the current generation.
  const refreshed = drive(ready(), { type: 'refresh' })
  const fetchEff = refreshed.effects[0]
  if (fetchEff?.type !== 'fetch') throw new Error('expected a fetch effect')
  const issuedAt = fetchEff.generation

  // 2. a pulse completes while that read is still in flight: epoch 4 → 5.
  const pulsed = drive(refreshed.state, { type: 'pulse', text: 'still on it' })
  const pulseEff = pulsed.effects[0]
  if (pulseEff?.type !== 'pulse') throw new Error('expected a pulse effect')
  const applied = drive(pulsed.state, {
    type: 'opSucceeded',
    opId: pulseEff.opId,
    doc: doc({ claim: { worker: WORKER, epoch: 5, tsIso: '2026-07-25T08:01:00Z' } }),
  })
  expect(currentEpoch(applied.state)).toBe(5)
  expect(applied.state.writeGeneration).toBe(issuedAt + 1)

  // 3. the slow, PRE-pulse read finally answers with epoch 4.
  const late = drive(applied.state, {
    type: 'loaded',
    detail: detail({ claim: { worker: WORKER, epoch: 4, tsIso: '2026-07-25T08:00:00Z' } }),
    generation: issuedAt,
  })

  // Dropped: epoch 5 stays on screen, and the refresh spinner still ends.
  expect(currentEpoch(late.state)).toBe(5)
  expect(late.state.refreshing).toBe(false)
  expect(late.effects).toHaveLength(0)

  // So the next stamp carries the POST-pulse epoch — no spurious 409.
  const stamped = drive(late.state, { type: 'stamp', criterion: 0, met: true, text: 'ev' })
  const stampEff = stamped.effects[0]
  if (stampEff?.type !== 'stamp') throw new Error('expected a stamp effect')
  expect(stampEff.observedEpoch).toBe(5)
})

test('an in-time refresh answer is still authoritative (the fence is not a mute button)', () => {
  const refreshed = drive(ready(), { type: 'refresh' })
  const fetchEff = refreshed.effects[0]
  if (fetchEff?.type !== 'fetch') throw new Error('expected a fetch effect')

  const landed = drive(refreshed.state, {
    type: 'loaded',
    detail: detail({ claim: { worker: WORKER, epoch: 9, tsIso: '2026-07-25T09:00:00Z' } }),
    generation: fetchEff.generation,
  })
  expect(currentEpoch(landed.state)).toBe(9)
  expect(landed.state.refreshing).toBe(false)
  expect(landed.state.phase).toBe('ready')
})
