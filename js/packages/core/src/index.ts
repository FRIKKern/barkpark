// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Public API surface of `@barkpark/core`. Every name here becomes a permanent
// contract — add only symbols with documented intent. See ADR-002 through
// ADR-011 for the contracts backing each export.

import type { BarkparkClient, BarkparkDocument, DocsBuilder } from './types'

// --- Client factory + handshake --------------------------------------------
export { createClient } from './client'
export { scopePrefix } from './scope'
export { createHandshakeCache } from './handshake'

// --- Operation factories (composable without createClient) -----------------
export { createPatch } from './patch'
export { createTransaction } from './transaction'
export { createDocsOperation } from './docs'
export { getDoc } from './doc'
export { searchDocuments } from './search'
export {
  uploadAsset,
  listAssets,
  getAsset,
  deleteAsset,
  listCollections,
  getCollection,
  getCollectionAssets,
} from './media'
export { listSchemas, getSchema } from './schemas'
export { publishDoc, unpublishDoc, discardDraftDoc } from './publish'
export { fetchRawDoc } from './fetchRaw'
export { createListenHandle } from './listen'
export { imageUrl } from './image-url'
export type { RenditionPreset, ImageRef, ImageUrlOptions } from './image-url'
export { listWorkspaces, listProjects, createWorkspace, createProject } from './tenancy'
export type {
  Project,
  Workspace,
  ListProjectsEnvelope,
  ListWorkspacesEnvelope,
  CreateProjectInput,
  CreateWorkspaceInput,
  CreateProjectEnvelope,
  CreateWorkspaceEnvelope,
} from './tenancy'

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

// --- Schema-typed client (pairs with @barkpark/codegen) ---------------------
/**
 * A {@link BarkparkClient} whose `doc`/`docs` are narrowed by a generated schema
 * `TypeMap` (type-name → document interface), so a known type returns its
 * concrete shape instead of the open {@link BarkparkDocument}.
 */
export type TypedClient<TMap extends Record<string, object> = Record<string, BarkparkDocument>> =
  Omit<BarkparkClient, 'doc' | 'docs'> & {
    doc<K extends keyof TMap & string>(type: K, id: string): Promise<TMap[K] | null>
    docs<K extends keyof TMap & string>(type: K): DocsBuilder<TMap[K]>
  }

/**
 * Re-type a client with a generated schema `TypeMap` so `doc`/`docs` infer the
 * concrete document interface. The runtime is the IDENTITY — only the static
 * types narrow; no behaviour changes.
 *
 * ```ts
 * import type { BarkparkTypeMap } from './barkpark.types' // emitted by `barkpark generate`
 * const bp = typedClient<BarkparkTypeMap>(createClient(cfg))
 * const post = await bp.doc('post', id) // Post | null — and bp.doc('psot', …) is a compile error
 * ```
 *
 * Pair with `@barkpark/codegen`. Without a `TypeMap` it defaults to the open
 * client shape, so calling it bare is a harmless no-op.
 */
export function typedClient<TMap extends Record<string, object> = Record<string, BarkparkDocument>>(
  client: BarkparkClient,
): TypedClient<TMap> {
  return client as unknown as TypedClient<TMap>
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
  QueryPage,
  SearchOptions,
  SearchResult,
  UploadOptions,
  MediaAsset,
  MediaCollection,
  MediaCollectionPage,
  MediaCollectionAssets,
  CollectionAssetsOptions,
  BarkparkSchema,
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
  QueryEnvelope,
  QueryOptions,
  ReadEnvelope,
  TransactionBuilder,
} from './types'

/**
 * @internal
 *
 * These types are internal to @barkpark/core and may change without notice.
 * Use the public client API. These types describe transport internals.
 */
export type { RequestContext, ResponseContext } from './types'
