// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Error taxonomy. Every class carries a `code` literal equal to its
// class name so consumers can match across bundle boundaries (pnpm hoist may
// produce duplicate copies; `instanceof` is unreliable, `err.code === '...'`
// is the supported fallback).

export interface BarkparkErrorOptions {
  cause?: unknown
  requestId?: string
  url?: string
  status?: number
  code?: string
  /** The server envelope's machine-readable `code` (e.g. `mfa_required`,
   *  `rev_mismatch`, `validation_failed`) — distinct from {@link BarkparkError.code},
   *  which is the error's class name. */
  serverCode?: string
  /** Server-supplied, human-readable fix suggestion for this error code (the
   *  envelope's optional `hint` field; same string the `bp` CLI prints). */
  hint?: string
}

/**
 * Abstract base for every Barkpark error. Every subclass sets `code` to its class name,
 * so callers can match across bundle boundaries via `err.code === 'BarkparkAuthError'`
 * when `instanceof` is unreliable (pnpm hoist duplicates).
 */
export abstract class BarkparkError extends Error {
  public readonly code: string
  /** The server's machine-readable error code (e.g. `mfa_required`,
   *  `rev_mismatch`) — distinct from `code` (the class name). Undefined when the
   *  server provided no code (network/timeout errors, client-side guards). */
  public readonly serverCode?: string
  public readonly requestId?: string
  public readonly url?: string
  public readonly status?: number
  public readonly hint?: string

  constructor(message: string, opts?: BarkparkErrorOptions) {
    super(message, opts?.cause !== undefined ? { cause: opts.cause } : undefined)
    this.name = new.target.name
    this.code = opts?.code ?? new.target.name
    if (opts?.serverCode !== undefined) this.serverCode = opts.serverCode
    if (opts?.requestId !== undefined) this.requestId = opts.requestId
    if (opts?.url !== undefined) this.url = opts.url
    if (opts?.status !== undefined) this.status = opts.status
    if (opts?.hint !== undefined) this.hint = opts.hint
  }
}

export interface BarkparkAPIErrorOptions extends BarkparkErrorOptions {
  body?: unknown
}

/** Generic HTTP-API error (non-2xx with unknown/unclassified error code). Carries the raw body. */
export class BarkparkAPIError extends BarkparkError {
  public readonly body?: unknown
  constructor(message: string, opts?: BarkparkAPIErrorOptions) {
    super(message, opts)
    if (opts?.body !== undefined) this.body = opts.body
  }
}

/** 401/403 or token invalid. Retrying won't help — caller must fix credentials. */
export class BarkparkAuthError extends BarkparkError {}

/** fetch() threw (DNS failure, offline, TLS). Retried only for idempotent writes. */
export class BarkparkNetworkError extends BarkparkError {}

export interface BarkparkTimeoutErrorOptions extends BarkparkErrorOptions {
  timeoutMs?: number
}

/** Per-attempt timeout elapsed (see config.timeoutMs). Carries the timeout value. */
export class BarkparkTimeoutError extends BarkparkError {
  public readonly timeoutMs?: number
  constructor(message: string, opts?: BarkparkTimeoutErrorOptions) {
    super(message, opts)
    if (opts?.timeoutMs !== undefined) this.timeoutMs = opts.timeoutMs
  }
}

export interface BarkparkRateLimitErrorOptions extends BarkparkAPIErrorOptions {
  retryAfterMs?: number
}

/** 429 response; exposes `retryAfterMs` from Retry-After header or body details. */
export class BarkparkRateLimitError extends BarkparkAPIError {
  public readonly retryAfterMs?: number
  constructor(message: string, opts?: BarkparkRateLimitErrorOptions) {
    super(message, opts)
    if (opts?.retryAfterMs !== undefined) this.retryAfterMs = opts.retryAfterMs
  }
}

/** 404 (document/schema/dataset missing). `client.doc(...)` swallows this to return `null`. */
export class BarkparkNotFoundError extends BarkparkAPIError {}

export interface BarkparkValidationErrorOptions extends BarkparkErrorOptions {
  issues?: unknown[]
  field?: string
  reason?: string
}

/**
 * 422 validation failure (from Phoenix changesets) OR client-side input guard
 * (e.g. patch.set on a system field). `issues` is Phoenix's `{field, message}` list.
 */
export class BarkparkValidationError extends BarkparkError {
  public readonly issues?: unknown[]
  public readonly field?: string
  public readonly reason?: string
  constructor(message: string, opts?: BarkparkValidationErrorOptions) {
    super(message, opts)
    if (opts?.issues !== undefined) this.issues = opts.issues
    if (opts?.field !== undefined) this.field = opts.field
    if (opts?.reason !== undefined) this.reason = opts.reason
  }
}

/** HMAC signature verification failed (webhook-side). Never thrown on normal client calls. */
export class BarkparkHmacError extends BarkparkError {}

export interface BarkparkSchemaMismatchErrorOptions extends BarkparkErrorOptions {
  clientApiVersion?: string
  serverMinApiVersion?: string
  serverMaxApiVersion?: string
  localSchemaHash?: string
  remoteSchemaHash?: string
}

/**
 * apiVersion or schema-hash drift between client and server. Caller should
 * re-run codegen or bump `apiVersion`. See ADR-007 / ADR-011.
 */
export class BarkparkSchemaMismatchError extends BarkparkError {
  public readonly clientApiVersion?: string
  public readonly serverMinApiVersion?: string
  public readonly serverMaxApiVersion?: string
  public readonly localSchemaHash?: string
  public readonly remoteSchemaHash?: string
  constructor(message: string, opts?: BarkparkSchemaMismatchErrorOptions) {
    super(message, opts)
    if (opts?.clientApiVersion !== undefined) this.clientApiVersion = opts.clientApiVersion
    if (opts?.serverMinApiVersion !== undefined) this.serverMinApiVersion = opts.serverMinApiVersion
    if (opts?.serverMaxApiVersion !== undefined) this.serverMaxApiVersion = opts.serverMaxApiVersion
    if (opts?.localSchemaHash !== undefined) this.localSchemaHash = opts.localSchemaHash
    if (opts?.remoteSchemaHash !== undefined) this.remoteSchemaHash = opts.remoteSchemaHash
  }
}

/** Operation not available in this edge runtime (e.g. `listen()` in Workerd). Thrown synchronously. */
export class BarkparkEdgeRuntimeError extends BarkparkError {}

export interface BarkparkConflictErrorOptions extends BarkparkAPIErrorOptions {
  serverEtag?: string
  serverDoc?: unknown
}

/**
 * 409 conflict (id collision) or 412 precondition failed (ifMatch mismatch).
 * Carries `serverEtag` / `serverDoc` when available for recovery flows.
 */
export class BarkparkConflictError extends BarkparkAPIError {
  public readonly serverEtag?: string
  public readonly serverDoc?: unknown
  constructor(message: string, opts?: BarkparkConflictErrorOptions) {
    super(message, opts)
    if (opts?.serverEtag !== undefined) this.serverEtag = opts.serverEtag
    if (opts?.serverDoc !== undefined) this.serverDoc = opts.serverDoc
  }
}

/**
 * Union of every concrete error class name — the known values for the `code`
 * argument of {@link isBarkparkError}. Surfaces autocomplete at call sites;
 * the guard still accepts an arbitrary `string` (see the catch-all overload)
 * so codes from a hoisted/older bundle keep working, but only a union member
 * narrows `e` to its subclass.
 */
export type BarkparkErrorCode =
  | 'BarkparkAPIError'
  | 'BarkparkAuthError'
  | 'BarkparkNetworkError'
  | 'BarkparkTimeoutError'
  | 'BarkparkRateLimitError'
  | 'BarkparkNotFoundError'
  | 'BarkparkValidationError'
  | 'BarkparkHmacError'
  | 'BarkparkSchemaMismatchError'
  | 'BarkparkEdgeRuntimeError'
  | 'BarkparkConflictError'

/**
 * Type guard for Barkpark errors that works across bundle boundaries.
 *
 * Matches on the string `code` field (equal to the class name) instead of
 * `instanceof`, so it holds even when pnpm hoisting yields duplicate copies of
 * a class. Pass `code` to narrow to a specific error (e.g.
 * `isBarkparkError(e, 'BarkparkConflictError')`), letting consumers drop the
 * verbose instanceof-or-`err.code` dance and the `as any` casts — the typed
 * overloads below narrow `e` all the way to the matching subclass, so its
 * extra fields (`retryAfterMs`, `serverEtag`, `timeoutMs`, `issues`, …) are
 * reachable without a cast.
 */
/**
 * The response-guard ladder the two STREAMING paths share.
 *
 * `listen()` and `exportDataset()` both bypass the JSON transport — their
 * bodies are streams, not envelopes — so each carried its own copy of
 * auth-check, ok-check, body-check, differing only in a label and (for listen)
 * an extra content-type check. Folding them keeps the two in step and pays for
 * the fetch fix in export.ts (core is on a hard gzipped budget — js/CLAUDE.md
 * "Bundle budget").
 *
 * Every message and error class is reproduced verbatim from the two copies, and
 * the ORDER is preserved exactly: auth, then ok, then content-type (listen
 * only), then body — so a response that fails two checks still reports the same
 * one it reported before.
 *
 * `url` is threaded on the error only when the caller has one, matching what
 * each site already passed.
 */
export function assertStreamResponse(
  response: Response,
  label: string,
  opts?: { url?: string; contentType?: string },
): asserts response is Response & { body: ReadableStream<Uint8Array> } {
  const meta = {
    status: response.status,
    ...(opts?.url !== undefined ? { url: opts.url } : {}),
  }
  if (response.status === 401 || response.status === 403) {
    throw new BarkparkAuthError(`${label}: ${response.status} auth failed`, meta)
  }
  if (!response.ok) {
    throw new BarkparkAPIError(`${label}: HTTP ${response.status}`, meta)
  }
  if (opts?.contentType !== undefined) {
    const ct = response.headers.get('content-type') ?? ''
    if (!ct.includes(opts.contentType)) {
      throw new BarkparkAPIError(
        `${label}: expected ${opts.contentType}, got ${ct || '(none)'}`,
        meta,
      )
    }
  }
  if (!response.body) {
    throw new BarkparkAPIError(`${label}: response has no body`, meta)
  }
}

export function isBarkparkError(e: unknown, code: 'BarkparkAPIError'): e is BarkparkAPIError
export function isBarkparkError(e: unknown, code: 'BarkparkAuthError'): e is BarkparkAuthError
export function isBarkparkError(e: unknown, code: 'BarkparkNetworkError'): e is BarkparkNetworkError
export function isBarkparkError(e: unknown, code: 'BarkparkTimeoutError'): e is BarkparkTimeoutError
export function isBarkparkError(e: unknown, code: 'BarkparkRateLimitError'): e is BarkparkRateLimitError
export function isBarkparkError(e: unknown, code: 'BarkparkNotFoundError'): e is BarkparkNotFoundError
export function isBarkparkError(e: unknown, code: 'BarkparkValidationError'): e is BarkparkValidationError
export function isBarkparkError(e: unknown, code: 'BarkparkHmacError'): e is BarkparkHmacError
export function isBarkparkError(
  e: unknown,
  code: 'BarkparkSchemaMismatchError',
): e is BarkparkSchemaMismatchError
export function isBarkparkError(e: unknown, code: 'BarkparkEdgeRuntimeError'): e is BarkparkEdgeRuntimeError
export function isBarkparkError(e: unknown, code: 'BarkparkConflictError'): e is BarkparkConflictError
export function isBarkparkError(e: unknown, code?: BarkparkErrorCode | (string & {})): e is BarkparkError
export function isBarkparkError(e: unknown, code?: string): e is BarkparkError {
  if (typeof e !== 'object' || e === null) return false
  const c = (e as { code?: unknown }).code
  if (typeof c !== 'string') return false
  return code === undefined || c === code
}
