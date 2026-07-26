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
  respondChatApproval,
  sendChatMessage,
  streamChatEvents,
  type StreamFailure,
  type StreamStatus,
} from '../api/chat'
import {
  initialChatState,
  reduce,
  type ChatEffect,
  type ChatEvent,
  type ChatState,
} from './reducer'

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
    next.notice === prev.notice &&
    next.exited === prev.exited
  )
}

export interface SessionSnapshot {
  state: ChatState
  /** true until the initial full GET resolves (or fails). */
  loading: boolean
  /** initial-load failure — the screen renders error-with-retry. */
  loadError: string | undefined
  /** transport failures of fire-and-forget POSTs (send/interrupt). */
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
        this.dispatch({ type: 'tailFetched', gen: 0, session })
        this.set({ loading: false })
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
          this.set({ streamStatus, streamFailure })
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
    this.dispatch({ type: 'interrupt' })
  }

  answer(requestId: string, decision: 'allow' | 'deny'): void {
    this.dispatch({ type: 'answer', requestId, decision })
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
    switch (eff.type) {
      case 'fetchTail':
        getChatSession(this.connection, this.sessionId, eff.sinceSeq)
          .then((session) => this.dispatch({ type: 'tailFetched', gen: eff.gen, session }))
          .catch((err: unknown) =>
            this.dispatch({ type: 'tailFetched', gen: eff.gen, error: message(err) }),
          )
        break
      case 'sendMessage':
        sendChatMessage(this.connection, this.sessionId, eff.content).catch((err: unknown) => {
          if (!this.stopped) this.set({ transportError: `send failed — ${message(err)}` })
        })
        break
      case 'interruptTurn':
        interruptChat(this.connection, this.sessionId).catch((err: unknown) => {
          if (!this.stopped) this.set({ transportError: `interrupt failed — ${message(err)}` })
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
