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

export interface ChatStreamOptions {
  signal: AbortSignal
  /** Replay cursor: the server replays rows with seq > lastEventId as
   * `event: message` frames before going live. */
  lastEventId?: string
  onFrame: (frame: SseFrame) => void
  /** Honest connection-state surface for the UI. */
  onStatus?: (status: 'connecting' | 'open' | 'reconnecting' | 'closed') => void
}

const MAX_RECONNECTS = 5

/** Opens GET /v1/chat/sessions/:id/events and pumps frames until aborted.
 * Reconnects with backoff + Last-Event-ID on drops (the server replays the
 * missed seq range); gives up after MAX_RECONNECTS consecutive failures. */
export async function streamChatEvents(
  connection: InstanceConnection,
  sessionId: string,
  opts: ChatStreamOptions,
): Promise<void> {
  let lastEventId = opts.lastEventId
  let failures = 0

  while (!opts.signal.aborted) {
    opts.onStatus?.(failures === 0 ? 'connecting' : 'reconnecting')
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
        throw new Error(`chat events: HTTP ${response.status}`)
      }
      opts.onStatus?.('open')
      failures = 0

      const reader = response.body.getReader()
      const decoder = new TextDecoder('utf-8')
      const splitter = new SseSplitter()
      try {
        for (;;) {
          const { done, value } = await reader.read()
          if (done) break
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
      // Clean close: reconnect with the cursor (EventSource semantics) after a
      // floor delay so an instantly-closing endpoint cannot busy-spin us.
      if (opts.signal.aborted) break
      await sleep(1000, opts.signal)
    } catch {
      if (opts.signal.aborted) break
      failures += 1
      if (failures > MAX_RECONNECTS) break
      await sleep(Math.min(500 * 2 ** failures, 8000), opts.signal)
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
