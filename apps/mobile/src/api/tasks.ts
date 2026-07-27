// The /v1/tasks HTTP surface — the task DETAIL read plus the four
// fence-respecting triage writes (claim · pulse · stamp · release).
//
// TRANSPORT LAW (same as src/api/chat.ts): the tasks plugin mounts its routes
// ONLY on the flat `/v1/tasks/...` scope — `plugin_routes(scope: :token_root)`
// appears exactly once, inside `scope "/v1"`; there is no
// `/w/:ws/p/:proj/v1/tasks` mirror. So this module does NOT ride
// client.fetchRaw: the SDK's scoped escape hatch would prefix
// `/w/<ws>/p/<project>` and 404. Tenancy comes from the token's own binding
// (AssignDefaultScope), exactly as the Go CLI assumes.
//
// expoFetch is used throughout for consistency with the rest of the app's
// instance traffic (charter D14).
//
// PARSING IS PURE AND SEPARATE from the IO (parseTaskDoc / taskErrorFrom):
// the wire shapes are unit-tested without a socket, the same seam SseSplitter
// carved for chat.
import { fetch as expoFetch } from 'expo/fetch'

import type { InstanceConnection } from './instance'

// ── wire shapes ──────────────────────────────────────────────────────────────

/** One acceptance criterion, as stored. The wording key is `criterion` (NOT
 * `text`) and `met` counts only when it is exactly boolean true. `attempts`
 * are the last 5 honest misses. */
export interface TaskCriterion {
  criterion: string
  met: boolean
  evidence?: string
  attempts: TaskAttempt[]
}

export interface TaskAttempt {
  note: string
  ts?: string
  worker?: string
}

/** The claim block, verbatim from `content.claim`. `now` appears once the
 * holder has pulsed — and it carries its OWN timestamp, which is the whole
 * point: a stale pulse must READ stale on the board. */
export interface TaskClaim {
  worker?: string
  tsIso?: string
  epoch?: number
  now?: { text?: string; ts?: string; criterion?: number }
}

export interface TaskChild {
  doc_id: string
  title?: string
  lifecycle_status?: string
  criteria_progress?: { met: number; total: number }
}

/** The `doc` half of every task envelope — what both `GET /v1/tasks/:id` and
 * each write's 200 body carry. Writes return this WITHOUT children, so the
 * detail state keeps those separately. */
export interface TaskDoc {
  docId: string
  title: string
  rev?: string
  lifecycleStatus?: string
  priority?: number
  assignee?: string
  parentId?: string
  labels: string[]
  papers: string[]
  updatedAt?: string
  claim?: TaskClaim
  criteria: TaskCriterion[]
  /** Server-computed; omitted entirely when the task has no criteria. */
  criteriaProgress?: { met: number; total: number }
}

export interface TaskDetail {
  doc: TaskDoc
  children: TaskChild[]
  childCount: number
}

// ── errors ───────────────────────────────────────────────────────────────────

/** A task write refused by the server. `reason` is the machine token
 * (`not_holder`, `fenced_off`, `criterion_text_required`, `not_found`, …) and
 * `serverMessage` is the server's own prose, kept VERBATIM — the UI shows the
 * server's honest reason, never a guess of ours. */
export class TaskApiError extends Error {
  readonly status: number
  readonly reason: string
  readonly serverMessage?: string

  constructor(status: number, reason: string, serverMessage?: string) {
    super(serverMessage !== undefined && serverMessage !== '' ? serverMessage : reason)
    this.name = 'TaskApiError'
    this.status = status
    this.reason = reason
    this.serverMessage = serverMessage
  }
}

/** Builds the error from a non-2xx response. The task controller answers every
 * refusal as `{"ok":false,"reason":"<token>"}` with an optional `"message"`;
 * a body we cannot parse degrades to the status code rather than inventing a
 * reason. */
export function taskErrorFrom(status: number, body: string): TaskApiError {
  let reason = `http_${status}`
  let message: string | undefined
  try {
    const parsed = JSON.parse(body) as { reason?: unknown; message?: unknown; error?: unknown }
    if (typeof parsed.reason === 'string' && parsed.reason !== '') reason = parsed.reason
    else if (typeof parsed.error === 'string' && parsed.error !== '') reason = parsed.error
    if (typeof parsed.message === 'string' && parsed.message !== '') message = parsed.message
  } catch {
    // Non-JSON body (a proxy page, an empty 502): keep the status-derived
    // reason and surface the raw text if it is short enough to be useful.
    const trimmed = body.trim()
    if (trimmed !== '' && trimmed.length <= 200) message = trimmed
  }
  return new TaskApiError(status, reason, message)
}

/** The one-line the UI shows for a refusal: the server's own message when it
 * gave one, else the bare reason token. Never paraphrased. */
export function describeTaskError(err: unknown): string {
  if (err instanceof TaskApiError) {
    return err.serverMessage !== undefined && err.serverMessage !== ''
      ? `${err.reason}: ${err.serverMessage}`
      : err.reason
  }
  return err instanceof Error ? err.message : String(err)
}

// ── parsing ──────────────────────────────────────────────────────────────────

function str(v: unknown): string | undefined {
  return typeof v === 'string' && v !== '' ? v : undefined
}

function num(v: unknown): number | undefined {
  return typeof v === 'number' && Number.isFinite(v) ? v : undefined
}

function strList(v: unknown): string[] {
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : []
}

export function parseCriteria(raw: unknown): TaskCriterion[] {
  if (!Array.isArray(raw)) return []
  const out: TaskCriterion[] = []
  for (const entry of raw) {
    if (entry === null || typeof entry !== 'object') continue
    const row = entry as Record<string, unknown>
    const wording = str(row.criterion)
    if (wording === undefined) continue
    const attempts: TaskAttempt[] = Array.isArray(row.attempts)
      ? row.attempts.flatMap((a) => {
          if (a === null || typeof a !== 'object') return []
          const at = a as Record<string, unknown>
          const note = str(at.note)
          if (note === undefined) return []
          const attempt: TaskAttempt = { note }
          const ts = str(at.ts)
          const worker = str(at.worker)
          if (ts !== undefined) attempt.ts = ts
          if (worker !== undefined) attempt.worker = worker
          return [attempt]
        })
      : []
    // `met` counts ONLY when it is exactly boolean true (the server's own rule
    // for criteria_progress) — a truthy string must not read as met.
    const criterion: TaskCriterion = { criterion: wording, met: row.met === true, attempts }
    const evidence = str(row.evidence)
    if (evidence !== undefined) criterion.evidence = evidence
    out.push(criterion)
  }
  return out
}

export function parseClaim(raw: unknown): TaskClaim | undefined {
  if (raw === null || typeof raw !== 'object') return undefined
  const row = raw as Record<string, unknown>
  const claim: TaskClaim = {}
  const worker = str(row.worker)
  const tsIso = str(row.ts_iso)
  const epoch = num(row.epoch)
  if (worker !== undefined) claim.worker = worker
  if (tsIso !== undefined) claim.tsIso = tsIso
  if (epoch !== undefined) claim.epoch = epoch
  if (row.now !== null && typeof row.now === 'object') {
    const nowRow = row.now as Record<string, unknown>
    const now: NonNullable<TaskClaim['now']> = {}
    const text = str(nowRow.text)
    const ts = str(nowRow.ts)
    const criterion = num(nowRow.criterion)
    if (text !== undefined) now.text = text
    if (ts !== undefined) now.ts = ts
    if (criterion !== undefined) now.criterion = criterion
    if (Object.keys(now).length > 0) claim.now = now
  }
  return Object.keys(claim).length > 0 ? claim : undefined
}

/** Flattens the `doc` envelope. The controller renders claim + criteria at two
 * addresses (`doc.claim` top level, criteria under `doc.content
 * .acceptance_criteria`) — this is the single place that knows that. */
export function parseTaskDoc(raw: unknown): TaskDoc {
  const row = (raw ?? {}) as Record<string, unknown>
  const content = (row.content ?? {}) as Record<string, unknown>
  const doc: TaskDoc = {
    docId: str(row.doc_id) ?? str(row.id) ?? '',
    title: str(row.title) ?? '(untitled task)',
    labels: strList(row.labels),
    papers: strList(row.papers),
    criteria: parseCriteria(content.acceptance_criteria),
  }
  const rev = str(row.rev)
  const lifecycleStatus = str(row.lifecycle_status)
  const assignee = str(row.assignee)
  const parentId = str(row.parent_id)
  const updatedAt = str(row.updated_at)
  const priority = num(row.priority)
  if (rev !== undefined) doc.rev = rev
  if (lifecycleStatus !== undefined) doc.lifecycleStatus = lifecycleStatus
  if (assignee !== undefined) doc.assignee = assignee
  if (parentId !== undefined) doc.parentId = parentId
  if (updatedAt !== undefined) doc.updatedAt = updatedAt
  if (priority !== undefined) doc.priority = priority
  // `doc.claim` is authoritative; the controller deletes content.claim, but an
  // older/diet render may only carry the nested one.
  const claim = parseClaim(row.claim) ?? parseClaim(content.claim)
  if (claim !== undefined) doc.claim = claim
  const progress = row.criteria_progress
  if (progress !== null && typeof progress === 'object') {
    const met = num((progress as Record<string, unknown>).met)
    const total = num((progress as Record<string, unknown>).total)
    if (met !== undefined && total !== undefined) doc.criteriaProgress = { met, total }
  }
  return doc
}

export function parseTaskDetail(raw: unknown): TaskDetail {
  const row = (raw ?? {}) as Record<string, unknown>
  const children: TaskChild[] = Array.isArray(row.children)
    ? row.children.flatMap((c) => {
        if (c === null || typeof c !== 'object') return []
        const child = c as Record<string, unknown>
        const docId = str(child.doc_id)
        if (docId === undefined) return []
        const out: TaskChild = { doc_id: docId }
        const title = str(child.title)
        const lifecycle = str(child.lifecycle_status)
        if (title !== undefined) out.title = title
        if (lifecycle !== undefined) out.lifecycle_status = lifecycle
        const progress = child.criteria_progress
        if (progress !== null && typeof progress === 'object') {
          const met = num((progress as Record<string, unknown>).met)
          const total = num((progress as Record<string, unknown>).total)
          if (met !== undefined && total !== undefined) out.criteria_progress = { met, total }
        }
        return [out]
      })
    : []
  return {
    doc: parseTaskDoc(row.doc),
    children,
    childCount: num(row.child_count) ?? children.length,
  }
}

// ── IO ───────────────────────────────────────────────────────────────────────

function tasksUrl(connection: InstanceConnection, suffix: string): string {
  return connection.projectUrl.replace(/\/+$/, '') + '/v1/tasks' + suffix
}

async function taskSend(
  connection: InstanceConnection,
  method: string,
  suffix: string,
  payload: unknown,
): Promise<unknown> {
  const headers: Record<string, string> = {
    Accept: 'application/json',
    Authorization: `Bearer ${connection.token}`,
  }
  const init: Parameters<typeof expoFetch>[1] = { method, headers }
  if (payload !== undefined) {
    headers['Content-Type'] = 'application/json'
    init.body = JSON.stringify(payload)
  }
  const response = await expoFetch(tasksUrl(connection, suffix), init)
  const body = await response.text()
  if (!response.ok) throw taskErrorFrom(response.status, body)
  try {
    return JSON.parse(body) as unknown
  } catch {
    throw new TaskApiError(response.status, 'unparseable_response')
  }
}

/** GET /v1/tasks/:doc_id — the detail read: the full doc plus ONE level of
 * child summaries and the true child_count. */
export async function fetchTaskDetail(
  connection: InstanceConnection,
  docId: string,
): Promise<TaskDetail> {
  return parseTaskDetail(await taskSend(connection, 'GET', `/${encodeURIComponent(docId)}`, undefined))
}

function docOf(envelope: unknown): TaskDoc {
  return parseTaskDoc((envelope as Record<string, unknown> | undefined)?.doc)
}

export interface StampRequest {
  docId: string
  worker: string
  observedEpoch: number
  criterion: number
  /** REQUIRED for a met-flip: the row's stored wording, verbatim. An index
   * alone is unverifiable, so the server answers `criterion_text_required`. */
  criterionText?: string
  met: boolean
  evidence?: string
  note?: string
}

/** POST /v1/tasks/:doc_id/stamp — holder-only AND epoch-fenced. Stamp does not
 * bump the epoch (unlike pulse). */
export async function stampCriterion(
  connection: InstanceConnection,
  req: StampRequest,
): Promise<TaskDoc> {
  const body: Record<string, unknown> = {
    worker_id: req.worker,
    observed_epoch: req.observedEpoch,
    criterion: req.criterion,
  }
  if (req.met) {
    body.met = true
    body.evidence = req.evidence ?? ''
    body.criterion_text = req.criterionText ?? ''
  } else {
    body.miss = true
    body.note = req.note ?? ''
  }
  return docOf(await taskSend(connection, 'POST', `/${encodeURIComponent(req.docId)}/stamp`, body))
}

/** POST /v1/tasks/:doc_id/pulse — the holder's heartbeat. Takes NO
 * observed_epoch (it survives fence bumps) and BUMPS the claim epoch itself:
 * the returned doc carries the fresh epoch, which is why every caller must
 * absorb the response instead of reusing the epoch it had. */
export async function pulseTask(
  connection: InstanceConnection,
  req: { docId: string; worker: string; now: string; criterion?: number },
): Promise<TaskDoc> {
  const body: Record<string, unknown> = { worker_id: req.worker, now: req.now }
  if (req.criterion !== undefined) body.criterion = req.criterion
  return docOf(await taskSend(connection, 'POST', `/${encodeURIComponent(req.docId)}/pulse`, body))
}

/** POST /v1/tasks/:doc_id/claim — targeted claim. Mints the epoch, so it takes
 * none. The server refuses `not_ready` when another worker holds it; a
 * same-worker re-claim is a RENEWAL, not an error. */
export async function claimTask(
  connection: InstanceConnection,
  req: { docId: string; worker: string },
): Promise<TaskDoc> {
  return docOf(
    await taskSend(connection, 'POST', `/${encodeURIComponent(req.docId)}/claim`, {
      worker_id: req.worker,
    }),
  )
}

/** POST /v1/tasks/:doc_id/release — the voluntary walk-away. Holder + epoch
 * both fenced; flips in_progress→open and bumps the epoch. */
export async function releaseTask(
  connection: InstanceConnection,
  req: { docId: string; worker: string; observedEpoch: number },
): Promise<TaskDoc> {
  return docOf(
    await taskSend(connection, 'POST', `/${encodeURIComponent(req.docId)}/release`, {
      worker_id: req.worker,
      observed_epoch: req.observedEpoch,
    }),
  )
}
