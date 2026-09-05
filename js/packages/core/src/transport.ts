// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// HTTP transport. Every other module (client/handshake/docs/patch/transaction/
// fetchRaw) goes through `request<T>`. Responsibilities:
//   - Build URL + base headers (vendor Accept, Bearer, request-tag).
//   - Run onBeforeRequest / onResponse hooks.
//   - Fetch with per-attempt AbortController (config.timeoutMs).
//   - Decode Phoenix error envelope → typed error from errors.ts.
//   - Delegate retry to retry.ts; injects one stable Idempotency-Key for
//     writes that opted in via `retryPolicy: 'on-idempotency-key'`.
//
// Contracts enforced here: fetch-only (no node: built-ins, Edge-safe); one stable
// Idempotency-Key per opted-in write; the Phoenix error envelope decoded to the typed
// errors in errors.ts (which owns the status → class mapping); and the
// X-Barkpark-Request-Tag observability header.

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
import type { BarkparkClientConfig, RequestContext, ResponseContext } from './types'
import { buildBaseHeaders, pickRequestId, uuidv7 } from './util/headers'

/**
 * @internal Names the HTTP verbs of a layer consumers do not address. Every
 * supported operation is a named function (`getDoc`, `publishDoc`,
 * `uploadAsset`, …) that picks its own verb; a consumer never chooses one. The
 * standard `RequestInit['method']` covers anyone doing their own fetch.
 */
export type TransportMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'

/**
 * @internal The option bag of `request`, which is itself internal — see the
 * marker there. Several fields (`rawResponse`, `kind`, `retryPolicy`) are
 * meaningful only to the layer that assembles a Barkpark call, and the ones a
 * consumer legitimately wants are already re-exposed on the public operations
 * as `signal`, `timeoutMs`, `retry` and `idempotencyKey`.
 */
export interface TransportRequestOptions {
  method?: TransportMethod
  body?: unknown
  headers?: Record<string, string>
  signal?: AbortSignal
  /** Default 'read'. Writes default to no-retry unless caller sets retryPolicy. */
  kind?: 'read' | 'write'
  /** Opt-in for writes. 'on-idempotency-key' auto-generates one stable uuidv7
   *  Idempotency-Key shared by every attempt, so server-side dedup can collapse retries. */
  retryPolicy?: 'none' | 'on-idempotency-key'
  /** Skip JSON decoding + error-envelope handling; caller gets the raw Response. */
  rawResponse?: boolean
  /** Per-call timeout override (ms). Falls back to the client `timeoutMs`, then
   *  the default (30000 reads / 60000 writes). 0 disables the timeout. */
  timeoutMs?: number
  /** Overall budget (ms) for this call, RETRIES AND BACKOFF SLEEPS INCLUDED —
   *  as opposed to `timeoutMs`, which bounds one attempt. Falls back to the
   *  client `deadlineMs`; undefined means unbounded. When set, a retry that
   *  cannot complete inside the remaining time is not attempted at all and the
   *  last error is thrown immediately. See the contract in retry.ts. */
  deadlineMs?: number
}

/**
 * @internal The return shape of the internal `request`. Public operations
 * deliberately do NOT return this: they hand back the decoded payload, and
 * where the raw `Response` genuinely matters they say so in their own type
 * (`fetchRawDoc`, `exportDataset`). Exporting this pair would suggest every
 * call carries a `Response` a consumer may read, which would be false — the
 * body has already been consumed by the time `request` returns.
 */
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

// Read the response body text with the SAME error taxonomy as the fetch-level
// catch. `response.text()` can reject mid-stream (a TCP reset while the body is
// still arriving) with a raw TypeError; that rejection sits outside the fetch
// try/catch and after the timeout timer is cleared, so without this it escapes
// the taxonomy — defaultShouldRetry returns false for a non-Barkpark error and
// never retries, even an idempotent GET. Mirror the fetch-level catch: a
// caller-initiated abort (opts.signal) is a cancellation, re-throw its
// AbortError untouched (caller detects it via `err.name === 'AbortError'`);
// otherwise wrap as a retryable BarkparkNetworkError.
async function readBodyText(
  response: Response,
  url: string,
  signal: AbortSignal | undefined,
): Promise<string> {
  try {
    return await response.text()
  } catch (err) {
    if (signal?.aborted) throw err
    throw new BarkparkNetworkError(err instanceof Error ? err.message : 'network error', {
      url,
      cause: err,
    })
  }
}

async function decodeErrorAndThrow(
  response: Response,
  url: string,
  signal: AbortSignal | undefined,
): Promise<never> {
  const status = response.status
  const requestIdHeader = response.headers.get('x-request-id') ?? undefined
  const raw = await readBodyText(response, url, signal)

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

  const errorField =
    parsed !== null && typeof parsed === 'object' && 'error' in parsed
      ? (parsed as { error?: unknown }).error
      : undefined

  // Canonical envelope: `error` is an object ({code, message, request_id, hint}).
  const envelope =
    typeof errorField === 'object' && errorField !== null
      ? (errorField as Record<string, unknown>)
      : undefined

  // Bare string-valued `error` (e.g. {"error":"not_found"} from some admin /
  // legacy endpoints, or the pre-canonical {"error":"halted","reason":…}).
  // Decode it symmetrically with the bp CLI's classifyError: the string is the
  // machine `code`, and the message unless a sibling `reason` is present. Before
  // this, a string `error` was cast to an object and read as {}, so `serverCode`
  // came back undefined and the message degraded to a bare `HTTP <status>`.
  const bareCode = strOrUndefined(errorField)
  const bareReason =
    parsed !== null && typeof parsed === 'object'
      ? strOrUndefined((parsed as { reason?: unknown }).reason)
      : undefined

  const code = envelope ? strOrUndefined(envelope['code']) : bareCode
  const message =
    (envelope ? strOrUndefined(envelope['message']) : (bareReason ?? bareCode)) ??
    `HTTP ${String(status)}`
  const requestId = pickRequestId(envelope) ?? requestIdHeader
  const hint = envelope ? strOrUndefined(envelope['hint']) : undefined
  // `!== null` is load-bearing: typeof null === 'object', so without it a
  // `details: null` envelope (a normal Phoenix changeset-less 422) sets
  // details = null, and the 422 branch's `Object.entries(details)` then throws a
  // raw TypeError that escapes the error taxonomy (the caller loses the status,
  // serverCode, message, and request_id and gets a non-BarkparkError).
  const details =
    envelope && typeof envelope['details'] === 'object' && envelope['details'] !== null
      ? (envelope['details'] as Record<string, unknown>)
      : undefined

  // The envelope's top-level `reason` — a sub-code sibling to `code`/`message`
  // inside the canonical `error` object (api/lib/barkpark/content/errors.ex
  // `build/1`, e.g. `forbidden_membership`'s `reason: "not_a_member"`,
  // `:replay`'s `reason: "replay"`). Distinct from `bareReason` above, which is
  // the PRE-canonical bare-string-`error` shape's sibling `reason` used only as
  // a message fallback — this one rides the canonical object envelope through
  // to the thrown error unchanged.
  const reason = envelope ? strOrUndefined(envelope['reason']) : undefined

  // `hint` + `serverCode` + `details` + `reason` live on `base`, which is spread
  // into every error's options below, so the server's fix-suggestion, its
  // machine-readable code, its structured details, and its reason sub-code all
  // reach EVERY thrown error class — previously only the 429/412/422 branches
  // picked individual fields out of `details`, so the 401/403/409/404 branches
  // (e.g. `duplicate_task`'s `details.similar`, `forbidden_membership`'s
  // `reason`, `schema_has_documents`'s `details.count`) silently dropped them.
  // serverCode is what lets a caller distinguish e.g. `mfa_required` from
  // `invalid_credentials` (both BarkparkAuthError) — `code` stays the class
  // name for the cross-bundle instanceof fallback.
  const base: {
    url: string
    status: number
    requestId?: string
    hint?: string
    serverCode?: string
    details?: Record<string, unknown>
    reason?: string
  } = { url, status }
  if (requestId !== undefined) base.requestId = requestId
  if (hint !== undefined) base.hint = hint
  if (code !== undefined) base.serverCode = code
  if (details !== undefined) base.details = details
  if (reason !== undefined) base.reason = reason

  // 401 / 403 auth-class. BarkparkAuthError is documented as "401/403 or token
  // invalid" — a 403 (token lacks permission, CORS/CSRF rejection) is the same
  // "fix your credentials, retrying won't help" class as a 401, so it maps here
  // rather than falling through to a generic BarkparkAPIError.
  if (
    status === 401 ||
    status === 403 ||
    code === 'unauthorized' ||
    code === 'unauthenticated' ||
    code === 'invalid_token' ||
    code === 'forbidden' ||
    code === 'cors_forbidden' ||
    code === 'csrf_required'
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
    const opts: typeof base & { issues?: unknown[]; field?: string } = { ...base }
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

/**
 * @internal The unvalidated escape hatch under every public operation. It takes
 * a raw `path` and appends it to the configured base URL, so exporting it would
 * publish a way to call arbitrary endpoints while bypassing the scope prefixing
 * and path-segment guards that the named operations apply — a consumer could
 * reach a URL this package never intended to construct. It also returns a
 * `Response` whose body is already consumed. Callers who need an unmodelled
 * endpoint should use their own `fetch` (the client's `fetch` config option
 * exists to keep instrumentation shared), or ask for the operation to be added.
 */
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

  // Headers are shared across retries — a stable Idempotency-Key (set once below
  // for 'on-idempotency-key' writes) rides every attempt so dedup can collapse them.
  const headers: Record<string, string> = buildBaseHeaders()
  if (config.token !== undefined && config.token.length > 0) {
    headers['Authorization'] = `Bearer ${config.token}`
  }
  // Observability tag — on by default with the documented 'bp' prefix;
  // set `requestTagPrefix: ''` to opt out.
  const tagPrefix = config.requestTagPrefix ?? 'bp'
  if (tagPrefix.length > 0) {
    headers['X-Barkpark-Request-Tag'] = `${tagPrefix}-${uuidv7()}`
  }
  if (opts.headers !== undefined) {
    for (const [k, v] of Object.entries(opts.headers)) headers[k] = v
  }

  const policy = pickPolicy(opts)
  if (opts.retryPolicy === 'on-idempotency-key' && !hasHeader(headers, 'idempotency-key')) {
    // One stable key set ONCE, shared by every attempt (including attempt 1), so
    // the server's hash(raw_key, token, method, path) dedup collapses a retried
    // write onto the original — a lost-response-then-retry can't double-apply it.
    headers['Idempotency-Key'] = uuidv7()
  }

  // Resolve the request timeout: per-call override → client config → documented
  // default (30000 reads / 60000 writes). Previously this was just
  // `config.timeoutMs`, so an un-configured client applied NO timeout — a hung
  // request hung forever, contradicting the documented default. `0` disables it.
  const timeoutMs = opts.timeoutMs ?? config.timeoutMs ?? (opts.kind === 'write' ? 60_000 : 30_000)

  // The WHOLE-call deadline, distinct from the per-attempt `timeoutMs` above.
  // Undefined by default — an unbounded caller has not asked us to hurry, and
  // inventing a bound here would silently shorten every existing consumer's
  // reads. A caller with a real global bound (a route handler's budget, an
  // AbortSignal.timeout) opts in, and the retry loop then declines any retry
  // that cannot finish inside it.
  const deadlineMs = opts.deadlineMs ?? config.deadlineMs
  if (deadlineMs !== undefined && deadlineMs > 0) policy.deadlineAt = Date.now() + deadlineMs

  return retry<TransportResult<T>>(
    async (attempt) => {
      // Per-attempt timeout + user-signal combination.
      let timeoutTimer: ReturnType<typeof setTimeout> | undefined
      let timedOut = false
      let attemptSignal: AbortSignal | undefined = opts.signal
      // [signal-listener-leak] Same hazard listen.ts documents at its own
      // [signal-listener-leak] block, same idiom: `{ once: true }` only
      // self-removes if the signal actually FIRES. The caller's signal outlives
      // the attempt (one AbortController held across a component's or job's whole
      // lifetime is the normal way to use this API), so every attempt that ended
      // any other way -- success, HTTP error, retry, timeout, a throwing hook --
      // left a dead handler bound to it. One per ATTEMPT, not per request: Node's
      // EventTarget starts warning past 10. Capture the remover and run it in the
      // attempt-wide finally below, which every exit path passes through.
      // removeEventListener is idempotent, so it is safe after the signal fired.
      let removeSignalListener: (() => void) | undefined

      if (timeoutMs !== undefined && timeoutMs > 0) {
        const ctrl = new AbortController()
        timeoutTimer = setTimeout(() => {
          timedOut = true
          ctrl.abort()
        }, timeoutMs)
        if (opts.signal !== undefined) {
          if (opts.signal.aborted) ctrl.abort()
          else {
            const callerSignal = opts.signal
            const onCallerAbort = () => ctrl.abort()
            callerSignal.addEventListener('abort', onCallerAbort, { once: true })
            removeSignalListener = () => callerSignal.removeEventListener('abort', onCallerAbort)
          }
        }
        attemptSignal = ctrl.signal
      }

      // Attempt-wide teardown: EVERY exit from here on -- a returned
      // TransportResult, a thrown typed error, a retry, a caller abort, a
      // throwing onBeforeRequest hook -- unwinds through this finally, which is
      // the only place the caller-signal listener above is guaranteed to be
      // dropped. (The inner finally below covers the timeout timer only, and
      // only from after the hook onward.)
      try {
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
          if (typeof reqCtx.body === 'string') {
            init.body = reqCtx.body
          } else if (typeof FormData !== 'undefined' && reqCtx.body instanceof FormData) {
            // Multipart (e.g. media upload): pass FormData through and drop the JSON
            // Content-Type so fetch sets `multipart/form-data` with its own boundary.
            init.body = reqCtx.body
            delete reqCtx.headers['Content-Type']
          } else {
            init.body = JSON.stringify(reqCtx.body)
          }
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
          // A caller-initiated abort (opts.signal) is a cancellation, NOT a network
          // failure: surface the standard AbortError so callers detect it via
          // `err.name === 'AbortError'` (exactly as with a bare fetch) and let it
          // fail fast — defaultShouldRetry returns false for a non-Barkpark error,
          // so it is never retried. Without this, an aborted read was wrapped as a
          // retryable BarkparkNetworkError and re-tried up to 3× with backoff. The
          // timeout abort is already handled above via `timedOut`, so `signal.aborted`
          // here means the caller's signal — re-throw fetch's AbortError untouched.
          if (opts.signal?.aborted) {
            throw err
          }
          // A genuine fetch-level failure (DNS/offline/TLS) is retryable.
          throw new BarkparkNetworkError(err instanceof Error ? err.message : 'network error', {
            url: reqCtx.url,
            cause: err,
          })
        }

        // The deadline is NOT cleared here: timeoutMs bounds the whole request,
        // body included. Clearing at headers let a server that streamed headers
        // and then stalled the body (slow-loris) hang request() forever — the
        // documented timeout never fired. The timer now stays armed through the
        // hook + body read (cleared in the finally below); rawResponse clears it
        // before returning, since there the CALLER owns the body stream and an
        // export may legitimately outlive timeoutMs.
        try {
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
            // CACHE VALIDATOR, observability only. This is the HTTP `ETag`
            // RESPONSE HEADER (RFC 9110 §8.8.1) — "is the cached
            // REPRESENTATION still valid?" — which folds the dataset schema
            // hash on top of the document rev. It is NOT a write precondition:
            // never feed `respCtx.etag` into `ifMatch` / `If-Match`. The write
            // token is the BODY's rev, which `getDoc` returns as
            // `DocResult.etag` (js/packages/core/src/doc.ts).
            const etagRaw = strOrUndefined(respHeaders['etag'])
            if (etagRaw !== undefined) respCtx.etag = etagRaw.replace(/^"|"$/g, '')
            await config.onResponse(respCtx)
          }

          if (opts.rawResponse === true) {
            if (timeoutTimer !== undefined) clearTimeout(timeoutTimer)
            return { data: response as unknown as T, response }
          }

          if (response.ok) {
            if (response.status === 204) {
              return { data: undefined as unknown as T, response }
            }
            const text = await readBodyText(response, reqCtx.url, opts.signal)
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

          await decodeErrorAndThrow(response, reqCtx.url, opts.signal)
          // decodeErrorAndThrow returns Promise<never>; this line is unreachable.
          throw new BarkparkAPIError('unreachable', { status: response.status, url: reqCtx.url })
        } catch (err) {
          // The deadline fired mid-body (or mid-hook): the abort surfaces as an
          // AbortError from response.text() — or its retryable BarkparkNetworkError
          // wrap from readBodyText. Reclassify OUR abort as the timeout it is; a
          // caller abort (opts.signal) was already re-thrown raw and is excluded.
          if (
            timedOut &&
            opts.signal?.aborted !== true &&
            (err instanceof BarkparkNetworkError ||
              (err instanceof Error && err.name === 'AbortError'))
          ) {
            const o: { url: string; cause: unknown; timeoutMs?: number } = {
              url: reqCtx.url,
              cause: err,
            }
            if (timeoutMs !== undefined) o.timeoutMs = timeoutMs
            throw new BarkparkTimeoutError('request timed out', o)
          }
          throw err
        } finally {
          if (timeoutTimer !== undefined) clearTimeout(timeoutTimer)
        }
      } finally {
        removeSignalListener?.()
      }
      // Pass the caller's signal so an abort during a between-attempt backoff sleep
      // cancels the retry immediately (surfaced as an AbortError) rather than
      // blocking until the delay elapses.
    },
    policy,
    opts.signal,
  )
}
