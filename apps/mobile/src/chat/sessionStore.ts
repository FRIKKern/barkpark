// The session shell — a plain-TS store around the pure reducer, the mobile
// twin of the Go TUI's model.go execEffect seam: UI events become ChatEvents,
// ChatEffects become IO (HTTP POSTs / the turn-boundary GET), and every SSE
// frame is dispatched straight into reduce(). The reducer owns ALL turn
// semantics; this store owns none — it is wiring, timers, and the stream
// lifecycle. Deliberately React-free (the useChatSession hook subscribes via
// useSyncExternalStore), so the whole shell is constructible in a test.
import type { InstanceConnection } from '../api/instance'
import {
  getChatSession,
  interruptChat,
  patchChatSession,
  respondChatApproval,
  sendChatMessage,
  streamChatEvents,
  type StreamFailure,
  type StreamStatus,
} from '../api/chat'
import {
  HYDRATION_GEN,
  initialChatState,
  reduce,
  type ChatEffect,
  type ChatEvent,
  type ChatState,
} from './reducer'
import type { ChatSession } from './wire'

// The wedge timer's clock (reduce.go ticks at 100ms; 500ms keeps the same 8s
// semantics with less wakeup churn on a phone).
const TICK_MS = 500

// The five-state stream vocabulary is OWNED by the transport (charter D24 —
// src/api/chat.ts produces it); re-exported here so consumers of the store
// don't have to reach into the api layer for the type.
export type { StreamFailure, StreamStatus } from '../api/chat'

// ── the notify coalescer (lane 2 M4) ─────────────────────────────────────────

/** How a coalesced notify is deferred. Injectable ONLY so jest can drive the
 * seam on a queue it controls; production always uses the microtask. */
export type NotifyScheduler = (run: () => void) => void

export const microtask: NotifyScheduler = (run) => {
  void Promise.resolve().then(run)
}

export interface NotifyCoalescer {
  /** Announce eventually — N schedules inside one tick collapse to ONE notify. */
  schedule(): void
  /** Announce NOW, and swallow any coalesced notify already in flight. */
  flush(): void
  /** Drop a pending notify without announcing (the store's stop()). */
  cancel(): void
}

/** THE BATCHING SEAM — and it sits here, at set()/notify, deliberately NOT in
 * the reducer. reduce() keeps running once per SSE frame, so the D77
 * gen/tailGen fence sees exactly the frame sequence it was proven against; all
 * that is batched is how often listeners are TOLD. Pure apart from the
 * injected scheduler, so the whole law is jest-drivable.
 *
 * `dirty` is what makes flush() honest: it cancels the pending announcement
 * rather than racing it, so an immediate event can never be followed by a
 * duplicate coalesced notify for state that was already delivered. */
export function createNotifyCoalescer(
  notify: () => void,
  schedule: NotifyScheduler = microtask,
): NotifyCoalescer {
  let scheduled = false
  let dirty = false
  return {
    schedule(): void {
      dirty = true
      if (scheduled) return
      scheduled = true
      schedule(() => {
        scheduled = false
        if (!dirty) return
        dirty = false
        notify()
      })
    },
    flush(): void {
      dirty = false
      notify()
    },
    cancel(): void {
      dirty = false
    },
  }
}

/** The ONE delta safe to coalesce: the streaming tail grew and NOTHING else
 * moved. Every other transition — an init frame, a turn settling, a card
 * arriving, a phase or notice change — flushes immediately, because those are
 * the moments the user is waiting on and a microtask of latency on them buys
 * nothing.
 *
 * Written as an exhaustive field comparison rather than a role guess on the
 * event: a future reducer field that a delta starts touching then falls out of
 * the coalesced path automatically (it stops looking tail-only), which fails
 * SAFE — toward more notifies, never toward a swallowed one. */
export function tailOnlyGrowth(prev: ChatState, next: ChatState): boolean {
  if (next === prev || next.tail === prev.tail) return false
  return (
    next.messages === prev.messages &&
    next.local === prev.local &&
    next.answerInFlight === prev.answerInFlight &&
    next.sessionId === prev.sessionId &&
    next.title === prev.title &&
    next.lastSeq === prev.lastSeq &&
    next.model === prev.model &&
    next.mode === prev.mode &&
    next.phase === prev.phase &&
    next.settling === prev.settling &&
    next.wedgeAtMs === prev.wedgeAtMs &&
    next.gen === prev.gen &&
    next.tailGen === prev.tailGen &&
    // The live-document fields (D59): a `stable` frame never moves the tail, so
    // it already flushes immediately by the first guard above. They are listed
    // anyway because this comparison's whole contract is EXHAUSTIVENESS — the
    // day a delta starts touching one of them, the coalesced path must open
    // rather than quietly keep swallowing a structural change.
    next.segments === prev.segments &&
    next.stableTurn === prev.stableTurn &&
    next.committedBytes === prev.committedBytes &&
    next.committedChars === prev.committedChars &&
    next.skeleton === prev.skeleton &&
    next.stableStopped === prev.stableStopped &&
    next.stableEnd === prev.stableEnd &&
    next.stableGap === prev.stableGap &&
    next.tailCarried === prev.tailCarried &&
    next.settleArm === prev.settleArm &&
    next.suppressed === prev.suppressed &&
    next.notice === prev.notice &&
    next.exited === prev.exited
  )
}

/** The session's PERSISTED CHOICES — what the user asked for, kept beside the
 * reducer rather than inside it.
 *
 * This deliberately does NOT live in ChatState. The reducer is the D77 turn
 * machine: its `model` field is the OBSERVED model off system/init (fact,
 * empty until a turn streams), and mixing a request into that machine is
 * exactly the conflation ratified call #5 forbids. So the store carries the
 * requests, the reducer carries the observation, and the picker renders both
 * as the two different things they are. */
export interface SessionChoices {
  /** Which engine answers — the key the picker vocabulary is looked up under.
   * '' until the seed GET lands. */
  provider: string
  /** The persisted permission-mode request. */
  mode: string
  /** The persisted model REQUEST (may differ from the observed model). */
  modelChoice: string
  /** The persisted effort REQUEST (no observed counterpart exists). */
  effortChoice: string
}

export function emptyChoices(): SessionChoices {
  return { provider: '', mode: '', modelChoice: '', effortChoice: '' }
}

export interface SessionSnapshot {
  state: ChatState
  /** The persisted choices, refreshed by every session GET (seed + every
   * turn-boundary tail refetch) and written optimistically by setChoice. */
  choices: SessionChoices
  /** true until the initial full GET resolves (or fails). */
  loading: boolean
  /** initial-load failure — the screen renders error-with-retry. */
  loadError: string | undefined
  /** transport failures of fire-and-forget POSTs (send/interrupt/setChoice).
   *
   * RECONCILED write/clear ledger (mob-bl-transport-error-sticky) — set() is a
   * shallow merge, so any field without a deliberate clear survives every later
   * write. Every writer therefore has a matching clear, plus one global one:
   *   writes:  send-fail, interrupt-fail, setChoice-fail
   *   clears:  send() entry, interrupt() entry, setChoice() entry (a fresh
   *            attempt drops the old verdict), and onStatus('open') — a healthy
   *            stream is the transport re-asserting itself, so a stale failure
   *            must not outlive the transport it indicts. Without that last
   *            clear, one failed send masked every later reducer notice via the
   *            screen's `transportError ?? state.notice` until the next send. */
  transportError: string | undefined
  streamStatus: StreamStatus
  /** rides along with 'degraded'/'refused' — the refused header label needs
   * the HTTP status to say WHICH wall (signed out / gone / other). */
  streamFailure: StreamFailure | undefined
}

export class ChatSessionStore {
  private snapshot: SessionSnapshot
  private readonly listeners = new Set<() => void>()
  /** Per-start controller (charter D25): stop() aborts it PERMANENTLY, so a
   * restart provisions a fresh one — and every async closure captures its own
   * start's controller, never `this.controller` (reading the field in an old
   * closure would reintroduce the aborted-forever race). */
  private controller = new AbortController()
  private tick: ReturnType<typeof setInterval> | undefined
  private stopped = false
  /** Per-start fence (D25): callbacks from a superseded start — its stream's
   * unconditional terminal 'closed', a late seed GET — must never clobber the
   * live start's state. */
  private startGen = 0
  /** Tail deltas announce through here (lane 2 M4). Constructed per store so
   * two live sessions never share a pending notify. */
  private readonly notifier: NotifyCoalescer

  constructor(
    private readonly connection: InstanceConnection,
    private readonly sessionId: string,
    schedule: NotifyScheduler = microtask,
  ) {
    this.notifier = createNotifyCoalescer(() => {
      for (const listener of this.listeners) listener()
    }, schedule)
    this.snapshot = {
      state: initialChatState(sessionId),
      choices: emptyChoices(),
      loading: true,
      loadError: undefined,
      transportError: undefined,
      streamStatus: 'connecting',
      streamFailure: undefined,
    }
  }

  readonly subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  readonly getSnapshot = (): SessionSnapshot => this.snapshot

  /** Kick off the initial full GET (since=0 — seeds messages, title, mode),
   * then the SSE stream with Last-Event-ID at the seeded cursor, plus the
   * wedge tick. TRUE PAIR with stop() (charter D25): on RUNNING it no-ops
   * (the tick handle is the running marker — stop() nulls it); after stop()
   * it RESTARTS — clears the stopped latch, provisions a FRESH per-start
   * AbortController, and re-runs seed GET + SSE + tick. */
  start(): void {
    if (this.tick !== undefined) return // already running — a second start() is a no-op
    this.stopped = false
    const gen = ++this.startGen
    const controller = new AbortController()
    this.controller = controller
    this.set({
      loading: true,
      loadError: undefined,
      streamStatus: 'connecting',
      streamFailure: undefined,
    })
    void (async () => {
      try {
        const session = await getChatSession(this.connection, this.sessionId, 0)
        if (this.stopped || gen !== this.startGen) return
        // HYDRATION, not a settle: a re-attach (background→foreground, a screen
        // remount) re-runs this seed GET while a turn may still be streaming,
        // and the zero this used to pass MATCHED the attach-mid-turn tail
        // (gen === tailGen === 0 until an init frame is observed) and wiped it.
        this.dispatch({ type: 'tailFetched', gen: HYDRATION_GEN, session })
        this.set({ loading: false, choices: choicesFrom(this.snapshot.choices, session) })
      } catch (err) {
        if (this.stopped || gen !== this.startGen) return
        this.set({ loading: false, loadError: message(err) })
        return
      }
      void streamChatEvents(this.connection, this.sessionId, {
        signal: controller.signal,
        lastEventId: String(this.snapshot.state.lastSeq),
        onFrame: (frame) => {
          // Fenced per start: a superseded stream may still be draining.
          if (this.stopped || gen !== this.startGen) return
          this.dispatch({ type: 'frame', name: frame.event, data: frame.data })
        },
        onStatus: (streamStatus, streamFailure) => {
          // Fenced per start: streamChatEvents emits a terminal status on loop
          // exit — a superseded stream's 'closed' must never clobber the live
          // stream's status.
          if (this.stopped || gen !== this.startGen) return
          // A healthy stream clears a stale POST failure (the reconciled-ledger
          // clear at the field declaration). ONLY 'open' clears — a degraded or
          // refused status is not evidence the transport recovered, and wiping
          // the error on it would be the same claim-without-evidence in the
          // other direction.
          if (streamStatus === 'open') {
            this.set({ streamStatus, streamFailure, transportError: undefined })
          } else {
            this.set({ streamStatus, streamFailure })
          }
        },
      })
    })()
    this.tick = setInterval(() => this.dispatch({ type: 'tick' }), TICK_MS)
  }

  stop(): void {
    this.stopped = true
    // A coalesced tail notify must not land after teardown — the listeners are
    // already gone, and firing into them is noise the store can simply not make.
    this.notifier.cancel()
    if (this.tick !== undefined) {
      clearInterval(this.tick)
      this.tick = undefined // start()'s running marker — stop() must null it (D25)
    }
    this.controller.abort()
  }

  send(content: string): void {
    this.set({ transportError: undefined })
    this.dispatch({ type: 'send', content })
  }

  interrupt(): void {
    // Entry-clear, same as send()/setChoice(): a fresh attempt drops the old
    // verdict — and without it 'interrupting…' (a reducer notice this very
    // dispatch produces) stayed hidden behind a stale send failure.
    this.set({ transportError: undefined })
    this.dispatch({ type: 'interrupt' })
  }

  answer(requestId: string, decision: 'allow' | 'deny'): void {
    this.dispatch({ type: 'answer', requestId, decision })
  }

  /** Writes one picker choice: optimistic locally, PATCHed to the server.
   *
   * Optimism is the right default here because the write is cheap and its
   * truth is re-asserted for free — every turn-boundary tail refetch overwrites
   * `choices` from the server row, so a rejected PATCH self-corrects within one
   * turn without a poll of its own. A failure surfaces honestly as a
   * transportError AND rolls the field back, so a dead write never leaves the
   * sheet claiming a choice the server refused.
   *
   * THE ROLLBACK IS FENCED ON THE FIELD IT WROTE, and it did not used to be.
   * The handler captured `before` at call time and wrote `before[key]` into the
   * CURRENT snapshot, so a slow failure could overwrite a NEWER choice the
   * server had already accepted: tap `plan` (call A captures 'acceptEdits'),
   * tap `default` a second later (call B succeeds, server now holds 'default'),
   * then A's PATCH times out — A's catch writes 'acceptEdits', a value neither
   * the user nor the server ever chose, and raises an error naming a write the
   * user had already replaced. start()'s own three closures fence on
   * `gen !== this.startGen`; this one checked only `this.stopped` — and so, it
   * turned out, did all five inside run() (fenced since; see the note there).
   *
   * The fence is a per-field compare-and-swap rather than a generation, because
   * the unit at risk is the FIELD: two writes to different keys never conflict,
   * and a generation counter would make them. If `choices[key]` is no longer the
   * value THIS call wrote, a later write owns the field and this failure is not
   * entitled to touch it — nor to raise an error about it, because the value the
   * user is looking at came from that later write, and its own failure (if any)
   * reports itself. A stale error next to a correct value reads as a bug in the
   * value. */
  setChoice(key: keyof SessionChoices, value: string): void {
    if (key === 'provider') return // provider is server truth, never a client write
    const before = this.snapshot.choices
    this.set({ transportError: undefined, choices: { ...before, [key]: value } })
    const field =
      key === 'mode' ? 'mode' : key === 'modelChoice' ? 'model_choice' : 'effort_choice'
    patchChatSession(this.connection, this.sessionId, { [field]: value }).catch(
      (err: unknown) => {
        if (this.stopped) return
        // SUPERSEDED: a later setChoice moved this field on. That write owns it.
        if (this.snapshot.choices[key] !== value) return
        // Still ours — roll back to the value the server still holds, then say so.
        this.set({
          choices: { ...this.snapshot.choices, [key]: before[key] },
          transportError: `could not set ${field} — ${message(err)}`,
        })
      },
    )
  }

  private dispatch(ev: ChatEvent): void {
    if (this.stopped) return
    const prev = this.snapshot.state
    const { state, effects } = reduce(prev, ev, Date.now())
    // The reducer ran per-frame, exactly as before. The only judgment made
    // here is how urgently listeners hear about it (lane 2 M4).
    if (state !== prev) this.set({ state }, tailOnlyGrowth(prev, state))
    for (const eff of effects) this.run(eff)
  }

  private run(eff: ChatEffect): void {
    // THE START THIS EFFECT BELONGS TO. stop() cancels the STREAM (the
    // AbortController) and nothing else — an in-flight POST or turn-boundary
    // GET keeps running, and the very next start() clears `stopped`, so a
    // callback from a superseded start lands on the LIVE store instead of
    // being dropped. `stopped` alone is therefore not a fence; it is a pause
    // that the thing it is fencing outlives.
    //
    // THE DISTINCTION THIS DRAWS, and it is not cosmetic. REDUCER state
    // survives a restart — the store keeps its ChatState across stop()/start()
    // — so a superseded settle, answer or send-failure still describes rows the
    // live view is painting, and each of those events carries a fence of its
    // own (eff.gen for the tail, requestId for an answer, the echo's content
    // for a failed send). Those must still be DISPATCHED: dropping them would
    // leave a permanent in-flight badge, or an echo painted as delivered that
    // nothing will ever retire.
    //
    // What must NOT survive is the SNAPSHOT chrome a dead start writes with no
    // fence of its own — the picker `choices` and the `transportError` banner.
    // A superseded refetch overwriting `choices` is setChoice's bug through
    // another door: it reverts a pick the server has already accepted. And a
    // banner about an action taken before the restart is the same stale error
    // beside a correct value that setChoice's note argues against.
    const gen = this.startGen
    const superseded = (): boolean => this.stopped || gen !== this.startGen

    switch (eff.type) {
      case 'fetchTail':
        getChatSession(this.connection, this.sessionId, eff.sinceSeq)
          .then((session) => {
            // The turn-boundary refetch re-asserts server truth over the
            // optimistic picker writes — the same "the server settles it"
            // discipline the TUI's ctrl+p flip already runs on.
            // Only for the start that asked: a fetch issued before a restart
            // carries the PRE-restart choices, and writing them here would
            // revert a pick made (and accepted) after it.
            if (!superseded()) this.set({ choices: choicesFrom(this.snapshot.choices, session) })
            this.dispatch({ type: 'tailFetched', gen: eff.gen, session })
          })
          .catch((err: unknown) =>
            this.dispatch({ type: 'tailFetched', gen: eff.gen, error: message(err) }),
          )
        break
      case 'sendMessage':
        sendChatMessage(this.connection, this.sessionId, eff.content).catch((err: unknown) => {
          if (this.stopped) return
          // The banner is this view's chrome, so a superseded start does not get
          // to raise one; the echo badge below is reducer state the live view is
          // still painting, so it lands either way.
          if (!superseded()) this.set({ transportError: `send failed — ${message(err)}` })
          // The banner alone is not enough: the optimistic echo is still
          // painted as a delivered message and nothing else will ever retire it
          // (no persisted row exists for a POST the server refused). Tell the
          // reducer, so the bubble itself says so.
          this.dispatch({ type: 'sendFailed', content: eff.content, error: message(err) })
        })
        break
      case 'interruptTurn':
        interruptChat(this.connection, this.sessionId).catch((err: unknown) => {
          if (!superseded()) this.set({ transportError: `interrupt failed — ${message(err)}` })
        })
        break
      case 'answerCard':
        respondChatApproval(
          this.connection,
          this.sessionId,
          eff.requestId,
          eff.decision as 'allow' | 'deny',
        )
          .then(() => this.dispatch({ type: 'answered', requestId: eff.requestId }))
          .catch((err: unknown) =>
            this.dispatch({ type: 'answered', requestId: eff.requestId, error: message(err) }),
          )
        break
    }
  }

  /** The snapshot is committed SYNCHRONOUSLY either way — getSnapshot always
   * returns the newest truth, so a coalesced notify can delay an announcement
   * but can never serve stale state to a listener that reads in between. */
  private set(patch: Partial<SessionSnapshot>, coalesce = false): void {
    this.snapshot = { ...this.snapshot, ...patch }
    if (coalesce) this.notifier.schedule()
    else this.notifier.flush()
  }
}

function message(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}

/** Folds a session read into the held choices. A blank/absent wire value KEEPS
 * the held one rather than erasing it: the `?since=` tail refetch is a partial
 * read of the same row, and an omitted key there means "unchanged", never
 * "cleared". */
function choicesFrom(held: SessionChoices, session: ChatSession): SessionChoices {
  const pick = (wire: string | undefined, current: string): string => {
    const v = (wire ?? '').trim()
    return v !== '' ? v : current
  }
  return {
    provider: pick(session.provider, held.provider),
    mode: pick(session.mode, held.mode),
    modelChoice: pick(session.model_choice, held.modelChoice),
    effortChoice: pick(session.effort_choice, held.effortChoice),
  }
}
