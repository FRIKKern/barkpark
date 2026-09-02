// Chat wire types — the mobile projection of the /v1/chat contract, the same
// server JSON the Go TUI consumes through internal/apiclient/chat.go
// (chat_controller.ex full_session_json / sidebar_json / message_json). The
// mobile floor keeps the render-bearing subset: rail_snapshot / workflow /
// epic mission-control richness stays a TUI+Studio surface this wave, so those
// keys are deliberately not projected here (unknown JSON keys are simply
// ignored — same forward-compat tolerance as the Go decoder).
import type { Block } from '../papers/portabledoc/model'

/** One persisted transcript row (message_json). Rich rows carry `blocks` —
 * the server's PortableDoc conversion (chat_controller.ex message_json →
 * FromMarkdown.blocks), the SAME block trees the Studio and the Go TUI
 * render — alongside the `source_markdown` they were built from. */
export interface ChatMessage {
  seq: number
  role: string
  source_markdown?: string
  blocks?: Block[]
  metadata?: Record<string, unknown>
  inserted_at?: string
}

/** WHO IS RUNNING THIS SESSION, WHERE — the server-side half of the context
 * band (chat-local-cloud-context-w3, criterion 2; the CLI half is
 * internal/chat/context.go, the Studio half is
 * Barkpark.StudioChat.ContextIdentity). Projected by chat_controller.ex
 * `session_context_json/1` onto the full-session read.
 *
 * FACTS, not renderings: every key here is something the phone CANNOT measure
 * for itself — the execution host is a lease row, the workspace is a slug
 * behind a UUID, and the cwd is a path on a machine this device has never
 * seen. `src/chat/context.ts` applies the typed-absence vocabulary to them.
 *
 * EVERY FIELD IS OPTIONAL AND SO IS THE WHOLE OBJECT, deliberately: an older
 * server does not send `context` at all, and the band must then say `(unknown)`
 * for the facts only a server can supply rather than invent them or vanish. */
export interface ChatSessionContext {
  /** The host holding the session's LIVE execution lease, by name. `null` is a
   * MEASUREMENT — no enrolled host holds one, so the server itself runs the
   * session — which the band paints `(server-local)`, never blank. */
  host?: string | null
  /** "managed" | "registered_host" — WHOSE filesystem `cwd` names. It is what
   * makes an absent repo root honest rather than lazy: a registered host's cwd
   * is on another machine, so nobody can answer. */
  execution_target?: string | null
  /** The session's working directory, on whichever machine runs it. */
  cwd?: string | null
  /** The slug of the session's OWN `owner_workspace_id` — the workspace every
   * store gate compares against, which is why it beats the workspace the app
   * happens to be scoped to when the two disagree. */
  workspace?: string | null
  /** The work-tree root `cwd` sits in, when the server could measure one. */
  repo_root?: string | null
  /** WHICH KIND of absence `repo_root: null` is: "set" | "not_a_repo" (measured
   * — outside a work tree) | "unknown" (nobody can answer). Collapsing the last
   * two would let "I could not look" reach the eye as "you are not in a repo". */
  repo_status?: string | null
}

/** The FULL GET /v1/chat/sessions/:id struct (subset) — continuity set +
 * message tail. `?since=<seq>` returns only newer rows. */
export interface ChatSession {
  id: string
  title?: string
  status?: string
  /** Which engine answers ("claude" | "codex" | …) — the key the picker
   * vocabulary is looked up under (charter D27). */
  provider?: string
  mode?: string
  /** The OBSERVED model the server last recorded answering. Distinct from
   * model_choice below, and the distinction is load-bearing (ratified call
   * #5): this is FACT, that is a REQUEST. */
  model?: string
  /** The user's persisted model REQUEST. May legitimately differ from
   * `model` — an alias resolving to a concrete id, or a choice that has not
   * taken effect yet. */
  model_choice?: string
  /** The user's persisted effort REQUEST. There is no observed counterpart:
   * no wire frame reports effort back, and there is no set_effort control
   * verb — so it is persist-only and applies from the next resume. */
  effort_choice?: string
  summary?: string
  message_count?: number
  pending_approvals?: number
  agent_state?: string
  agent_state_at?: string
  last_active_at?: string
  inserted_at?: string
  updated_at?: string
  /** The connection identity of the session (see ChatSessionContext). Absent
   * from an older server — read it through `sessionContext` below, never
   * directly, so the absence has exactly one handler. */
  context?: ChatSessionContext
  messages?: ChatMessage[]
}

/** The session's context facts, or undefined.
 *
 * The wire JSON is a plain cast (api/chat.ts getChatSession), so `context` can
 * arrive as `null`, as a non-object, or not at all — an older server sends no
 * such key. All three mean the SAME thing to the band ("the server told us
 * nothing"), and this is the one place that decides it. */
export function sessionContext(s: ChatSession): ChatSessionContext | undefined {
  const raw: unknown = s.context
  return typeof raw === 'object' && raw !== null ? (raw as ChatSessionContext) : undefined
}

/** The sidebar row (GET /v1/chat/sessions) — NO draft/rail/choices (the D14
 * vacuous-green trap), so opening a session must re-GET. */
export interface ChatSessionSummary {
  id: string
  title?: string
  status?: string
  summary?: string
  message_count?: number
  pending_approvals?: number
  agent_state?: string
  agent_state_at?: string
  last_active_at?: string
  /** The DISMISSAL stamp the wire really carries (chat_controller.ex
   * sidebar_json → `archived_at`), projected here because discarding a key the
   * server sends is how a client ends up guessing at it. `null` on the active
   * shelf, an ISO8601 timestamp on the archived one.
   *
   * It is a FACT about the row, NOT the screen's archived truth: which shelf you
   * asked for still decides what is archived (charter D28), because a row that
   * went stale in either direction would otherwise claim the wrong shelf. */
  archived_at?: string | null
  inserted_at?: string
  updated_at?: string
}

// ---------------------------------------------------------------------------
// The LIVE-DOCUMENT stream (charter D59)
//
// While a turn is answering, the server emits SETTLED SEGMENTS of the reply as
// PortableDoc blocks instead of raw markdown deltas, so the phone renders the
// same block trees Studio and the TUI do while the answer is still being
// written. Both frames are id-LESS — a frame's identity is its (turn, from)
// pair — and both ALWAYS carry a data: line whose payload is JSON, never raw
// markdown (the Go SSE reader trims every data line while this client strips
// only one leading space, so raw text would differ per surface).
//
// The frozen wire, its offset arithmetic, and the exact per-sequence client
// outcomes are recorded ONCE at internal/pdrender/testdata/chat_stable_frames.json
// and consumed by both this app (__tests__/stableFrameContract.test.ts) and the
// Go TUI (internal/pdrender/chat_stable_frames_test.go). Change the contract
// there first.
// ---------------------------------------------------------------------------

/** What the still-unsettled tail after `to` is SHAPED like, so the client can
 * draw a shape-appropriate placeholder rather than a half-open ``` fence. The
 * classifier is server-side on purpose: it belongs to the one converter, so
 * every surface skeletons the same tail the same way. */
export type StableSkeletonKind =
  | 'code'
  | 'diagram'
  | 'chart'
  | 'stats'
  | 'table'
  | 'callout'
  | 'block'

export interface StableSkeleton {
  /** WIDER than StableSkeletonKind on purpose, and it is the same distinction
   * messageBlocks draws below: that type is what the server sends TODAY, this is
   * what a client must be able to hold. A newer server's eighth label has to
   * render honestly — StreamSkeleton's `skeletonLabel` degrades any unknown kind
   * to the generic "block" shape, exactly as the server's own `skeleton_label/1`
   * fallback arm does — and a consumer that narrowed here would instead have to
   * reject the frame and lose a whole turn's worth of settled document over a
   * word it did not recognise. */
  kind: string
  /** The PROSE ABOVE the forming component — the source bytes between `to` and
   * the component's first triggering line, verbatim. It is `StreamTail`'s
   * `classify/1` third element (charter D62/D67), and the client renders it as
   * live text ABOVE the placeholder box so a paragraph that happens to sit
   * under a forming table keeps streaming instead of vanishing behind it.
   *
   * NOT a caption, NOT the component's own body, and legitimately the EMPTY
   * STRING whenever the component starts exactly at `to` — a consumer must
   * handle '' and must never require it non-empty. */
  prose: string
}

/** `event: stable` — one settled segment of the answering turn.
 *
 * `to` is not redundant with `blocks`: block text is NOT source bytes (a
 * four-segment run proof measured 53 source vs 42 derived), so a client that
 * tried to advance its cursor by the rendered length would reject a PERFECT
 * stream at frame 2. `turn` is not redundant with `from` either: `from` alone
 * false-accepts across a turn boundary, splicing the next turn's tail onto the
 * previous message. */
export interface StableFrame {
  turn: number
  /** Inclusive UTF-8 byte offset into the turn's source markdown. */
  from: number
  /** Exclusive end offset — the client's next expected `from`. */
  to: number
  blocks: Block[]
  skeleton: StableSkeleton | null
}

/** Why the turn stopped producing settled segments. `settled` is the clean
 * end; `capped` means the segmenter hit its size cap (reachable with ZERO
 * stable frames ever emitted, which is why this is its own event and not a
 * field); `degraded` means the SERVER distrusts its own segmentation, so the
 * client drops the segments it holds and renders the persisted row. */
export type StableEndReason = 'settled' | 'capped' | 'degraded'

/** `event: stable_end` — the turn's terminal frame. */
export interface StableEndFrame {
  turn: number
  from: number
  reason: StableEndReason
}

export interface StableEvent {
  event: 'stable'
  data: StableFrame
}

export interface StableEndEvent {
  event: 'stable_end'
  data: StableEndFrame
}

/** The tagged envelope a consumer switches on after reading the event name. */
export type StableWireEvent = StableEvent | StableEndEvent

/** Narrows the envelope to a settled segment. */
export function isStableEvent(e: StableWireEvent): e is StableEvent {
  return e.event === 'stable'
}

/** GET /v1/chat/rollup (herd charter D64h): agent_state counts + the one
 * precedence state, DB-scoped by the token's chat_scope. */
export interface ChatRollup {
  counts: { working: number; blocked: number; idle: number; unknown: number }
  precedence: 'blocked' | 'working' | 'idle' | 'unknown'
}

/** The row's renderable block tree, or undefined. The declared type says what
 * the server sends; THIS says what actually arrived — the JSON is a plain
 * cast (api/chat.ts getChatSession), so a row with `blocks: null`, `blocks:
 * {}` or an empty array must fall back to the markdown source rather than
 * render an empty document. */
export function messageBlocks(m: ChatMessage): Block[] | undefined {
  const raw: unknown = m.blocks
  return Array.isArray(raw) && raw.length > 0 ? (raw as Block[]) : undefined
}

function metaString(m: ChatMessage, key: string): string {
  const v = m.metadata?.[key]
  return typeof v === 'string' ? v : ''
}

/** The card's answer handle (metadata.request_id) — '' when absent. */
export function requestId(m: ChatMessage): string {
  return metaString(m, 'request_id')
}

/** 'pending' | 'allowed' | 'denied' | '' — the card's server-held status. */
export function approvalStatus(m: ChatMessage): string {
  return metaString(m, 'approval_status')
}

/** A card row that reached a terminal decision. */
export function resolved(m: ChatMessage): boolean {
  const s = approvalStatus(m)
  return s !== '' && s !== 'pending'
}

// The three interactive card roles (render.go cardRoles). A card row still
// pending with a request_id is answerable; anything else is display-only.
const CARD_ROLES = new Set(['approval', 'plan', 'question'])

/** The role-level predicate — the role taxonomy reads THIS so the card set is
 * declared once (render.go's cardRoles map is the twin). */
export function isCardRole(role: string): boolean {
  return CARD_ROLES.has(role)
}

export function isCard(m: ChatMessage): boolean {
  return isCardRole(m.role)
}

/** True for a card row still awaiting a decision (pending + a request_id). */
export function answerable(m: ChatMessage): boolean {
  return isCard(m) && approvalStatus(m) === 'pending' && requestId(m) !== ''
}
