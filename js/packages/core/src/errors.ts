// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

export class BarkparkError extends Error {
  constructor(message?: string) {
    super(message)
    this.name = 'BarkparkError'
  }
}

export class BarkparkAPIError extends BarkparkError {
  status: number
  requestId: string | undefined
  constructor(message?: string, status: number = 0, requestId?: string) {
    super(message)
    this.name = 'BarkparkAPIError'
    this.status = status
    this.requestId = requestId
  }
}

export class BarkparkAuthError extends BarkparkAPIError {
  constructor(message?: string, status: number = 401, requestId?: string) {
    super(message, status, requestId)
    this.name = 'BarkparkAuthError'
  }
}

export class BarkparkNetworkError extends BarkparkError {
  constructor(message?: string) {
    super(message)
    this.name = 'BarkparkNetworkError'
  }
}

export class BarkparkTimeoutError extends BarkparkError {
  constructor(message?: string) {
    super(message)
    this.name = 'BarkparkTimeoutError'
  }
}

export class BarkparkRateLimitError extends BarkparkAPIError {
  retryAfterMs: number | undefined
  constructor(message?: string, status: number = 429, requestId?: string, retryAfterMs?: number) {
    super(message, status, requestId)
    this.name = 'BarkparkRateLimitError'
    this.retryAfterMs = retryAfterMs
  }
}

export class BarkparkNotFoundError extends BarkparkAPIError {
  constructor(message?: string, status: number = 404, requestId?: string) {
    super(message, status, requestId)
    this.name = 'BarkparkNotFoundError'
  }
}

export class BarkparkValidationError extends BarkparkError {
  constructor(message?: string) {
    super(message)
    this.name = 'BarkparkValidationError'
  }
}

export class BarkparkHmacError extends BarkparkError {
  constructor(message?: string) {
    super(message)
    this.name = 'BarkparkHmacError'
  }
}

export class BarkparkSchemaMismatchError extends BarkparkError {
  constructor(message?: string) {
    super(message)
    this.name = 'BarkparkSchemaMismatchError'
  }
}

export class BarkparkEdgeRuntimeError extends BarkparkError {
  constructor(message?: string) {
    super(message)
    this.name = 'BarkparkEdgeRuntimeError'
  }
}

export class BarkparkConflictError extends BarkparkAPIError {
  constructor(message?: string, status: number = 409, requestId?: string) {
    super(message, status, requestId)
    this.name = 'BarkparkConflictError'
  }
}
