// Chat wire types — the mobile projection of the /v1/chat contract, the same
// server JSON the Go TUI consumes through internal/apiclient/chat.go
// (chat_controller.ex full_session_json / sidebar_json / message_json). The
// mobile floor keeps the render-bearing subset: rail_snapshot / workflow /
// epic mission-control richness stays a TUI+Studio surface this wave, so those
// keys are deliberately not projected here (unknown JSON keys are simply
// ignored — same forward-compat tolerance as the Go decoder).

/** One persisted transcript row (message_json). Assistant rows carry `blocks`
 * alongside `source_markdown`; the mobile MVP renders the markdown source. */
export interface ChatMessage {
  seq: number
  role: string
  source_markdown?: string
  blocks?: unknown
  metadata?: Record<string, unknown>
  inserted_at?: string
}

/** The FULL GET /v1/chat/sessions/:id struct (subset) — continuity set +
 * message tail. `?since=<seq>` returns only newer rows. */
export interface ChatSession {
  id: string
  title?: string
  status?: string
  mode?: string
  model?: string
  summary?: string
  message_count?: number
  pending_approvals?: number
  agent_state?: string
  agent_state_at?: string
  last_active_at?: string
  inserted_at?: string
  updated_at?: string
  messages?: ChatMessage[]
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
  inserted_at?: string
  updated_at?: string
}

/** GET /v1/chat/rollup (herd charter D64h): agent_state counts + the one
 * precedence state, DB-scoped by the token's chat_scope. */
export interface ChatRollup {
  counts: { working: number; blocked: number; idle: number; unknown: number }
  precedence: 'blocked' | 'working' | 'idle' | 'unknown'
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

export function isCard(m: ChatMessage): boolean {
  return CARD_ROLES.has(m.role)
}

/** True for a card row still awaiting a decision (pending + a request_id). */
export function answerable(m: ChatMessage): boolean {
  return isCard(m) && approvalStatus(m) === 'pending' && requestId(m) !== ''
}
