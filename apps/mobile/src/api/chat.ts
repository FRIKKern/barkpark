// The /v1/chat HTTP + SSE surface — the mobile app as the third sibling
// client of the chat transport (after the Go TUI's internal/apiclient/chat.go
// and Studio). The chat routes are NOT workspace/project-scoped (the wire
// contract fixes them at bare /v1/chat/…, same as the Go client's chatURL —
// which is why this module does NOT ride client.fetchRaw: the SDK's scoped
// escape hatch would prefix /w/<ws>/p/<project> and 404). Auth is the minted
// [read,write,chat] bearer; the workspace floor is resolved server-side from
// the token's binding (charter D6/D10).
//
// expoFetch (the D14 streaming seam) is used for EVERYTHING here so the SSE
// reader gets a streaming response.body — React Native's built-in fetch
// cannot stream.
import { fetch as expoFetch } from 'expo/fetch'

import type { InstanceConnection } from './instance'
import type { ChatRollup, ChatSession, ChatSessionSummary } from '../chat/wire'

function chatUrl(connection: InstanceConnection, suffix: string): string {
  return connection.projectUrl.replace(/\/+$/, '') + '/v1/chat' + suffix
}

async function chatSend(
  connection: InstanceConnection,
  method: string,
  suffix: string,
  payload: unknown,
  okStatuses: number[],
): Promise<{ status: number; body: string }> {
  const headers: Record<string, string> = {
    Accept: 'application/json',
    Authorization: `Bearer ${connection.token}`,
  }
  const init: Parameters<typeof expoFetch>[1] = { method, headers }
  if (payload !== undefined) {
    headers['Content-Type'] = 'application/json'
    init.body = JSON.stringify(payload)
  }
  const response = await expoFetch(chatUrl(connection, suffix), init)
  const body = await response.text()
  if (!okStatuses.includes(response.status)) {
    throw new Error(`chat ${method} ${suffix} failed: HTTP ${response.status}`)
  }
  return { status: response.status, body }
}

/** GET /v1/chat/sessions — the sidebar list, workspace-scoped at the DB by
 * the token (D10: the workspace's sessions ARE the floor, by design). */
export async function listChatSessions(
  connection: InstanceConnection,
): Promise<ChatSessionSummary[]> {
  const { body } = await chatSend(connection, 'GET', '/sessions', undefined, [200])
  const parsed = JSON.parse(body) as { sessions?: ChatSessionSummary[] }
  return parsed.sessions ?? []
}

/** GET /v1/chat/sessions/:id?since=<seq> — the full session + message tail.
 * sinceSeq 0 fetches every row (the full refetch). */
export async function getChatSession(
  connection: InstanceConnection,
  id: string,
  sinceSeq: number,
): Promise<ChatSession> {
  const suffix =
    sinceSeq > 0
      ? `/sessions/${encodeURIComponent(id)}?since=${sinceSeq}`
      : `/sessions/${encodeURIComponent(id)}`
  const { body } = await chatSend(connection, 'GET', suffix, undefined, [200])
  return JSON.parse(body) as ChatSession
}

/** POST /v1/chat/sessions/:id/messages — send a user turn (202). */
export async function sendChatMessage(
  connection: InstanceConnection,
  id: string,
  content: string,
): Promise<void> {
  await chatSend(connection, 'POST', `/sessions/${encodeURIComponent(id)}/messages`, { content }, [202])
}

/** POST /v1/chat/sessions/:id/interrupt — 202 {request_id}; request_id is
 * null when no runtime holds a turn (the D11 silent no-op). */
export async function interruptChat(connection: InstanceConnection, id: string): Promise<void> {
  await chatSend(connection, 'POST', `/sessions/${encodeURIComponent(id)}/interrupt`, undefined, [202])
}

/** POST /v1/chat/sessions/:id/approval — answer a pending card (204).
 * decision is "allow" | "deny" ONLY (charter D28 — no updatedInput). */
export async function respondChatApproval(
  connection: InstanceConnection,
  id: string,
  requestId: string,
  decision: 'allow' | 'deny',
): Promise<void> {
  await chatSend(
    connection,
    'POST',
    `/sessions/${encodeURIComponent(id)}/approval`,
    { request_id: requestId, decision },
    [204],
  )
}

/** GET /v1/chat/rollup — agent_state counts + one precedence state for the
 * token's floor. Feeds the tab-bar needs-you badge. */
export async function fetchChatRollup(connection: InstanceConnection): Promise<ChatRollup> {
  const { body } = await chatSend(connection, 'GET', '/rollup', undefined, [200])
  return JSON.parse(body) as ChatRollup
}

// ── SSE ──────────────────────────────────────────────────────────────────────

export interface SseFrame {
  event: string
  data: string
  id?: string
}

/** Incremental SSE frame splitter — feed it decoded text chunks in any
 * partitioning; it yields complete frames (blank-line separated, \n and \r\n
 * tolerated). Pure and buffer-bounded so the parsing seam is unit-testable
 * without a socket (the same split the SDK's listen.ts and the Go apiclient
 * decoder implement). */
export class SseSplitter {
  private buffer = ''

  push(chunk: string): SseFrame[] {
    this.buffer += chunk
    const frames: SseFrame[] = []
    for (;;) {
      const lf = this.buffer.indexOf('\n\n')
      const crlf = this.buffer.indexOf('\r\n\r\n')
      let start: number
      let end: number
      if (lf === -1 && crlf === -1) break
      if (lf !== -1 && (crlf === -1 || lf < crlf)) {
        start = lf
        end = lf + 2
      } else {
        start = crlf
        end = crlf + 4
      }
      const raw = this.buffer.slice(0, start)
      this.buffer = this.buffer.slice(end)
      const frame = parseSseFrame(raw)
      if (frame !== undefined) frames.push(frame)
    }
    return frames
  }
}

/** Parses one raw SSE frame. Comment-only frames (keepalives) return
 * undefined. Default event name is "message" per the SSE spec — which is also
 * the chat replay frame's name. */
export function parseSseFrame(raw: string): SseFrame | undefined {
  if (raw.length === 0) return undefined
  let event = 'message'
  let id: string | undefined
  const dataLines: string[] = []
  for (const rawLine of raw.split('\n')) {
    const line = rawLine.replace(/\r$/, '')
    if (line.length === 0 || line.startsWith(':')) continue
    const colon = line.indexOf(':')
    if (colon === -1) continue
    const field = line.slice(0, colon)
    let value = line.slice(colon + 1)
    if (value.startsWith(' ')) value = value.slice(1)
    if (field === 'event') event = value
    else if (field === 'id') id = value
    else if (field === 'data') dataLines.push(value)
  }
  if (dataLines.length === 0) return undefined
  const frame: SseFrame = { event, data: dataLines.join('\n') }
  if (id !== undefined) frame.id = id
  return frame
}

// ── connection truth ─────────────────────────────────────────────────────────

/** The five-state stream vocabulary (charter D24), OWNED here — the transport
 * produces it, sessionStore and the screens import it. 'degraded' replaced
 * 'reconnecting' (the stream is retrying forever, honestly labeled); 'blocked'
 * is forbidden (agent_state owns it) and 'settle' is reserved for D77. */
export type StreamStatus = 'connecting' | 'open' | 'degraded' | 'refused' | 'closed'

/** The transport's failure vocabulary: `transient` keeps retrying forever on
 * the jittered 1s→16s ladder; `refused` terminates into the refused state. */
export type StreamFailureClass = 'transient' | 'refused'

export interface StreamFailure {
  class: StreamFailureClass
  /** Set when the failure was an HTTP response (4xx/5xx); absent on
   * network-level failures (DNS, socket, timeout). */
  httpStatus?: number
  message: string
}

/** A non-2xx answer from the events route — carries the status so the
 * classifier can split transient (5xx) from refused (4xx). */
export class ChatHttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message)
    this.name = 'ChatHttpError'
  }
}

/** Charter D26 client contract: 5xx (incl runtime_capacity/runtime_unavailable
 * and overloaded) and network-level errors are `transient` — the server may
 * come back, so the stream degrades and retries. Every 4xx (401/403/404/422
 * chat_unsupported…) is `refused` — permanent for this session/token; retrying
 * would loop forever against a wall. */
export function classifyStreamFailure(err: unknown): StreamFailure {
  if (err instanceof ChatHttpError) {
    return {
      class: err.status >= 400 && err.status < 500 ? 'refused' : 'transient',
      httpStatus: err.status,
      message: err.message,
    }
  }
  return { class: 'transient', message: err instanceof Error ? err.message : String(err) }
}

// The reconnect discipline ported from @barkpark/core listen.ts (withJitter +
// counted clean closes) — a port, not a fork: terminal behavior here is
// degraded-retry-forever, never a throw. Jitter (0.5–1.0×) keeps a fleet of
// phones from reconnecting in lockstep; the exponential ladder means a dead
// endpoint costs ~4 requests/min at the cap, not 60.
const BACKOFF_BASE_MS = 1_000
const BACKOFF_CAP_MS = 16_000

function withJitter(ms: number): number {
  return (ms * (1 + Math.random())) / 2
}

/** Jittered exponential backoff: attempt 0 → ~1s … attempt ≥4 → ~16s cap.
 * Exported for the bounded-window proof (a simulated window must show
 * exponentially few connects, not one per second). */
export function backoffDelayMs(attempt: number): number {
  return withJitter(Math.min(BACKOFF_BASE_MS * 2 ** attempt, BACKOFF_CAP_MS))
}

export interface ChatStreamOptions {
  signal: AbortSignal
  /** Replay cursor: the server replays rows with seq > lastEventId as
   * `event: message` frames before going live. */
  lastEventId?: string
  onFrame: (frame: SseFrame) => void
  /** Honest connection-state surface for the UI (the D24 five-state
   * vocabulary). `failure` rides along on 'degraded' and 'refused'. */
  onStatus?: (status: StreamStatus, failure?: StreamFailure) => void
}

/** Opens GET /v1/chat/sessions/:id/events and pumps frames until aborted.
 * Transient failures (5xx/network) and clean closes retry FOREVER on the
 * jittered 1s→16s ladder with Last-Event-ID resume (the server replays the
 * missed seq range); a refused-class failure (any 4xx) terminates into the
 * 'refused' state — the screen renders the actionable wall, not a spinner. */
export async function streamChatEvents(
  connection: InstanceConnection,
  sessionId: string,
  opts: ChatStreamOptions,
): Promise<void> {
  let lastEventId = opts.lastEventId
  // ONE counter feeds the backoff ladder: transient failures AND clean closes
  // both count (the old flat uncounted 1s clean-close loop hammered a dead
  // endpoint 60×/min); any bytes from the server reset it.
  let attempt = 0

  opts.onStatus?.('connecting')
  while (!opts.signal.aborted) {
    try {
      const headers: Record<string, string> = {
        Accept: 'text/event-stream',
        Authorization: `Bearer ${connection.token}`,
      }
      if (lastEventId !== undefined) headers['Last-Event-ID'] = lastEventId
      const response = await expoFetch(
        chatUrl(connection, `/sessions/${encodeURIComponent(sessionId)}/events`),
        { method: 'GET', headers, signal: opts.signal },
      )
      if (!response.ok || response.body === null) {
        throw new ChatHttpError(response.status, `chat events: HTTP ${response.status}`)
      }
      opts.onStatus?.('open')

      const reader = response.body.getReader()
      const decoder = new TextDecoder('utf-8')
      const splitter = new SseSplitter()
      try {
        for (;;) {
          const { done, value } = await reader.read()
          if (done) break
          attempt = 0 // bytes prove a live stream — reset the ladder
          for (const frame of splitter.push(decoder.decode(value, { stream: true }))) {
            if (frame.id !== undefined) lastEventId = frame.id
            opts.onFrame(frame)
          }
        }
      } finally {
        try {
          reader.releaseLock()
        } catch {
          // ignore
        }
      }
      // Clean close: reconnect with the cursor (EventSource semantics), COUNTED
      // against the same jittered ladder as failures — an instantly-closing
      // endpoint backs off to the 16s cap instead of busy-looping at 1 Hz.
      if (opts.signal.aborted) break
      opts.onStatus?.('degraded')
      await sleep(backoffDelayMs(attempt), opts.signal)
      attempt += 1
    } catch (err) {
      if (opts.signal.aborted) break
      const failure = classifyStreamFailure(err)
      if (failure.class === 'refused') {
        // Terminal: a 4xx is a wall (signed out / session gone / unsupported) —
        // "reconnecting…" forever would be a lie.
        opts.onStatus?.('refused', failure)
        return
      }
      opts.onStatus?.('degraded', failure)
      await sleep(backoffDelayMs(attempt), opts.signal)
      attempt += 1
    }
  }
  opts.onStatus?.('closed')
}

function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal.aborted) {
      resolve()
      return
    }
    const timer = setTimeout(() => {
      signal.removeEventListener('abort', onAbort)
      resolve()
    }, ms)
    const onAbort = () => {
      clearTimeout(timer)
      resolve()
    }
    signal.addEventListener('abort', onAbort, { once: true })
  })
}
