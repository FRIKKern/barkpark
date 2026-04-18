// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Public API surface of `@barkpark/core`. Every name here becomes a permanent
// contract — add only symbols with documented intent. See ADR-002 through
// ADR-011 for the contracts backing each export.

// --- Client factory + handshake --------------------------------------------
export { createClient } from './client'
export { createHandshakeCache } from './handshake'

// --- Operation factories (composable without createClient) -----------------
export { createPatch } from './patch'
export { createTransaction } from './transaction'
export { createDocsOperation } from './docs'
export { getDoc } from './doc'
export { publishDoc, unpublishDoc } from './publish'
export { fetchRawDoc } from './fetchRaw'
export { createListenHandle } from './listen'

// --- Filter / builder utilities (used by advanced callers + codegen) -------
export { createDocsBuilder, makeFilterExpression, buildQueryString } from './filter-builder'
export type { FilterExpression, BuilderState } from './filter-builder'

// --- Errors — export class AND note: every class has a `code` literal equal
// to its class name, for cross-bundle matching when `instanceof` is unreliable
// (ADR-009 §code taxonomy).
export {
  BarkparkError,
  BarkparkAPIError,
  BarkparkAuthError,
  BarkparkConflictError,
  BarkparkEdgeRuntimeError,
  BarkparkHmacError,
  BarkparkNetworkError,
  BarkparkNotFoundError,
  BarkparkRateLimitError,
  BarkparkSchemaMismatchError,
  BarkparkTimeoutError,
  BarkparkValidationError,
} from './errors'

// --- Typed-pass-through helpers (identity functions) -----------------------
/** Typed identity — lets callers attach types to an existing client value. */
export function typedClient<C>(client: C): C {
  return client
}
/** Typed identity — reserved for a future action-binding helper; currently a no-op. */
export function defineActions<C>(client: C): C {
  return client
}

// --- Public type surface ----------------------------------------------------
export type {
  ApiVersion,
  BarkparkClient,
  BarkparkClientConfig,
  BarkparkDocument,
  BarkparkHooks,
  CommitOptions,
  DocsBuilder,
  FilterOp,
  FilterValue,
  ListenEvent,
  ListenHandle,
  MetaResponse,
  MutateEnvelope,
  MutateResult,
  OrderDirection,
  OrderField,
  OrderSpec,
  PatchBuilder,
  Perspective,
  QueryOptions,
  ReadEnvelope,
  RequestContext,
  ResponseContext,
  TransactionBuilder,
} from './types'
