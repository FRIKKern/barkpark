// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// SSE live-stream transport. ADR-005 + w6.3-phoenix-contract.md §listen.
// - Returns a ListenHandle<T>: AsyncIterable + .unsubscribe().
// - Edge runtimes throw BarkparkEdgeRuntimeError SYNCHRONOUSLY (not lazily).
// - Uses fetch() + ReadableStream reader for custom headers (Bearer, Last-Event-ID);
//   EventSource is unavailable because it does not support Authorization.
// - Reconnects with exponential backoff + Last-Event-ID on network drops.
// - Yields ListenEvent<T> as defined in types.ts:117-126.

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
} from './errors'
import { detectEdgeRuntime } from './util/edge-detect'

export interface ListenOptions {
  perspective?: Perspective
  onUnsubscribe?: () => void
  /** Max reconnect attempts after an *error* (clean stream close doesn't count). Default 5. 0 disables. */
  maxReconnects?: number
  /** Base reconnect delay ms. Exponential backoff ×2, capped at 8000 ms. Default 500. */
  reconnectBaseMs?: number
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
 *
 * @see ADR-005 §SSE transport.
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

  const abortController = new AbortController()
  if (opts?.signal) {
    if (opts.signal.aborted) {
      abortController.abort(opts.signal.reason)
    } else {
      opts.signal.addEventListener(
        'abort',
        () => abortController.abort(opts.signal?.reason),
        { once: true },
      )
    }
  }

  let unsubscribed = false
  let lastEventId: string | undefined
  let reconnectCount = 0
  const maxReconnects = opts?.maxReconnects ?? 5
  const reconnectBase = opts?.reconnectBaseMs ?? 500

  const handle: ListenHandle<T> = {
    unsubscribe() {
      if (unsubscribed) return
      unsubscribed = true
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
            const url = new URL(`${base}/v1/data/listen/${config.dataset}`)
            if (type) url.searchParams.set('types', type)
            const p = opts?.perspective ?? config.perspective
            if (p) url.searchParams.set('perspective', p)
            if (filter && typeof filter === 'object') {
              for (const [k, v] of Object.entries(filter)) {
                url.searchParams.set(`filter[${k}]`, String(v))
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
              throw new BarkparkNetworkError('listen: fetch failed', { cause: fetchErr, url: url.toString() })
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
                const { done, value } = await reader.read()
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
                    // pure comment / keepalive — not yielded
                    frameEnd = findFrameBoundary(buffer)
                    continue
                  }

                  let payload: Record<string, unknown>
                  try {
                    const joined = parsed.dataLines.join('\n')
                    const v = JSON.parse(joined)
                    payload = v && typeof v === 'object' ? (v as Record<string, unknown>) : {}
                  } catch {
                    // Malformed data — skip this frame, do not crash
                    frameEnd = findFrameBoundary(buffer)
                    continue
                  }

                  const event = buildListenEvent<T>(parsed.eventName, parsed.eventId, payload)
                  yield event
                  frameEnd = findFrameBoundary(buffer)
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
              const delay = Math.min(reconnectBase * 2 ** reconnectCount, 8000)
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
      eventName = (val === 'welcome' || val === 'mutation' ? val : 'message') as ParsedFrame['eventName']
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
  const eventType: 'welcome' | 'mutation' =
    sseEvent === 'mutation' ? 'mutation' : 'welcome' // unknown SSE event → welcome; contract only emits welcome|mutation
  const eventId =
    sseEventId ??
    (payload['eventId'] !== undefined && payload['eventId'] !== null
      ? String(payload['eventId'])
      : '')

  const evt: ListenEvent<T> = { eventId, type: eventType }
  const m = payload['mutation']
  if (m === 'create' || m === 'update' || m === 'delete' || m === 'publish' || m === 'unpublish') {
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
    evt.syncTags = (payload['syncTags'] as unknown[]).filter((x): x is string => typeof x === 'string')
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

/**
 * Back-compat scaffold export. The public API is `createListenHandle`.
 * `listen` on the client is wired via client.ts; this re-export exists only so
 * index.ts re-export doesn't break during incremental migration.
 */
export function listen<T = BarkparkDocument>(
  config: BarkparkClientConfig,
  type?: string,
  filter?: Record<string, unknown>,
  opts?: ListenOptions,
): ListenHandle<T> {
  return createListenHandle<T>(config, type, filter, opts)
}
