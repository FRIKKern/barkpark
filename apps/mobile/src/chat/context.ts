// context.ts — WHICH DEVICE IS TALKING TO WHICH SERVER, ABOUT A SESSION
// RUNNING WHERE.
//
// The mobile half of the chat context identity (chat-local-cloud-context-w3,
// criterion 2). The CLI half is `internal/chat/context.go`; the Studio half is
// `Barkpark.StudioChat.ContextIdentity`. This file speaks the SAME vocabulary
// as both, so the three surfaces cannot answer the same question differently.
//
// A phone is one client among many servers, workspaces and sessions, and its
// chat screen said nothing about which of them it had reached. This module
// resolves the identity the band paints: the execution HOST and REPOSITORY
// ROOT (server-reported — the phone can measure neither), and the SERVER /
// WORKSPACE / PROJECT / DATASET the live API client is actually pointed at.
// `ContextBand.tsx` paints it; nothing here renders.
//
// Two laws hold the surface honest, and both are load-bearing:
//
//  1. A DISPLAYED VALUE COMES FROM THE ACTUAL BINDING wherever an actual truth
//     exists. The server/scope fields read the LIVE `InstanceConnection` the
//     store dials, never the stored config blob — where the config's claim and
//     the connection DISAGREE the field renders the CONNECTION's value and
//     reports the disagreement beside it. The workspace goes one step further:
//     the SESSION's own owner workspace beats the app's scope, because that is
//     the workspace every server-side store gate compares against. A surface
//     that prints a stored string while the wire uses something else is
//     precisely how a wrong connection reads as a right one.
//
//  2. ABSENCE IS VISIBLE AND TYPED. `(not set)` (measured — nothing is
//     configured), `(unknown)` (nobody can answer), `(not a git repo)`
//     (measured — the directory is outside a work tree) and `(server-local)`
//     (measured — no host holds the lease, the server itself runs it) are four
//     different facts. None renders as a blank and none renders as a plausible
//     default. This matters most on DATASET: `connectionFromConfig` silently
//     substitutes `'production'` for an empty dataset, so an unset dataset
//     would otherwise reach the eye as the word "production" — the single value
//     most likely to be wrong, wearing the costume of a deliberate choice. The
//     absence stays the headline and the substitution is reported next to it.
import { normalizeServerUrl } from '../cascade/knownServers'
import type { InstanceConnection } from '../api/instance'
import type { ChatSessionContext } from './wire'

/** The three-way answer to "do we have this value?". The middle arm is the
 * whole point: "measured, and there is nothing" is a different fact from
 * "could not measure", and someone staring at a wrong connection needs to know
 * which one they are looking at. */
export type FieldStatus = 'set' | 'unset' | 'unknown'

// The absence markers. Distinct strings on purpose (law 2), and every one is
// parenthesised — which no host name, slug, URL or path ever is — so none can
// be mistaken for a value.
export const ABSENT_UNSET = '(not set)'
export const ABSENT_UNKNOWN = '(unknown)'
export const ABSENT_NO_REPO = '(not a git repo)'
export const ABSENT_SERVER_LOCAL = '(server-local)'

/** One line-item of the identity: a name, a three-way status, the value when
 * there is one, the visible marker when there is not, and — when two truths
 * disagree — the disagreement, in text. */
export interface ContextField {
  /** The label the band prints and the name a guard reds by. */
  name: string
  status: FieldStatus
  /** The DISPLAYED value. Meaningful only when status is 'set'. */
  value: string
  /** The marker rendered when status is not 'set'. Never empty. */
  absent: string
  /** The disagreement (or qualification) report; '' when there is none. */
  note: string
  /** True when two truths about this field disagree — including the "nothing
   * was configured, the client substituted a default" case, which is a
   * disagreement about the most dangerous value in the set. */
  mismatch: boolean
}

/** The field's rendered text. It can NEVER return an empty string: a band that
 * renders '' where a value belongs is the exact failure mode this module exists
 * to prevent, so the fallback is the loudest honest marker rather than a
 * blank. The note rides after it. */
export function fieldDisplay(f: ContextField): string {
  let base = f.status === 'set' ? f.value : ''
  if (base === '') base = f.absent
  if (base === '') base = ABSENT_UNKNOWN
  return f.note !== '' ? `${base} ${f.note}` : base
}

/** The whole answer, in paint order. */
export interface ContextIdentity {
  fields: ContextField[]
}

/** The six field names, in paint order. The band renders exactly these. */
export const CONTEXT_FIELD_NAMES = ['host', 'server', 'workspace', 'project', 'dataset', 'repo']

/** The named field, or undefined. The lookup exists so tests and callers
 * address a field BY NAME rather than by position — a positional read is how a
 * reordered list turns into a silently wrong reading, and this list is
 * reordered by anyone who redesigns the band. */
export function contextField(ci: ContextIdentity, name: string): ContextField | undefined {
  return ci.fields.find((f) => f.name === name)
}

/** The fields whose truths disagree — what ⚠ is painted on. */
export function contextMismatches(ci: ContextIdentity): ContextField[] {
  return ci.fields.filter((f) => f.mismatch)
}

/** The STORED config's claim about the connection — the persisted literal, the
 * half that can be stale. It is never displayed on its own: it is only ever the
 * thing reported when it disagrees with what the client actually dials. */
export interface ConnectionClaim {
  server?: string
  workspace?: string
  project?: string
  dataset?: string
}

const text = (v: string | null | undefined): string => (typeof v === 'string' ? v.trim() : '')

const quoted = (v: string): string => `"${v}"`

/** Appends a note without dropping one already there: a field can carry TWO
 * disagreements at once (the stored config is stale AND the session runs in
 * another workspace), and silently keeping only the newer one would hide the
 * older — which is the same information loss a blank is. */
function withNote(f: ContextField, note: string): ContextField {
  return { ...f, note: f.note === '' ? note : `${f.note} ${note}` }
}

/** One field reconciled between what the config CLAIMS and what the client
 * ACTUALLY dials — the exact four arms of the CLI's `reconciled`, each a
 * distinct fact:
 *
 *   - neither: UNSET, plainly.
 *   - claim silent, connection carrying a value: the client substituted a
 *     default nobody chose. The ABSENCE is the headline and the substitution is
 *     reported — showing "production" alone here would be the plausible-default
 *     lie law 2 names.
 *   - connection silent: no actual truth exists for this field, so the claim
 *     stands UNRECONCILED and nothing extra is asserted.
 *   - both, disagreeing: the connection's value is the truth and the claim is
 *     reported as the thing that is wrong.
 *
 * `same` exists for the server URL, whose two spellings can differ by a
 * trailing slash or host casing without disagreeing about anything. Comparing
 * those raw would raise a ⚠ on a connection that is perfectly correct, and a
 * warning that fires on healthy state is a warning nobody reads. */
function reconciled(
  name: string,
  claim: string | null | undefined,
  actual: string | null | undefined,
  same: (a: string, b: string) => boolean = (a, b) => a === b,
): ContextField {
  const declared = text(claim)
  const live = text(actual)
  const base: ContextField = {
    name,
    status: 'unset',
    value: '',
    absent: ABSENT_UNSET,
    note: '',
    mismatch: false,
  }
  if (declared === '' && live === '') return base
  if (declared === '') {
    return { ...base, mismatch: true, note: `— the connection uses ${quoted(live)}` }
  }
  if (live === '' || same(declared, live)) {
    return { ...base, status: 'set', value: declared }
  }
  return {
    ...base,
    status: 'set',
    value: live,
    mismatch: true,
    note: `— configured ${quoted(declared)}`,
  }
}

/** Layers SERVER TRUTH over an app-side field. The session's own fact wins the
 * headline — it is the binding the server's own store gates enforce, while the
 * app's scope is merely where this device happens to be standing — and the
 * app's value is reported beside it when the two disagree.
 *
 * `appValue` is passed in rather than read off `f.value` on purpose: `f` may be
 * in the "nothing configured, the client substituted one" arm, where its value
 * is deliberately BLANK and the substitution lives in the note. Reading the
 * displayed value there would compare against the empty string and call every
 * substituted default a disagreement with the session.
 *
 * A server that said nothing changes nothing: silence is not a disagreement,
 * and overwriting a known app value with an absence would manufacture one. An
 * app that carries nothing is not a disagreement either — and a ⚠ raised there
 * would be a warning about the app being unscoped, which is not what this field
 * is for. In BOTH agreeing arms any earlier claim-vs-connection note survives:
 * a stale stored config is still stale even when the session agrees with the
 * live connection. */
function overlaidWithSessionTruth(
  f: ContextField,
  appValue: string,
  truth: string,
  label: string,
): ContextField {
  if (truth === '') return f
  if (appValue === '' || appValue === truth) {
    return { ...f, status: 'set', value: truth, absent: '' }
  }
  return withNote({ ...f, status: 'set', value: truth, absent: '', mismatch: true }, `— ${label} ${quoted(appValue)}`)
}

/** The EXECUTION HOST — server truth only. The phone cannot measure it and has
 * no claim to reconcile against, so there are exactly three answers: the host
 * holding the live lease, `(server-local)` when no host holds one (a
 * MEASUREMENT: the server itself runs the session), and `(unknown)` when the
 * server told us nothing at all — an older server that does not project
 * `context`. The last two are not the same fact and must not render the same. */
function hostField(wire: ChatSessionContext | undefined): ContextField {
  const base: ContextField = {
    name: 'host',
    status: 'unknown',
    value: '',
    absent: ABSENT_UNKNOWN,
    note: '',
    mismatch: false,
  }
  if (wire === undefined) return withNote(base, '— this server reports no session context')
  const host = text(wire.host)
  if (host !== '') return { ...base, status: 'set', value: host, absent: '' }
  return { ...base, status: 'unset', absent: ABSENT_SERVER_LOCAL }
}

/** The REPOSITORY ROOT — server truth only, for the same reason: the cwd is a
 * path on a machine this device has never seen.
 *
 * `repo_status` is what makes the absence honest. A `registered_host` session's
 * root is a HOST-side fact and the chat-host protocol carries no such report,
 * so `(unknown)` WITH THE CWD NAMED is the true answer and a confident one
 * would be a wrong one. A server-local cwd outside a work tree is measured, and
 * `(not a git repo)` says exactly that. */
function repoField(wire: ChatSessionContext | undefined): ContextField {
  const base: ContextField = {
    name: 'repo',
    status: 'unknown',
    value: '',
    absent: ABSENT_UNKNOWN,
    note: '',
    mismatch: false,
  }
  if (wire === undefined) return withNote(base, '— this server reports no session context')

  const root = text(wire.repo_root)
  const status = text(wire.repo_status)
  const cwd = text(wire.cwd)

  if (status === 'set' && root !== '') return { ...base, status: 'set', value: root, absent: '' }
  if (status === 'not_a_repo') {
    const f: ContextField = { ...base, status: 'unset', absent: ABSENT_NO_REPO }
    return cwd === '' ? f : withNote(f, `— ${quoted(cwd)}`)
  }
  // Unknown. WHOSE machine could not answer is the useful half of the message.
  if (cwd === '') return { ...base, status: 'unset', absent: ABSENT_UNSET }
  const where = text(wire.execution_target) === 'registered_host' ? 'the execution host' : 'the server'
  return withNote(base, `— ${quoted(cwd)} on ${where}, which reports no repository root`)
}

/**
 * Build the identity the band paints.
 *
 * `claim` is the STORED config blob (the half that can be stale), `connection`
 * is the LIVE `InstanceConnection` the chat store actually dials, and `wire` is
 * what the server said about this session (undefined on an older server).
 * Pure: it performs no IO and reads no module state, so every arm is drivable
 * from a fixture.
 */
export function resolveContextIdentity(
  claim: ConnectionClaim | undefined,
  connection: InstanceConnection,
  wire: ChatSessionContext | undefined,
): ContextIdentity {
  const c = claim ?? {}
  return {
    fields: [
      hostField(wire),
      reconciled(
        'server',
        c.server,
        connection.projectUrl,
        (a, b) => normalizeServerUrl(a) === normalizeServerUrl(b),
      ),
      // WORKSPACE carries all three sources, and its precedence is the whole
      // point of the field: the session's own owner workspace beats whatever
      // this device is scoped to, because that is the workspace every
      // server-side gate compares against. The app's effective value is the
      // live connection's, falling back to the stored claim when the connection
      // carries none (connectionFromConfig only sets workspace when project is
      // set too) — so an unreconciled claim is still what gets compared.
      overlaidWithSessionTruth(
        reconciled('workspace', c.workspace, connection.workspace),
        text(connection.workspace) || text(c.workspace),
        text(wire?.workspace),
        'the app is scoped to',
      ),
      reconciled('project', c.project, connection.project),
      reconciled('dataset', c.dataset, connection.dataset),
      repoField(wire),
    ],
  }
}
