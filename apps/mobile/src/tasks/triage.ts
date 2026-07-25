// The PURE fence-free triage state machine — every intent, server answer and
// refusal flows through reduce(state, event) → { state, effects }; the React
// shell only translates taps into TriageEvents and executes TriageEffects as
// IO. Same architecture as src/chat/reducer.ts, and for the same reason: the
// load-bearing invariants (optimistic apply, rollback, the fence refusal, the
// epoch-restaleness trap) are provable by driving a function — no device, no
// server, no clock.
//
// ── THE CLAIM-EPOCH LAW, as this client honours it ──────────────────────────
//
//   pulse    holder-only, NO epoch argument, and it BUMPS the epoch.
//   stamp    holder-only AND epoch-fenced; a met-flip additionally requires
//            the criterion's stored wording verbatim (an index alone is
//            unverifiable → 409 criterion_text_required).
//   release  holder-only AND epoch-fenced; bumps the epoch.
//   claim    mints the epoch; refuses `not_ready` if someone else holds it.
//            A same-worker re-claim is a RENEWAL, not an error.
//   close    NOT WIRED HERE. Closing is not triage.
//
// "Fence-free" means: the actions a plain member can take WITHOUT stealing
// another worker's fence. So this machine NEVER attempts a write it can see
// is fenced — it refuses in the UI first, naming the holder. The only
// refusals that reach the server are the ones we could not have known about
// (a race), and those are surfaced with the server's own words.
//
// THE TRAP (recorded in the wave log): a pulse bumps the claim epoch, so a
// stamp issued with a pre-pulse epoch 409s. It is closed here STRUCTURALLY,
// not by discipline: the epoch is only ever read from the CURRENT doc, and
// every write's 200 body replaces that doc — so a successful pulse installs
// its own fresh epoch before any later stamp can be built. Single-flight
// (one write at a time) closes the remaining interleaving window.
import {
  describeTaskError,
  type TaskCriterion,
  type TaskDetail,
  type TaskDoc,
} from '../api/tasks'

/** Server ceiling on a pulse's now-line (400 `now must be at most 500 bytes`).
 * Enforced client-side so an over-long line is a refusal, not a round trip. */
export const PULSE_MAX_BYTES = 500

// ── state ────────────────────────────────────────────────────────────────────

export type TriageAction = 'stamp' | 'pulse' | 'claim' | 'release'

/** One optimistic write in flight. Because the rendered view is DERIVED from
 * (server truth + this op), rollback is nothing but dropping it — there is no
 * second copy of the truth to un-corrupt. */
export interface PendingOp {
  opId: number
  action: TriageAction
  /** stamp only */
  criterion?: number
  met?: boolean
  evidence?: string
  note?: string
  /** pulse only */
  nowText?: string
}

export type NoticeTone = 'ok' | 'refused' | 'failed'

/** The one honest line under the action bar. `refused` = we declined locally
 * (the fence was visible); `failed` = the server declined, quoted verbatim. */
export interface Notice {
  tone: NoticeTone
  text: string
}

export interface TriageState {
  docId: string
  /** This device's board identity — the fence is per-worker. */
  worker: string
  phase: 'loading' | 'error' | 'ready'
  /** phase === 'error' only. */
  message: string
  detail?: TaskDetail
  pending?: PendingOp
  notice?: Notice
  /** A background re-read is running (pull-to-refresh, or the forced re-read
   * after a fence refusal). */
  refreshing: boolean
  /** Set when the server told us our view of the claim is behind. The UI
   * blocks epoch-fenced actions until the re-read lands. */
  staleEpoch: boolean
  nextOpId: number
}

export function initialTriageState(docId: string, worker: string): TriageState {
  return {
    docId,
    worker,
    phase: 'loading',
    message: '',
    refreshing: false,
    staleEpoch: false,
    nextOpId: 1,
  }
}

// ── events ───────────────────────────────────────────────────────────────────

export type TriageEvent =
  | { type: 'loaded'; detail: TaskDetail }
  | { type: 'loadFailed'; message: string }
  | { type: 'refresh' }
  | { type: 'stamp'; criterion: number; met: boolean; text: string }
  | { type: 'pulse'; text: string }
  | { type: 'claim' }
  | { type: 'release' }
  | { type: 'opSucceeded'; opId: number; doc: TaskDoc }
  | { type: 'opFailed'; opId: number; error: unknown }
  | { type: 'dismissNotice' }

// ── effects ──────────────────────────────────────────────────────────────────

export type TriageEffect =
  | { type: 'fetch' }
  | {
      type: 'stamp'
      opId: number
      worker: string
      observedEpoch: number
      criterion: number
      /** The stored wording, verbatim — the server's met-flip guard. */
      criterionText: string
      met: boolean
      evidence?: string
      note?: string
    }
  | { type: 'pulse'; opId: number; worker: string; now: string }
  | { type: 'claim'; opId: number; worker: string }
  | { type: 'release'; opId: number; worker: string; observedEpoch: number }

// ── fence ────────────────────────────────────────────────────────────────────

export type FenceVerdict = { allowed: true } | { allowed: false; reason: string }

/** Byte length of a UTF-8 encoding, without depending on TextEncoder (which
 * the RN polyfill installs late and jsdom may not have at all). */
export function utf8Bytes(s: string): number {
  let n = 0
  for (const ch of s) {
    const cp = ch.codePointAt(0) ?? 0
    if (cp < 0x80) n += 1
    else if (cp < 0x800) n += 2
    else if (cp < 0x10000) n += 3
    else n += 4
  }
  return n
}

function holderOf(doc: TaskDoc | undefined): string | undefined {
  const worker = doc?.claim?.worker
  return worker !== undefined && worker.trim() !== '' ? worker : undefined
}

/** Can `worker` take `action` on this doc without stealing a fence?
 *
 * The refusal text is OURS on purpose: a pre-emptive refusal is not a server
 * answer, so quoting one would be a lie. When a write does reach the server
 * and is refused, the server's own words are what the UI shows (see
 * `opFailed`). */
export function fenceCheck(
  doc: TaskDoc | undefined,
  worker: string,
  action: TriageAction,
): FenceVerdict {
  if (doc === undefined) return { allowed: false, reason: 'The task has not loaded yet.' }
  const holder = holderOf(doc)
  const held = doc.lifecycleStatus === 'in_progress' && holder !== undefined

  if (action === 'claim') {
    if (held && holder !== worker) {
      return {
        allowed: false,
        reason: `Held by ${holder} (epoch ${doc.claim?.epoch ?? '?'}) — claiming it would steal their fence.`,
      }
    }
    return { allowed: true }
  }

  // stamp / pulse / release are all holder-only.
  if (holder === undefined) {
    return {
      allowed: false,
      reason: `No one holds this task — claim it first (${action} is holder-only).`,
    }
  }
  if (holder !== worker) {
    return {
      allowed: false,
      reason: `Held by ${holder} since ${doc.claim?.tsIso ?? 'unknown'} — ${action} is holder-only, so this is not yours to take.`,
    }
  }
  return { allowed: true }
}

/** The epoch every fenced write must carry — read from the CURRENT doc only. */
export function currentEpoch(state: TriageState): number | undefined {
  return state.detail?.doc.claim?.epoch
}

// ── derived views (the optimistic overlay) ───────────────────────────────────

export interface CriterionView extends TaskCriterion {
  /** An unconfirmed local write is painted on this row. */
  pending: boolean
}

/** Server truth with the in-flight stamp painted on top. Rollback needs no
 * code: drop the pending op and this returns to truth by construction. */
export function criteriaView(state: TriageState): CriterionView[] {
  const rows = state.detail?.doc.criteria ?? []
  const op = state.pending
  return rows.map((row, index) => {
    if (op === undefined || op.action !== 'stamp' || op.criterion !== index) {
      return { ...row, pending: false }
    }
    if (op.met === true) {
      const next: CriterionView = { ...row, met: true, pending: true }
      if (op.evidence !== undefined) next.evidence = op.evidence
      return next
    }
    return {
      ...row,
      pending: true,
      attempts: [...row.attempts, { note: op.note ?? '' }],
    }
  })
}

export interface NowView {
  text: string
  ts?: string
  criterion?: number
  pending: boolean
}

/** The claim's now-line WITH its timestamp — a stale pulse must read stale. */
export function nowView(state: TriageState): NowView | undefined {
  const op = state.pending
  if (op !== undefined && op.action === 'pulse') {
    return { text: op.nowText ?? '', pending: true }
  }
  const now = state.detail?.doc.claim?.now
  if (now === undefined || now.text === undefined || now.text === '') return undefined
  const view: NowView = { text: now.text, pending: false }
  if (now.ts !== undefined) view.ts = now.ts
  if (now.criterion !== undefined) view.criterion = now.criterion
  return view
}

/** met/total for the header, honouring the optimistic overlay so the count
 * moves the instant the user taps (and moves back on rollback). */
export function progressView(state: TriageState): { met: number; total: number } {
  const rows = criteriaView(state)
  return { met: rows.filter((r) => r.met).length, total: rows.length }
}

// ── reduce ───────────────────────────────────────────────────────────────────

type Out = { state: TriageState; effects: TriageEffect[] }

function refuse(state: TriageState, text: string): Out {
  return { state: { ...state, notice: { tone: 'refused', text } }, effects: [] }
}

export function reduce(state: TriageState, ev: TriageEvent): Out {
  switch (ev.type) {
    case 'loaded': {
      // A landing read is authoritative: it clears the stale-epoch brake and
      // any in-flight optimism it cannot vouch for is already gone (writes are
      // single-flight, and a fence refusal drops the op before asking).
      return {
        state: { ...state, phase: 'ready', message: '', detail: ev.detail, refreshing: false, staleEpoch: false },
        effects: [],
      }
    }

    case 'loadFailed': {
      if (state.detail !== undefined) {
        // A failed REFRESH must not blank a screen that already has truth.
        return {
          state: { ...state, refreshing: false, notice: { tone: 'failed', text: ev.message } },
          effects: [],
        }
      }
      return { state: { ...state, phase: 'error', message: ev.message, refreshing: false }, effects: [] }
    }

    case 'refresh':
      return { state: { ...state, refreshing: true }, effects: [{ type: 'fetch' }] }

    case 'dismissNotice': {
      const next = { ...state }
      delete next.notice
      return { state: next, effects: [] }
    }

    case 'stamp': {
      if (state.pending !== undefined) return refuse(state, 'A write is already in flight.')
      const doc = state.detail?.doc
      const verdict = fenceCheck(doc, state.worker, 'stamp')
      if (!verdict.allowed) return refuse(state, verdict.reason)
      if (state.staleEpoch) {
        return refuse(state, 'The claim moved under us — re-reading the task before stamping.')
      }
      const epoch = currentEpoch(state)
      if (epoch === undefined) {
        return refuse(state, 'No claim epoch on this task yet — re-read it before stamping.')
      }
      const row = doc?.criteria[ev.criterion]
      if (row === undefined) {
        return refuse(
          state,
          `Criterion ${ev.criterion} is not on this task any more — refresh before stamping.`,
        )
      }
      const text = ev.text.trim()
      if (ev.met && text === '') {
        return refuse(state, 'A met-flip needs evidence — the server rejects an empty one.')
      }
      if (!ev.met && text === '') {
        return refuse(state, 'A miss needs a note saying what was actually tried.')
      }
      const opId = state.nextOpId
      const op: PendingOp = { opId, action: 'stamp', criterion: ev.criterion, met: ev.met }
      const effect: TriageEffect = {
        type: 'stamp',
        opId,
        worker: state.worker,
        observedEpoch: epoch,
        criterion: ev.criterion,
        // Verbatim from the row we are looking at — the server's met-flip
        // guard, honoured client-side rather than guessed.
        criterionText: row.criterion,
        met: ev.met,
      }
      if (ev.met) {
        op.evidence = text
        effect.evidence = text
      } else {
        op.note = text
        effect.note = text
      }
      const next = { ...state, pending: op, nextOpId: opId + 1 }
      delete next.notice
      return { state: next, effects: [effect] }
    }

    case 'pulse': {
      if (state.pending !== undefined) return refuse(state, 'A write is already in flight.')
      const verdict = fenceCheck(state.detail?.doc, state.worker, 'pulse')
      if (!verdict.allowed) return refuse(state, verdict.reason)
      const text = ev.text.trim()
      if (text === '') return refuse(state, 'A pulse needs a now-line.')
      if (utf8Bytes(text) > PULSE_MAX_BYTES) {
        return refuse(state, `A now-line is capped at ${PULSE_MAX_BYTES} bytes.`)
      }
      const opId = state.nextOpId
      const next = {
        ...state,
        pending: { opId, action: 'pulse' as const, nowText: text },
        nextOpId: opId + 1,
      }
      delete next.notice
      return { state: next, effects: [{ type: 'pulse', opId, worker: state.worker, now: text }] }
    }

    case 'claim': {
      if (state.pending !== undefined) return refuse(state, 'A write is already in flight.')
      const verdict = fenceCheck(state.detail?.doc, state.worker, 'claim')
      if (!verdict.allowed) return refuse(state, verdict.reason)
      const opId = state.nextOpId
      const next = { ...state, pending: { opId, action: 'claim' as const }, nextOpId: opId + 1 }
      delete next.notice
      return { state: next, effects: [{ type: 'claim', opId, worker: state.worker }] }
    }

    case 'release': {
      if (state.pending !== undefined) return refuse(state, 'A write is already in flight.')
      const verdict = fenceCheck(state.detail?.doc, state.worker, 'release')
      if (!verdict.allowed) return refuse(state, verdict.reason)
      if (state.staleEpoch) {
        return refuse(state, 'The claim moved under us — re-reading the task before releasing.')
      }
      const epoch = currentEpoch(state)
      if (epoch === undefined) return refuse(state, 'No claim epoch to release against.')
      const opId = state.nextOpId
      const next = { ...state, pending: { opId, action: 'release' as const }, nextOpId: opId + 1 }
      delete next.notice
      return {
        state: next,
        effects: [{ type: 'release', opId, worker: state.worker, observedEpoch: epoch }],
      }
    }

    case 'opSucceeded': {
      // Late answer for an op we already rolled back / superseded: ignore it
      // rather than resurrect stale truth.
      if (state.pending?.opId !== ev.opId) return { state, effects: [] }
      const action = state.pending.action
      const detail: TaskDetail =
        state.detail !== undefined
          ? { ...state.detail, doc: ev.doc }
          : { doc: ev.doc, children: [], childCount: 0 }
      const next: TriageState = {
        ...state,
        detail,
        staleEpoch: false,
        notice: { tone: 'ok', text: confirmationFor(action, ev.doc) },
      }
      delete next.pending
      return { state: next, effects: [] }
    }

    case 'opFailed': {
      if (state.pending?.opId !== ev.opId) return { state, effects: [] }
      // ROLLBACK: the optimistic paint is derived from `pending`, so dropping
      // it restores server truth exactly.
      const reason = reasonOf(ev.error)
      const next: TriageState = {
        ...state,
        notice: { tone: 'failed', text: describeTaskError(ev.error) },
      }
      delete next.pending
      if (RE_READ_REASONS.has(reason)) {
        // Our view of the claim is provably behind (the pulse-bumps-the-epoch
        // trap is the classic case). Brake the fenced actions and re-read.
        next.staleEpoch = true
        next.refreshing = true
        return { state: next, effects: [{ type: 'fetch' }] }
      }
      return { state: next, effects: [] }
    }
  }
}

/** Server reasons that mean "your snapshot of the claim/criteria is stale" —
 * every one of them is answered by re-reading, never by retrying blind. */
const RE_READ_REASONS = new Set([
  'fenced_off',
  'stale_claim',
  'not_holder',
  'not_ready',
  'doc_changed_since_claim',
  'criteria_mismatch',
  'criteria_index_out_of_range',
  'criterion_text_required',
])

function reasonOf(error: unknown): string {
  const reason = (error as { reason?: unknown } | undefined)?.reason
  return typeof reason === 'string' ? reason : ''
}

function confirmationFor(action: TriageAction, doc: TaskDoc): string {
  const epoch = doc.claim?.epoch
  switch (action) {
    case 'stamp':
      return 'Criterion stamped.'
    case 'pulse':
      // Naming the new epoch is the honest thing: the pulse just moved the
      // fence, and the number on screen is what the next stamp will carry.
      return epoch !== undefined ? `Pulsed — claim epoch is now ${epoch}.` : 'Pulsed.'
    case 'claim':
      return epoch !== undefined ? `Claimed at epoch ${epoch}.` : 'Claimed.'
    case 'release':
      return 'Released — the task is back on the queue.'
  }
}
