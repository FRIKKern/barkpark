// The triage shell — a plain-TS store around the pure reducer, the exact twin
// of src/chat/sessionStore.ts: taps become TriageEvents, TriageEffects become
// HTTP. The reducer owns ALL fence semantics; this store owns none.
// Deliberately React-free (useTaskTriage subscribes via useSyncExternalStore)
// so the whole shell — optimistic paint, rollback, the forced re-read after a
// fence refusal — is drivable in a test with a fake API.
import type { InstanceConnection } from '../api/instance'
import {
  claimTask,
  fetchTaskDetail,
  pulseTask,
  releaseTask,
  stampCriterion,
  type StampRequest,
  type TaskDetail,
  type TaskDoc,
} from '../api/tasks'
import { initialTriageState, reduce, type TriageEffect, type TriageEvent, type TriageState } from './triage'

/** The IO seam. Injected in tests; defaults to the real /v1/tasks calls. */
export interface TriageApi {
  fetch: (docId: string) => Promise<TaskDetail>
  stamp: (req: StampRequest) => Promise<TaskDoc>
  pulse: (req: { docId: string; worker: string; now: string }) => Promise<TaskDoc>
  claim: (req: { docId: string; worker: string }) => Promise<TaskDoc>
  release: (req: { docId: string; worker: string; observedEpoch: number }) => Promise<TaskDoc>
}

export function apiFor(connection: InstanceConnection): TriageApi {
  return {
    fetch: (docId) => fetchTaskDetail(connection, docId),
    stamp: (req) => stampCriterion(connection, req),
    pulse: (req) => pulseTask(connection, req),
    claim: (req) => claimTask(connection, req),
    release: (req) => releaseTask(connection, req),
  }
}

export class TriageStore {
  private snapshot: TriageState
  private readonly listeners = new Set<() => void>()
  private stopped = false

  constructor(
    private readonly api: TriageApi,
    docId: string,
    worker: string,
  ) {
    this.snapshot = initialTriageState(docId, worker)
  }

  readonly subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  readonly getSnapshot = (): TriageState => this.snapshot

  /** TRUE PAIR with stop() (charter D25 twin of ChatSessionStore): restart
   * clears the stopped latch and re-reads, so a remounted screen gets a live
   * store again instead of a permanently inert one. */
  start(): void {
    this.stopped = false
    this.load(this.snapshot.writeGeneration)
  }

  stop(): void {
    this.stopped = true
  }

  refresh(): void {
    this.dispatch({ type: 'refresh' })
  }

  stamp(criterion: number, met: boolean, text: string): void {
    this.dispatch({ type: 'stamp', criterion, met, text })
  }

  pulse(text: string): void {
    this.dispatch({ type: 'pulse', text })
  }

  claim(): void {
    this.dispatch({ type: 'claim' })
  }

  release(): void {
    this.dispatch({ type: 'release' })
  }

  dismissNotice(): void {
    this.dispatch({ type: 'dismissNotice' })
  }

  /** Test/imperative seam: dispatch straight into the reducer. */
  dispatch(ev: TriageEvent): void {
    if (this.stopped) return
    const { state, effects } = reduce(this.snapshot, ev)
    if (state !== this.snapshot) this.set(state)
    for (const eff of effects) this.run(eff)
  }

  /** `generation` is captured BEFORE the request goes out and echoed back on
   * the answer: that is the whole write/read reorder fix (triage.ts `loaded`).
   * A response that lands after a write has installed newer truth carries the
   * older generation and the reducer drops it. */
  private load(generation: number): void {
    this.api
      .fetch(this.snapshot.docId)
      .then((detail) => this.dispatch({ type: 'loaded', detail, generation }))
      .catch((err: unknown) => this.dispatch({ type: 'loadFailed', message: message(err) }))
  }

  private run(eff: TriageEffect): void {
    const docId = this.snapshot.docId
    switch (eff.type) {
      case 'fetch':
        this.load(eff.generation)
        break
      case 'stamp': {
        const req: StampRequest = {
          docId,
          worker: eff.worker,
          observedEpoch: eff.observedEpoch,
          criterion: eff.criterion,
          met: eff.met,
        }
        if (eff.met) {
          req.criterionText = eff.criterionText
          req.evidence = eff.evidence ?? ''
        } else {
          req.note = eff.note ?? ''
        }
        this.settle(eff.opId, this.api.stamp(req))
        break
      }
      case 'pulse':
        this.settle(eff.opId, this.api.pulse({ docId, worker: eff.worker, now: eff.now }))
        break
      case 'claim':
        this.settle(eff.opId, this.api.claim({ docId, worker: eff.worker }))
        break
      case 'release':
        this.settle(
          eff.opId,
          this.api.release({ docId, worker: eff.worker, observedEpoch: eff.observedEpoch }),
        )
        break
    }
  }

  /** Every write lands as exactly one opSucceeded/opFailed — the reducer
   * decides what that means for the optimistic paint. */
  private settle(opId: number, work: Promise<TaskDoc>): void {
    work
      .then((doc) => this.dispatch({ type: 'opSucceeded', opId, doc }))
      .catch((error: unknown) => this.dispatch({ type: 'opFailed', opId, error }))
  }

  private set(state: TriageState): void {
    this.snapshot = state
    for (const listener of this.listeners) listener()
  }
}

function message(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}
