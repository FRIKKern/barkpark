// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// SSE live-stream transport for GET /v1/data/listen/:dataset.
// - Returns a ListenHandle<T>: AsyncIterable + .unsubscribe().
// - Edge runtimes throw BarkparkEdgeRuntimeError SYNCHRONOUSLY (not lazily).
// - Uses fetch() + ReadableStream reader for custom headers (Bearer, Last-Event-ID);
//   EventSource is unavailable because it does not support Authorization.
// - Reconnects with exponential backoff + Last-Event-ID on network drops.
// - Yields ListenEvent<T> (the interface declared in types.ts).

import type {
  BarkparkClientConfig,
  BarkparkDocument,
  ListenEvent,
  ListenHandle,
  Perspective,
} from './types'
import {
  BarkparkAPIError,
  BarkparkAuthError,
  BarkparkEdgeRuntimeError,
  BarkparkNetworkError,
  BarkparkValidationError,
} from './errors'
import { detectEdgeRuntime } from './util/edge-detect'
import { scopePrefix } from './scope'

// The server emits `: keepalive\n\n` every 30s (listen_controller.ex). If we see
// NEITHER data NOR a keepalive for this long, the TCP socket is half-open (no
// bytes, no FIN) and reader.read() would hang forever — never erroring, never
// reconnecting. 2.5× the keepalive interval tolerates one delayed/dropped
// keepalive before we give up on the socket and reconnect. See [idle-timeout-stall].
const DEFAULT_IDLE_TIMEOUT_MS = 75_000

// Cap the unframed decode buffer. A broken/malicious stream that emits bytes with
// no frame boundary (\n\n) would grow `buffer` without bound → OOM. 1 MiB is orders
// of magnitude above any legitimate SSE frame. See [buffer-unbounded].
const MAX_SSE_BUFFER_BYTES = 1_048_576

// Consecutive clean 200→EOF closes with zero data frames between them = a
// misconfigured proxy / instantly-terminating LB looping silently. EventSource
// would retry forever; after this many we escalate to a thrown error so the caller
// isn't stuck in an invisible loop. Resets on any data OR keepalive frame (a
// keepalive proves a real, live stream — an instantly-terminating LB never emits
// one). See [clean-close-infinite-silent].
const MAX_CONSECUTIVE_CLEAN_CLOSES = 5

// Under maxReconnects: 'unbounded' the clean-close escalation above is disarmed
// (retry-forever means forever on clean closes too). Compensation: past the old
// threshold the clean-close delay escalates on the jittered exponential up to
// this cap, so a dead LB costs ~4 requests/min instead of 60.
const CLEAN_CLOSE_MAX_DELAY_MS = 16_000

// Reconnect-delay jitter factor: 0.5–1.0×. Full jitter de-synchronizes a fleet's
// reconnect storm after a server restart (thundering herd) while keeping the delay
// bounded by its input (the 8s ceiling / 1s floor still hold). See [backoff-jitter].
function withJitter(ms: number): number {
  return (ms * (1 + Math.random())) / 2
}

export interface ListenOptions {
  perspective?: Perspective
  onUnsubscribe?: () => void
  /**
   * Max reconnect attempts after an *error* (clean stream close doesn't count).
   * Default 5. 0 disables. `'unbounded'` retries forever AND disarms the
   * consecutive-clean-close escalation (the delay escalates to a 16s cap instead
   * of throwing). The sentinel is a STRING deliberately, not Infinity:
   * `JSON.stringify(Infinity)` is `null`, which the `?? 5` default would silently
   * turn back into the bounded default across any serialization boundary — the
   * string survives JSON verbatim, and unknown strings fail loud.
   */
  maxReconnects?: number | 'unbounded'
  /** Base reconnect delay ms. Exponential backoff ×2, capped at 8000 ms. Default 500. */
  reconnectBaseMs?: number
  /**
   * Idle/keepalive watchdog: if no bytes (data OR server keepalive comment) arrive
   * within this many ms, the half-open socket is abandoned and reconnected. Default
   * 75000 (2.5× the server's 30s keepalive). Pass 0 (or a non-positive value) to disable.
   */
  idleTimeoutMs?: number
  /**
   * Called when a frame's `data:` payload does not parse as JSON and is skipped.
   * The frame is a lost event: the stream continues (one corrupt frame must not
   * kill a live subscription), but the loss is no longer invisible. `raw` is the
   * joined `data:` text as received, `err` the JSON.parse failure.
   *
   * Purely observational — throwing from it is not a supported way to stop the
   * stream, and a throw here is swallowed so a logging callback cannot take down
   * a subscription. Use it to log, count, or alert.
   */
  onDroppedFrame?: (raw: string, err: unknown) => void
  signal?: AbortSignal
}

/**
 * Open a live SSE stream against `/v1/data/listen/:dataset`.
 *
 * Returns a {@link ListenHandle} — an `AsyncIterable<ListenEvent<T>>` with a
 * `.unsubscribe()` method. Authors should `for await (const ev of handle)` and
 * call `handle.unsubscribe()` in their cleanup. Reconnects exponentially on
 * network drops (max 5 attempts by default) and sends `Last-Event-ID` on resume.
 *
 * Throws {@link BarkparkEdgeRuntimeError} synchronously in Workerd / Cloudflare
 * edge runtimes where streaming fetch is unavailable — poll via `client.docs()` instead.
 *
 * Prefer `client.listen(type, filter)` in app code.
 */
export function createListenHandle<T = BarkparkDocument>(
  config: BarkparkClientConfig,
  type?: string,
  filter?: Record<string, unknown>,
  opts?: ListenOptions,
): ListenHandle<T> {
  // Layer 1: edge detection — synchronous throw at call site, not at iterator consume.
  const edge = detectEdgeRuntime()
  if (edge !== null) {
    throw new BarkparkEdgeRuntimeError(
      `listen() is not supported in ${edge} runtime — streaming fetch is unavailable. ` +
        `Use polling via client.docs() on a short interval instead.`,
    )
  }

  // NaN or negative reconnect knobs are worse than useless: reconnectBaseMs: NaN
  // flows to Math.min(NaN * 2**n, 8000) = NaN → setTimeout(fn, NaN) coerces to 0, so
  // the client hammers the server with zero-delay reconnects instead of backing off.
  // Fail closed synchronously — before any connection is opened — like every other knob.
  // Widened additively for the 'unbounded' sentinel — Infinity is STILL rejected
  // (accepting it would silently relax a published BarkparkValidationError
  // contract, and it cannot survive JSON anyway).
  if (
    opts?.maxReconnects !== undefined &&
    opts.maxReconnects !== 'unbounded' &&
    !(Number.isInteger(opts.maxReconnects) && opts.maxReconnects >= 0)
  ) {
    throw new BarkparkValidationError(
      "listen: maxReconnects must be a non-negative integer or 'unbounded'",
      {
        field: 'maxReconnects',
      },
    )
  }
  if (
    opts?.reconnectBaseMs !== undefined &&
    !(
      Number.isInteger(opts.reconnectBaseMs) &&
      Number.isFinite(opts.reconnectBaseMs) &&
      opts.reconnectBaseMs > 0
    )
  ) {
    throw new BarkparkValidationError('listen: reconnectBaseMs must be a positive integer', {
      field: 'reconnectBaseMs',
    })
  }

  const abortController = new AbortController()
  // [signal-listener-leak] Capture the caller-signal 'abort' handler so teardown
  // can remove it. `{ once: true }` only self-removes if the signal actually FIRES;
  // a long-lived signal reused across many listen() handles would otherwise
  // accumulate one dead listener per torn-down handle (bounded memory leak).
  // removeEventListener is idempotent — safe to call after the signal already fired.
  let removeSignalListener: (() => void) | undefined
  if (opts?.signal) {
    const callerSignal = opts.signal
    if (callerSignal.aborted) {
      abortController.abort(callerSignal.reason)
    } else {
      const onCallerAbort = () => abortController.abort(callerSignal.reason)
      callerSignal.addEventListener('abort', onCallerAbort, { once: true })
      removeSignalListener = () => callerSignal.removeEventListener('abort', onCallerAbort)
    }
  }

  let unsubscribed = false
  let lastEventId: string | undefined
  let reconnectCount = 0
  let cleanCloseCount = 0
  const maxReconnectsOpt = opts?.maxReconnects ?? 5
  // 'unbounded' maps to POSITIVE_INFINITY internally so the reconnectCount
  // comparison below is unchanged; the sentinel additionally gates the
  // clean-close ×5 escalation (see the clean-close block).
  const unbounded = maxReconnectsOpt === 'unbounded'
  const maxReconnects = unbounded ? Number.POSITIVE_INFINITY : maxReconnectsOpt
  const reconnectBase = opts?.reconnectBaseMs ?? 500
  // `> 0` naturally disables on 0 / negative / NaN — no separate validation needed.
  const idleTimeoutMs = opts?.idleTimeoutMs ?? DEFAULT_IDLE_TIMEOUT_MS

  const handle: ListenHandle<T> = {
    unsubscribe() {
      if (unsubscribed) return
      unsubscribed = true
      removeSignalListener?.()
      try {
        abortController.abort(new BarkparkNetworkError('listen unsubscribed by caller'))
      } catch {
        /* ignore */
      }
      opts?.onUnsubscribe?.()
    },
    async *[Symbol.asyncIterator](): AsyncIterator<ListenEvent<T>> {
      try {
        outer: while (!unsubscribed) {
          try {
            const fetchImpl = config.fetch ?? globalThis.fetch
            if (typeof fetchImpl !== 'function') {
              throw new BarkparkNetworkError('fetch is unavailable in this runtime')
            }

            const base = config.projectUrl.replace(/\/+$/, '')
            // scopePrefix() is invoked at request time (not module top-level) so the
            // listen ↔ client import cycle stays benign. '' when unscoped (back-compat).
            const prefix = scopePrefix(config)
            const url = new URL(
              `${base}${prefix}/v1/data/listen/${encodeURIComponent(config.dataset)}`,
            )
            if (type) url.searchParams.set('types', type)
            const p = opts?.perspective ?? config.perspective
            if (p) url.searchParams.set('perspective', p)
            if (filter && typeof filter === 'object') {
              // Mirror the query builder's ISO-8601 normalization (filter-builder.ts
              // buildQueryString) — a bare String(Date) emits a locale string the
              // server can never match, silently no-matching the realtime filter.
              const enc = (x: unknown) => (x instanceof Date ? x.toISOString() : String(x))
              for (const [k, v] of Object.entries(filter)) {
                url.searchParams.set(
                  `filter[${k}]`,
                  Array.isArray(v) ? v.map(enc).join(',') : enc(v),
                )
              }
            }

            const headers: Record<string, string> = {
              Accept: 'text/event-stream',
              'X-Barkpark-Api-Version': config.apiVersion,
            }
            if (config.token) headers.Authorization = `Bearer ${config.token}`
            if (lastEventId !== undefined) headers['Last-Event-ID'] = lastEventId

            let response: Response
            try {
              response = await fetchImpl(url.toString(), {
                method: 'GET',
                headers,
                signal: abortController.signal,
              })
            } catch (fetchErr) {
              if (unsubscribed || abortController.signal.aborted) return
              throw new BarkparkNetworkError('listen: fetch failed', {
                cause: fetchErr,
                url: url.toString(),
              })
            }

            if (response.status === 401 || response.status === 403) {
              throw new BarkparkAuthError(`listen: ${response.status} auth failed`, {
                status: response.status,
                url: url.toString(),
              })
            }
            if (!response.ok) {
              throw new BarkparkAPIError(`listen: HTTP ${response.status}`, {
                status: response.status,
                url: url.toString(),
              })
            }
            const ct = response.headers.get('content-type') ?? ''
            if (!ct.includes('text/event-stream')) {
              throw new BarkparkAPIError(
                `listen: expected text/event-stream, got ${ct || '(none)'}`,
                { status: response.status, url: url.toString() },
              )
            }
            if (!response.body) {
              throw new BarkparkAPIError('listen: response has no body', {
                status: response.status,
                url: url.toString(),
              })
            }

            reconnectCount = 0 // successful open resets the error counter

            const reader = response.body.getReader()
            const decoder = new TextDecoder('utf-8')
            let buffer = ''

            try {
              while (!unsubscribed) {
                // [idle-timeout-stall] Watchdog: arm a timer before each read; ANY
                // byte (data OR keepalive comment) resolves read() and clears it, so
                // legitimate keepalive traffic never trips it. On a half-open socket
                // read() hangs — the timer fires and cancels the reader, which resolves
                // the pending read() with { done: true } → the clean-close reconnect
                // path below. (Aborting the shared abortController instead would set
                // .aborted → the catch returns, terminating the stream, not reconnecting.)
                let idleTimer: ReturnType<typeof setTimeout> | undefined
                if (idleTimeoutMs > 0)
                  idleTimer = setTimeout(() => reader.cancel().catch(() => {}), idleTimeoutMs)
                let result: ReadableStreamReadResult<Uint8Array>
                try {
                  result = await reader.read()
                } finally {
                  clearTimeout(idleTimer) // clearTimeout(undefined) is a no-op
                }
                const { done, value } = result
                if (done) break
                buffer += decoder.decode(value, { stream: true })

                // SSE frames are separated by blank line (\n\n). Also handle \r\n\r\n tolerantly.
                let frameEnd = findFrameBoundary(buffer)
                while (frameEnd !== -1) {
                  const frame = buffer.slice(0, frameEnd.start)
                  buffer = buffer.slice(frameEnd.end)

                  const parsed = parseSseFrame(frame)
                  if (!parsed) {
                    frameEnd = findFrameBoundary(buffer)
                    continue
                  }
                  if (parsed.eventId !== undefined) lastEventId = parsed.eventId

                  if (parsed.dataLines.length === 0) {
                    // pure comment / keepalive — not yielded. A keepalive still
                    // proves the endpoint is a real live stream, so it resets the
                    // silent-close escalation in BOTH modes — otherwise five 75s
                    // idle-watchdog cycles over a quiet board would kill a healthy
                    // stream. (An instantly-terminating LB never emits a
                    // 30s-cadence keepalive, so the detector keeps its teeth.)
                    cleanCloseCount = 0
                    frameEnd = findFrameBoundary(buffer)
                    continue
                  }

                  const joined = parsed.dataLines.join('\n')
                  let payload: Record<string, unknown>
                  try {
                    const v = JSON.parse(joined)
                    payload = v && typeof v === 'object' ? (v as Record<string, unknown>) : {}
                  } catch (parseErr) {
                    // [malformed-frame-silent] Malformed data — skip this frame,
                    // do not crash (killing a live subscription over one corrupt
                    // event is worse than losing it). But a skip is a LOST EVENT,
                    // and it used to be reported on NO channel at all — no throw,
                    // no callback, no counter — while the iterator's "here is
                    // every event" contract stayed nominally true. onDroppedFrame
                    // is that channel.
                    try {
                      opts?.onDroppedFrame?.(joined, parseErr)
                    } catch {
                      // A logging callback must not be able to kill the stream.
                    }
                    frameEnd = findFrameBoundary(buffer)
                    continue
                  }

                  const event = buildListenEvent<T>(parsed.eventName, parsed.eventId, payload)
                  cleanCloseCount = 0 // healthy data frame — reset the silent-close escalation
                  yield event
                  frameEnd = findFrameBoundary(buffer)
                }

                // [buffer-unbounded] Residual (post-drain) buffer holds only an
                // incomplete frame. If it exceeds the cap the stream is emitting bytes
                // with no boundary — surface an error instead of eating memory.
                if (buffer.length > MAX_SSE_BUFFER_BYTES) {
                  throw new BarkparkAPIError('listen: SSE buffer overflow (no frame boundary)')
                }
              }
            } finally {
              try {
                reader.releaseLock()
              } catch {
                /* ignore */
              }
            }

            // Clean stream close: reconnect with Last-Event-ID (matches EventSource semantics).
            // Not counted against maxReconnects — only errors are.
            if (unsubscribed) return
            // [clean-close-infinite-silent] EventSource-parity hardening: consecutive
            // clean closes that yielded NO data (the counter resets on any data frame)
            // mean the endpoint is looping silently. Escalate to a thrown error so the
            // caller eventually surfaces it instead of an invisible ~1s reconnect loop.
            cleanCloseCount++
            if (cleanCloseCount >= MAX_CONSECUTIVE_CLEAN_CLOSES && !unbounded) {
              throw new BarkparkAPIError('listen: repeated empty stream closes')
            }
            // A clean immediate 200→EOF means the server isn't really streaming
            // (misconfigured proxy / instantly-terminating LB). Floor the reconnect at 1s
            // so that case can't busy-spin — twin of the Go floor in internal/apiclient/change.go.
            // Jitter (0.5–1.0×, min 500ms) scatters a fleet's reconnects; still no busy-spin.
            // Under 'unbounded' the ×5 throw above is disarmed (retry-forever means
            // forever on clean closes too — any finite bound just relocates the
            // placebo); past the old threshold the delay escalates on the jittered
            // exponential capped at CLEAN_CLOSE_MAX_DELAY_MS.
            const cleanCloseFloor = Math.max(reconnectBase, 1000)
            const past = cleanCloseCount - MAX_CONSECUTIVE_CLEAN_CLOSES + 1
            const cleanCloseDelay =
              unbounded && past > 0
                ? Math.min(cleanCloseFloor * 2 ** past, CLEAN_CLOSE_MAX_DELAY_MS)
                : cleanCloseFloor
            await sleep(withJitter(cleanCloseDelay), abortController.signal)
            if (unsubscribed || abortController.signal.aborted) return
            continue outer
          } catch (err) {
            if (unsubscribed || abortController.signal.aborted) return

            // Dual-module safe check — instanceof can be unreliable across bundle boundaries (errors.ts §2-7).
            const code = (err as { code?: unknown })?.code
            if (code === 'BarkparkAuthError' || err instanceof BarkparkAuthError) throw err

            const isNetworkish =
              err instanceof BarkparkNetworkError ||
              (err instanceof BarkparkAPIError && (err.status ?? 0) >= 500)

            if (isNetworkish && reconnectCount < maxReconnects) {
              // [backoff-jitter] Jitter the exponential delay so a fleet doesn't
              // reconnect in lockstep after a server restart. ×(0.5–1.0) keeps the
              // 8s ceiling intact (bounded above by the un-jittered value).
              const delay = withJitter(Math.min(reconnectBase * 2 ** reconnectCount, 8000))
              reconnectCount++
              await sleep(delay, abortController.signal)
              if (unsubscribed || abortController.signal.aborted) return
              continue outer
            }
            throw err
          }
        }
      } finally {
        if (!unsubscribed) {
          unsubscribed = true
          removeSignalListener?.()
          try {
            abortController.abort()
          } catch {
            /* ignore */
          }
          opts?.onUnsubscribe?.()
        }
      }
    },
  }

  return handle
}

// --- helpers ---

interface ParsedFrame {
  eventName: 'welcome' | 'mutation' | 'message'
  eventId: string | undefined
  dataLines: string[]
}

function parseSseFrame(frame: string): ParsedFrame | null {
  if (frame.length === 0) return null
  let eventName: ParsedFrame['eventName'] = 'message'
  let eventId: string | undefined
  const dataLines: string[] = []
  for (const rawLine of frame.split('\n')) {
    const line = rawLine.replace(/\r$/, '')
    if (line.length === 0) continue
    if (line.startsWith(':')) continue // comment
    const colon = line.indexOf(':')
    if (colon === -1) continue
    const field = line.slice(0, colon)
    let val = line.slice(colon + 1)
    if (val.startsWith(' ')) val = val.slice(1)
    if (field === 'event') {
      eventName = (
        val === 'welcome' || val === 'mutation' ? val : 'message'
      ) as ParsedFrame['eventName']
    } else if (field === 'id') {
      eventId = val
    } else if (field === 'data') {
      dataLines.push(val)
    }
  }
  return { eventName, eventId, dataLines }
}

function findFrameBoundary(buffer: string): { start: number; end: number } | -1 {
  const lf = buffer.indexOf('\n\n')
  const crlf = buffer.indexOf('\r\n\r\n')
  if (lf === -1 && crlf === -1) return -1
  if (lf !== -1 && (crlf === -1 || lf < crlf)) return { start: lf, end: lf + 2 }
  return { start: crlf, end: crlf + 4 }
}

function buildListenEvent<T>(
  sseEvent: 'welcome' | 'mutation' | 'message',
  sseEventId: string | undefined,
  payload: Record<string, unknown>,
): ListenEvent<T> {
  const eventType: 'welcome' | 'mutation' = sseEvent === 'mutation' ? 'mutation' : 'welcome' // unknown SSE event → welcome; contract only emits welcome|mutation
  const eventId =
    sseEventId ??
    (payload['eventId'] !== undefined && payload['eventId'] !== null
      ? String(payload['eventId'])
      : '')

  const evt: ListenEvent<T> = { eventId, type: eventType }
  const m = payload['mutation']
  if (
    m === 'create' ||
    m === 'update' ||
    m === 'delete' ||
    m === 'publish' ||
    m === 'unpublish' ||
    m === 'discardDraft'
  ) {
    evt.mutation = m
  }
  if (typeof payload['documentId'] === 'string') evt.documentId = payload['documentId']
  if (typeof payload['rev'] === 'string') evt.rev = payload['rev']
  if ('previousRev' in payload) {
    const p = payload['previousRev']
    evt.previousRev = (p === null || typeof p === 'string' ? p : null) as string | null
  }
  if ('result' in payload && payload['result'] !== undefined) {
    evt.result = payload['result'] as T
  }
  if (Array.isArray(payload['syncTags'])) {
    evt.syncTags = (payload['syncTags'] as unknown[]).filter(
      (x): x is string => typeof x === 'string',
    )
  }
  return evt
}

function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const onAbort = () => {
      clearTimeout(timer)
      resolve()
    }
    if (signal.aborted) return resolve()
    const timer = setTimeout(() => {
      signal.removeEventListener('abort', onAbort)
      resolve()
    }, ms)
    signal.addEventListener('abort', onAbort, { once: true })
  })
}
