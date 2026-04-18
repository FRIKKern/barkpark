// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// HTTP transport. Every other module (client/handshake/docs/patch/transaction/
// fetchRaw) goes through `request<T>`. Responsibilities:
//   - Build URL + base headers (vendor Accept, Bearer, request-tag).
//   - Run onBeforeRequest / onResponse hooks.
//   - Fetch with per-attempt AbortController (config.timeoutMs).
//   - Decode Phoenix error envelope → typed error from errors.ts.
//   - Delegate retry to retry.ts; injects Idempotency-Key on retry for
//     writes that opted in via `retryPolicy: 'on-idempotency-key'`.
//
// See ADR-002 (fetch-only transport), ADR-008 (idempotency contract),
// ADR-009 (error taxonomy), ADR-010 (observability hooks),
// w6.3-phoenix-contract.md §Error envelope / §Status codes,
// w6.2-impl-spec.md §Retry policy / §Status → class.

import {
  BarkparkAPIError,
  BarkparkAuthError,
  BarkparkConflictError,
  BarkparkHmacError,
  BarkparkNetworkError,
  BarkparkNotFoundError,
  BarkparkRateLimitError,
  BarkparkSchemaMismatchError,
  BarkparkTimeoutError,
  BarkparkValidationError,
} from './errors'
import {
  DEFAULT_READ_POLICY,
  DEFAULT_WRITE_POLICY,
  IDEMPOTENT_WRITE_POLICY,
  retry,
  type RetryPolicy,
} from './retry'
import type {
  BarkparkClientConfig,
  RequestContext,
  ResponseContext,
} from './types'
import { buildBaseHeaders, pickRequestId, uuidv7 } from './util/headers'

export type TransportMethod = 'GET' | 'POST' | 'PATCH' | 'DELETE'

export interface TransportRequestOptions {
  method?: TransportMethod
  body?: unknown
  headers?: Record<string, string>
  signal?: AbortSignal
  /** Default 'read'. Writes default to no-retry unless caller sets retryPolicy. */
  kind?: 'read' | 'write'
  /** Opt-in for writes. 'on-idempotency-key' auto-generates uuidv7 header on retry. */
  retryPolicy?: 'none' | 'on-idempotency-key'
  /** Skip JSON decoding + error-envelope handling; caller gets the raw Response. */
  rawResponse?: boolean
}

export interface TransportResult<T> {
  data: T
  response: Response
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

function hasHeader(h: Record<string, string>, name: string): boolean {
  const lower = name.toLowerCase()
  for (const k of Object.keys(h)) {
    if (k.toLowerCase() === lower) return true
  }
  return false
}

function headersToRecord(h: Headers): Record<string, string> {
  const out: Record<string, string> = {}
  h.forEach((v, k) => {
    out[k] = v
  })
  return out
}

function parseRetryAfter(raw: string | null): number | undefined {
  if (raw === null || raw.length === 0) return undefined
  const n = Number(raw)
  if (Number.isFinite(n)) return Math.max(0, n * 1000)
  const date = Date.parse(raw)
  if (Number.isFinite(date)) return Math.max(0, date - Date.now())
  return undefined
}

function strOrUndefined(v: unknown): string | undefined {
  return typeof v === 'string' && v.length > 0 ? v : undefined
}

async function decodeErrorAndThrow(response: Response, url: string): Promise<never> {
  const status = response.status
  const requestIdHeader = response.headers.get('x-request-id') ?? undefined
  const raw = await response.text()

  let parsed: unknown = undefined
  if (raw.length > 0) {
    try {
      parsed = JSON.parse(raw)
    } catch {
      const apiOpts: { status: number; body: unknown; url: string; requestId?: string } = {
        status,
        body: raw,
        url,
      }
      if (requestIdHeader !== undefined) apiOpts.requestId = requestIdHeader
      throw new BarkparkAPIError('unexpected non-JSON response', apiOpts)
    }
  }

  const envelope =
    parsed !== null && typeof parsed === 'object' && 'error' in parsed
      ? ((parsed as { error?: unknown }).error as Record<string, unknown> | undefined)
      : undefined

  const code = envelope ? strOrUndefined(envelope['code']) : undefined
  const message =
    (envelope ? strOrUndefined(envelope['message']) : undefined) ?? `HTTP ${String(status)}`
  const requestId = pickRequestId(envelope) ?? requestIdHeader
  const details =
    envelope && envelope['details'] !== undefined && typeof envelope['details'] === 'object'
      ? (envelope['details'] as Record<string, unknown>)
      : undefined

  const base: { url: string; status: number; requestId?: string } = { url, status }
  if (requestId !== undefined) base.requestId = requestId

  // 401 / auth-class
  if (
    status === 401 ||
    code === 'unauthorized' ||
    code === 'unauthenticated' ||
    code === 'invalid_token'
  ) {
    throw new BarkparkAuthError(message, base)
  }

  // HMAC signature failure (webhook-side, but may surface via transport too)
  if (code === 'hmac_failed') {
    throw new BarkparkHmacError(message, base)
  }

  // 429 / rate-limited — honor both envelope details.retry_after (seconds) + Retry-After header
  if (status === 429 || code === 'rate_limited') {
    const headerMs = parseRetryAfter(response.headers.get('retry-after'))
    const bodySec = details?.['retry_after']
    const retryAfterMs = typeof bodySec === 'number' ? Math.max(0, bodySec * 1000) : headerMs
    const opts: typeof base & { retryAfterMs?: number } = { ...base }
    if (retryAfterMs !== undefined) opts.retryAfterMs = retryAfterMs
    throw new BarkparkRateLimitError(message, opts)
  }

  // 412 / precondition_failed — optimistic concurrency
  if (status === 412 || code === 'precondition_failed') {
    const expected = strOrUndefined(details?.['expected'])
    const actualRev = strOrUndefined(details?.['actual'])
    const opts: typeof base & { serverEtag?: string; serverDoc?: unknown } = { ...base }
    if (expected !== undefined) opts.serverEtag = expected
    if (actualRev !== undefined) opts.serverDoc = { rev: actualRev }
    throw new BarkparkConflictError(message, opts)
  }

  // apiVersion / schema-hash mismatch
  if (code === 'schema_mismatch' || code === 'apiversion_mismatch') {
    const opts: typeof base & {
      clientApiVersion?: string
      serverMinApiVersion?: string
      serverMaxApiVersion?: string
      localSchemaHash?: string
      remoteSchemaHash?: string
    } = { ...base }
    const cv = strOrUndefined(details?.['client_api_version'])
    const minV = strOrUndefined(details?.['server_min_api_version'])
    const maxV = strOrUndefined(details?.['server_max_api_version'])
    const lh = strOrUndefined(details?.['local_schema_hash'])
    const rh = strOrUndefined(details?.['remote_schema_hash'])
    if (cv !== undefined) opts.clientApiVersion = cv
    if (minV !== undefined) opts.serverMinApiVersion = minV
    if (maxV !== undefined) opts.serverMaxApiVersion = maxV
    if (lh !== undefined) opts.localSchemaHash = lh
    if (rh !== undefined) opts.remoteSchemaHash = rh
    throw new BarkparkSchemaMismatchError(message, opts)
  }

  // 422 / validation_failed — Phoenix `details` is field→[msg] map per w6.3
  if (status === 422 || code === 'validation_failed') {
    const opts: typeof base & { issues?: unknown[]; field?: string; reason?: string } = { ...base }
    if (details !== undefined) {
      const issues: unknown[] = []
      for (const [field, msgs] of Object.entries(details)) {
        if (Array.isArray(msgs)) {
          for (const m of msgs) issues.push({ field, message: m })
        } else {
          issues.push({ field, message: msgs })
        }
      }
      if (issues.length > 0) opts.issues = issues
    }
    throw new BarkparkValidationError(message, opts)
  }

  // 409 conflict without precondition — create of existing id, etc.
  if (status === 409 || code === 'conflict') {
    throw new BarkparkConflictError(message, base)
  }

  // 404 not_found / schema_unknown
  if (status === 404 || code === 'not_found' || code === 'schema_unknown') {
    throw new BarkparkNotFoundError(message, base)
  }

  // Everything else → generic API error with body + status.
  const genericOpts: typeof base & { body?: unknown } = { ...base }
  genericOpts.body = parsed ?? raw
  throw new BarkparkAPIError(message, genericOpts)
}

function pickPolicy(opts: TransportRequestOptions): RetryPolicy {
  const kind = opts.kind ?? 'read'
  if (kind === 'write') {
    return opts.retryPolicy === 'on-idempotency-key'
      ? { ...IDEMPOTENT_WRITE_POLICY }
      : { ...DEFAULT_WRITE_POLICY }
  }
  return { ...DEFAULT_READ_POLICY }
}

// ----------------------------------------------------------------------------
// Public entry point
// ----------------------------------------------------------------------------

export async function request<T>(
  config: BarkparkClientConfig,
  path: string,
  opts: TransportRequestOptions = {},
): Promise<TransportResult<T>> {
  const fetchFn = config.fetch ?? globalThis.fetch
  if (typeof fetchFn !== 'function') {
    throw new BarkparkNetworkError('fetch unavailable in this runtime')
  }
  if (!path.startsWith('/')) {
    throw new BarkparkValidationError('transport path must start with /', {
      reason: 'path-not-absolute',
    })
  }

  const url = `${config.projectUrl.replace(/\/$/, '')}${path}`
  const method: TransportMethod = opts.method ?? 'GET'

  // Headers are mutable across retries — onBeforeAttempt injects Idempotency-Key.
  const headers: Record<string, string> = buildBaseHeaders()
  if (config.token !== undefined && config.token.length > 0) {
    headers['Authorization'] = `Bearer ${config.token}`
  }
  const tagPrefix = config.requestTagPrefix ?? ''
  if (tagPrefix.length > 0) {
    headers['X-Barkpark-Request-Tag'] = `${tagPrefix}-${uuidv7()}`
  }
  if (opts.headers !== undefined) {
    for (const [k, v] of Object.entries(opts.headers)) headers[k] = v
  }

  const policy = pickPolicy(opts)
  if (opts.retryPolicy === 'on-idempotency-key' && !hasHeader(headers, 'idempotency-key')) {
    policy.onBeforeAttempt = () => {
      headers['Idempotency-Key'] = uuidv7()
    }
  }

  const timeoutMs = config.timeoutMs

  return retry<TransportResult<T>>(async (attempt) => {
    // Per-attempt timeout + user-signal combination.
    let timeoutTimer: ReturnType<typeof setTimeout> | undefined
    let timedOut = false
    let attemptSignal: AbortSignal | undefined = opts.signal

    if (timeoutMs !== undefined && timeoutMs > 0) {
      const ctrl = new AbortController()
      timeoutTimer = setTimeout(() => {
        timedOut = true
        ctrl.abort()
      }, timeoutMs)
      if (opts.signal !== undefined) {
        if (opts.signal.aborted) ctrl.abort()
        else opts.signal.addEventListener('abort', () => ctrl.abort(), { once: true })
      }
      attemptSignal = ctrl.signal
    }

    const startedAt = typeof performance !== 'undefined' ? performance.now() : Date.now()
    const reqCtx: RequestContext = {
      method,
      url,
      headers,
      attempt,
      startedAt,
    }
    if (opts.body !== undefined) reqCtx.body = opts.body
    if (config.onBeforeRequest) await config.onBeforeRequest(reqCtx)

    // After-hook values: the hook may mutate ctx to rewrite url/method/headers/body.
    const init: RequestInit = {
      method: reqCtx.method,
      headers: reqCtx.headers,
    }
    if (reqCtx.body !== undefined) {
      init.body = typeof reqCtx.body === 'string' ? reqCtx.body : JSON.stringify(reqCtx.body)
    }
    if (attemptSignal !== undefined) init.signal = attemptSignal

    let response: Response
    try {
      response = await fetchFn(reqCtx.url, init)
    } catch (err) {
      if (timeoutTimer !== undefined) clearTimeout(timeoutTimer)
      if (timedOut) {
        const opts2: { url: string; cause: unknown; timeoutMs?: number } = {
          url: reqCtx.url,
          cause: err,
        }
        if (timeoutMs !== undefined) opts2.timeoutMs = timeoutMs
        throw new BarkparkTimeoutError('request timed out', opts2)
      }
      // AbortError (user signal) and TypeError (fetch-level) both surface here.
      throw new BarkparkNetworkError(
        err instanceof Error ? err.message : 'network error',
        { url: reqCtx.url, cause: err },
      )
    }
    if (timeoutTimer !== undefined) clearTimeout(timeoutTimer)

    // onResponse hook runs on both success and error paths.
    if (config.onResponse) {
      const endedAt = typeof performance !== 'undefined' ? performance.now() : Date.now()
      const respHeaders = headersToRecord(response.headers)
      const respCtx: ResponseContext = {
        status: response.status,
        ok: response.ok,
        url: reqCtx.url,
        headers: respHeaders,
        durationMs: endedAt - startedAt,
        attempt,
      }
      const rid = strOrUndefined(respHeaders['x-request-id'])
      if (rid !== undefined) respCtx.requestId = rid
      const etagRaw = strOrUndefined(respHeaders['etag'])
      if (etagRaw !== undefined) respCtx.etag = etagRaw.replace(/^"|"$/g, '')
      await config.onResponse(respCtx)
    }

    if (opts.rawResponse === true) {
      return { data: response as unknown as T, response }
    }

    if (response.ok) {
      if (response.status === 204) {
        return { data: undefined as unknown as T, response }
      }
      const text = await response.text()
      if (text.length === 0) {
        return { data: undefined as unknown as T, response }
      }
      try {
        return { data: JSON.parse(text) as T, response }
      } catch (err) {
        throw new BarkparkAPIError('unexpected non-JSON response', {
          status: response.status,
          body: text,
          url: reqCtx.url,
          cause: err,
        })
      }
    }

    await decodeErrorAndThrow(response, reqCtx.url)
    // decodeErrorAndThrow returns Promise<never>; this line is unreachable.
    throw new BarkparkAPIError('unreachable', { status: response.status, url: reqCtx.url })
  }, policy)
}
