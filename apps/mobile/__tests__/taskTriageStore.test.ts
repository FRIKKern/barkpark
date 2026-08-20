// The triage SHELL proofs — the store wiring the pure reducer to /v1/tasks IO.
// A fake TriageApi stands in for the network, so the whole optimistic
// round trip (paint → request → 200/409 → confirm or roll back) is drivable
// end to end without a socket. Also pins the wire-shape parsing and the
// error-reason extraction the UI's honesty depends on.
import {
  describeTaskError,
  parseTaskDetail,
  parseTaskDoc,
  taskErrorFrom,
  TaskApiError,
  type TaskDoc,
} from '../src/api/tasks'
import { criteriaView, nowView } from '../src/tasks/triage'
import { TriageStore, type TriageApi } from '../src/tasks/triageStore'

const WORKER = 'mobile-abc12345'
const OTHER = 'loop-builder-7'

/** The server's real GET /v1/tasks/:doc_id envelope, trimmed to the keys that
 * matter (criteria live under content.acceptance_criteria; claim is a sibling
 * of doc, and the controller deletes content.claim). */
function envelope(over: { claim?: unknown; met?: boolean } = {}): unknown {
  return {
    ok: true,
    doc: {
      doc_id: 't1',
      title: 'Ship the triage',
      lifecycle_status: 'in_progress',
      priority: 1,
      assignee: 'mob',
      parent_id: 'goal-1',
      labels: ['mobile'],
      rev: 'r1',
      claim:
        'claim' in over
          ? over.claim
          : { worker: WORKER, epoch: 4, ts_iso: '2026-07-25T08:00:00Z' },
      content: {
        acceptance_criteria: [
          { criterion: 'gate passes', met: over.met === true, attempts: [] },
        ],
      },
      criteria_progress: { met: over.met === true ? 1 : 0, total: 1 },
    },
    children: [
      { doc_id: 'kid-1', title: 'a child', lifecycle_status: 'open', criteria_progress: { met: 1, total: 3 } },
    ],
    child_count: 1,
  }
}

function fakeApi(over: Partial<TriageApi> = {}): TriageApi {
  const base: TriageApi = {
    fetch: () => Promise.resolve(parseTaskDetail(envelope())),
    stamp: () => Promise.reject(new Error('stamp not stubbed')),
    pulse: () => Promise.reject(new Error('pulse not stubbed')),
    claim: () => Promise.reject(new Error('claim not stubbed')),
    release: () => Promise.reject(new Error('release not stubbed')),
  }
  return { ...base, ...over }
}

/** Lets every already-resolved promise in the chain settle. */
const flush = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0))

test('the store loads, paints a stamp optimistically, then confirms on the 200', async () => {
  const calls: unknown[] = []
  const store = new TriageStore(
    fakeApi({
      stamp: (req) => {
        calls.push(req)
        // The server echoes the whole doc; the criterion is now truly met.
        return Promise.resolve(parseTaskDoc((envelope({ met: true }) as { doc: unknown }).doc))
      },
    }),
    't1',
    WORKER,
  )
  store.start()
  await flush()
  expect(store.getSnapshot().phase).toBe('ready')
  expect(store.getSnapshot().detail?.childCount).toBe(1)

  store.stamp(0, true, 'jest green')
  // Painted before the promise settles.
  expect(criteriaView(store.getSnapshot())[0]?.pending).toBe(true)
  expect(criteriaView(store.getSnapshot())[0]?.met).toBe(true)

  await flush()
  const settled = store.getSnapshot()
  expect(settled.pending).toBeUndefined()
  expect(criteriaView(settled)[0]?.met).toBe(true)
  expect(criteriaView(settled)[0]?.pending).toBe(false)
  expect(settled.notice).toEqual({ tone: 'ok', text: 'Criterion stamped.' })

  // The request carried the fence: worker, the observed epoch, and the stored
  // wording verbatim.
  expect(calls).toEqual([
    {
      docId: 't1',
      worker: WORKER,
      observedEpoch: 4,
      criterion: 0,
      met: true,
      criterionText: 'gate passes',
      evidence: 'jest green',
    },
  ])
})

test('a 409 from the server rolls the paint back and re-reads once', async () => {
  let fetches = 0
  const store = new TriageStore(
    fakeApi({
      fetch: () => {
        fetches += 1
        return Promise.resolve(parseTaskDetail(envelope()))
      },
      stamp: () => Promise.reject(taskErrorFrom(409, JSON.stringify({ ok: false, reason: 'fenced_off' }))),
    }),
    't1',
    WORKER,
  )
  store.start()
  await flush()
  expect(fetches).toBe(1)

  store.stamp(0, true, 'jest green')
  expect(criteriaView(store.getSnapshot())[0]?.met).toBe(true)

  await flush()
  const settled = store.getSnapshot()
  expect(criteriaView(settled)[0]?.met).toBe(false) // rolled back
  expect(settled.notice).toEqual({ tone: 'failed', text: 'fenced_off' })
  await flush()
  expect(fetches).toBe(2) // the forced re-read landed
  expect(store.getSnapshot().staleEpoch).toBe(false)
})

test('a foreign claim never reaches the wire', async () => {
  let attempts = 0
  const store = new TriageStore(
    fakeApi({
      fetch: () =>
        Promise.resolve(
          parseTaskDetail(envelope({ claim: { worker: OTHER, epoch: 9, ts_iso: '2026-07-24T22:00:00Z' } })),
        ),
      stamp: () => {
        attempts += 1
        return Promise.reject(new Error('should never be called'))
      },
      pulse: () => {
        attempts += 1
        return Promise.reject(new Error('should never be called'))
      },
    }),
    't1',
    WORKER,
  )
  store.start()
  await flush()

  store.stamp(0, true, 'evidence')
  store.pulse('working')
  await flush()

  expect(attempts).toBe(0)
  expect(store.getSnapshot().notice?.tone).toBe('refused')
  expect(store.getSnapshot().notice?.text).toContain(OTHER)
})

test('a pulse round trip installs the bumped epoch for the next fenced write', async () => {
  const stampCalls: { observedEpoch: number }[] = []
  const pulsed: TaskDoc = parseTaskDoc({
    doc_id: 't1',
    title: 'Ship the triage',
    lifecycle_status: 'in_progress',
    claim: {
      worker: WORKER,
      epoch: 5, // ← the pulse bumped it
      ts_iso: '2026-07-25T08:00:00Z',
      now: { text: 'working', ts: '2026-07-25T08:10:00Z' },
    },
    content: { acceptance_criteria: [{ criterion: 'gate passes', met: false, attempts: [] }] },
  })
  const store = new TriageStore(
    fakeApi({
      pulse: () => Promise.resolve(pulsed),
      stamp: (req) => {
        stampCalls.push({ observedEpoch: req.observedEpoch })
        return Promise.resolve(pulsed)
      },
    }),
    't1',
    WORKER,
  )
  store.start()
  await flush()

  store.pulse('working')
  await flush()
  expect(nowView(store.getSnapshot())).toEqual({
    text: 'working',
    ts: '2026-07-25T08:10:00Z',
    pending: false,
  })

  store.stamp(0, true, 'evidence')
  await flush()
  expect(stampCalls).toEqual([{ observedEpoch: 5 }])
})

test('the store is restartable: stop() then start() re-reads — the D25 twin', async () => {
  let fetches = 0
  const store = new TriageStore(
    fakeApi({
      fetch: () => {
        fetches += 1
        return Promise.resolve(parseTaskDetail(envelope()))
      },
    }),
    't1',
    WORKER,
  )
  store.start()
  await flush()
  expect(fetches).toBe(1)
  expect(store.getSnapshot().phase).toBe('ready')

  store.stop()
  store.refresh() // a stopped store is inert — nothing reaches the wire
  await flush()
  expect(fetches).toBe(1)

  // start() clears the stopped latch and re-reads: the remounted screen gets
  // a LIVE store again, not a permanently dead one.
  store.start()
  await flush()
  expect(fetches).toBe(2)
  expect(store.getSnapshot().phase).toBe('ready')
  store.refresh()
  await flush()
  expect(fetches).toBe(3) // dispatch works again after the restart
})

// ── wire shapes ──────────────────────────────────────────────────────────────

test('parseTaskDoc reads the criteria off content.acceptance_criteria', () => {
  const parsed = parseTaskDoc((envelope() as { doc: unknown }).doc)
  expect(parsed.docId).toBe('t1')
  expect(parsed.parentId).toBe('goal-1')
  expect(parsed.claim).toEqual({ worker: WORKER, epoch: 4, tsIso: '2026-07-25T08:00:00Z' })
  expect(parsed.criteria).toEqual([{ criterion: 'gate passes', met: false, attempts: [] }])
  expect(parsed.criteriaProgress).toEqual({ met: 0, total: 1 })
})

test('only a boolean true counts as met — a truthy string does not', () => {
  const parsed = parseTaskDoc({
    doc_id: 't',
    content: {
      acceptance_criteria: [
        { criterion: 'a', met: 'true' },
        { criterion: 'b', met: true },
        { criterion: 'c' },
        { nope: 'no criterion key' },
      ],
    },
  })
  expect(parsed.criteria.map((c) => c.met)).toEqual([false, true, false])
})

test('attempts survive with their worker + ts (the honest-miss trail)', () => {
  const parsed = parseTaskDoc({
    doc_id: 't',
    content: {
      acceptance_criteria: [
        {
          criterion: 'a',
          met: false,
          attempts: [{ note: 'flaky', ts: '2026-07-25T08:00:00Z', worker: 'w1' }, { bad: 1 }],
        },
      ],
    },
  })
  expect(parsed.criteria[0]?.attempts).toEqual([
    { note: 'flaky', ts: '2026-07-25T08:00:00Z', worker: 'w1' },
  ])
})

test('taskErrorFrom keeps the server reason AND its message verbatim', () => {
  const err = taskErrorFrom(
    409,
    JSON.stringify({
      ok: false,
      reason: 'criterion_text_required',
      message: 'criterion 0 requires --criterion-text matching the stored wording',
    }),
  )
  expect(err).toBeInstanceOf(TaskApiError)
  expect(err.status).toBe(409)
  expect(err.reason).toBe('criterion_text_required')
  expect(describeTaskError(err)).toBe(
    'criterion_text_required: criterion 0 requires --criterion-text matching the stored wording',
  )

  // The 404 auth-floor oracle shape: not-found, never a permission word.
  const notFound = taskErrorFrom(404, JSON.stringify({ ok: false, reason: 'not_found', message: 'task not found' }))
  expect(notFound.reason).toBe('not_found')
  expect(describeTaskError(notFound)).toBe('not_found: task not found')

  // A non-JSON body degrades to the status, never an invented reason.
  const html = taskErrorFrom(502, '<html>bad gateway</html>')
  expect(html.reason).toBe('http_502')
})
