// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// ADR-009 error taxonomy. Every class carries a `code` literal equal to its
// class name so consumers can match across bundle boundaries (pnpm hoist may
// produce duplicate copies; `instanceof` is unreliable, `err.code === '...'`
// is the supported fallback).

export interface BarkparkErrorOptions {
  cause?: unknown
  requestId?: string
  url?: string
  status?: number
  code?: string
}

/**
 * Abstract base for every Barkpark error. Every subclass sets `code` to its class name,
 * so callers can match across bundle boundaries via `err.code === 'BarkparkAuthError'`
 * when `instanceof` is unreliable (pnpm hoist duplicates).
 *
 * @see ADR-009 error taxonomy.
 */
export abstract class BarkparkError extends Error {
  public readonly code: string
  public readonly requestId?: string
  public readonly url?: string
  public readonly status?: number

  constructor(message: string, opts?: BarkparkErrorOptions) {
    super(message, opts?.cause !== undefined ? { cause: opts.cause } : undefined)
    this.name = new.target.name
    this.code = opts?.code ?? new.target.name
    if (opts?.requestId !== undefined) this.requestId = opts.requestId
    if (opts?.url !== undefined) this.url = opts.url
    if (opts?.status !== undefined) this.status = opts.status
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
