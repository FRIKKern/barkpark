// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Public API surface of `@barkpark/core`. Every name here becomes a permanent
// contract — add only symbols with documented intent.

import type {
  BarkparkClient,
  BarkparkClientConfig,
  BarkparkDocument,
  DocsBuilder,
  Perspective,
} from './types'

// --- Client factory + handshake --------------------------------------------
export { createClient } from './client'
// The runtime operator array `FilterOp` is derived from — exported so a caller
// can enumerate the ops (a `<select>`, a validator) instead of re-typing them.
export { FILTER_OPS } from './types'
export { scopePrefix } from './scope'
export { createHandshakeCache } from './handshake'

// --- Operation factories (composable without createClient) -----------------
export { createPatch } from './patch'
export { createTransaction } from './transaction'
export { verifyWebhookSignature, parseWebhookEvent } from './webhook'
export type { VerifyWebhookOptions, WebhookEvent, WebhookEventKind } from './webhook'
export { createDocsOperation } from './docs'
export type { DocsOperationOptions } from './docs'
export { getDoc } from './doc'
export type { GetDocOptions, DocResult } from './doc'
export { searchDocuments, getSearchSuggestions } from './search'
export { getBacklinks } from './backlinks'
export { getRelated } from './related'
export { listTags, getTagDocs, normalizeTags } from './tags'
export { getGraph, getOrphans, getDangling } from './graph'
export { getHistory, getRevision, restoreRevision } from './history'
export {
  registerUser,
  loginUser,
  getCurrentUser,
  logoutUser,
  enrollMfa,
  verifyMfa,
  disableMfa,
  verifyEmail,
  requestPasswordReset,
  resetPassword,
} from './auth'
export {
  uploadAsset,
  listAssets,
  getAsset,
  deleteAsset,
  updateAsset,
  checkoutAsset,
  undoCheckoutAsset,
  getAssetRelations,
  searchAssets,
  getAssetSearchSuggestions,
  listCollections,
  getCollection,
  getCollectionAssets,
  addCollectionMember,
  removeCollectionMember,
  shareCollection,
  revokeCollectionShare,
} from './media'
export { listSchemas, getSchema, upsertSchema, deleteSchema } from './schemas'
export { getAnalytics } from './analytics'
export {
  listWebhooks,
  getWebhook,
  createWebhook,
  updateWebhook,
  deleteWebhook,
} from './webhooks'
export { publishDoc, unpublishDoc, discardDraftDoc } from './publish'
export { fetchRawDoc } from './fetchRaw'
export { createListenHandle } from './listen'
export type { ListenOptions } from './listen'
// The edge-runtime detector `listen()` already gates on. Exported so downstream
// packages (@barkpark/nextjs) REUSE it instead of hand-rolling a second copy —
// the fork in @barkpark/nextjs's client bundle had drifted into classifying
// every browser as an edge runtime.
export { detectEdgeRuntime } from './util/edge-detect'
export type { EdgeSignal } from './util/edge-detect'
export { exportDataset } from './export'
export { imageUrl } from './image-url'
export type { RenditionPreset, ImageRef, ImageUrlOptions } from './image-url'
export { listWorkspaces, listProjects, listDatasets, createWorkspace, createProject } from './tenancy'
export type {
  Project,
  Workspace,
  Dataset,
  ListProjectsEnvelope,
  ListDatasetsEnvelope,
  ListWorkspacesEnvelope,
  CreateProjectInput,
  CreateWorkspaceInput,
  CreateProjectEnvelope,
  CreateWorkspaceEnvelope,
} from './tenancy'

// --- Filter / builder utilities (used by advanced callers + codegen) -------
export {
  createDocsBuilder,
  makeFilterExpression,
  buildQueryString,
  assertPaging,
} from './filter-builder'
export type { FilterExpression, BuilderState } from './filter-builder'

// The path-segment guard this package's own eleven path builders call. Exported
// so downstream packages (@barkpark/nextjs) REUSE the rule instead of writing a
// second copy of it — @barkpark/nextjs's server fetch path had already hand-
// rolled one, and the ONLY reason it existed was that this line was missing.
// Two implementations of one rule means the next reader greps, finds the copy,
// and edits that. Same reason `detectEdgeRuntime` above is public.
export { assertSegment } from './util/guards'

// --- Errors — export class AND note: every class has a `code` literal equal
// to its class name, for cross-bundle matching when `instanceof` is unreliable
// (the code-literal taxonomy — see errors.ts).
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
  // Value export: a runtime type guard (matches on the `code` string, not
  // `instanceof`) so consumers narrow errors safely across bundle boundaries.
  isBarkparkError,
} from './errors'
// The accepted `code` values for `isBarkparkError` (each concrete class name).
export type { BarkparkErrorCode } from './errors'

// --- Schema-typed client (pairs with @barkpark/codegen) ---------------------
/**
 * A {@link BarkparkClient} whose type-keyed reads (`doc`/`docs`/`getDocuments`) are
 * narrowed by a generated schema `TypeMap` (type-name → document interface), so a
 * known type returns its concrete shape instead of the open {@link BarkparkDocument}.
 * (`getBacklinks`/`getGraph`/mutate/listen aren't single-type-keyed, so they stay
 * unnarrowed by design.)
 */
export type TypedClient<TMap extends Record<string, object> = Record<string, BarkparkDocument>> =
  Omit<BarkparkClient, 'doc' | 'docs' | 'getDocuments' | 'withConfig'> & {
    doc<K extends keyof TMap & string>(
      type: K,
      id: string,
      opts?: {
        expand?: string | string[]
        fields?: string | string[]
        signal?: AbortSignal
        perspective?: Perspective
      },
    ): Promise<TMap[K] | null>
    docs<K extends keyof TMap & string>(
      type: K,
      opts?: { perspective?: Perspective; signal?: AbortSignal },
    ): DocsBuilder<TMap[K]>
    getDocuments<K extends keyof TMap & string>(
      type: K,
      ids: string[],
      opts?: {
        expand?: string | string[]
        fields?: string | string[]
        signal?: AbortSignal
        perspective?: Perspective
      },
    ): Promise<Array<TMap[K] | null>>
    // Re-narrowed so `.withConfig({ perspective: 'drafts' })` keeps the `TMap`
    // typing instead of collapsing back to the open `BarkparkClient`.
    withConfig(patch: Partial<BarkparkClientConfig>): TypedClient<TMap>
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
  SearchSuggestion,
  SearchSuggestions,
  SearchSuggestionsOptions,
  UploadOptions,
  UpdateAssetInput,
  AssetRelations,
  AssetRelationEdge,
  SearchAssetsOptions,
  MediaSearchResult,
  AssetSearchSuggestion,
  AssetSearchSuggestions,
  AssetSearchSuggestionsOptions,
  MediaAsset,
  MediaAssetPage,
  AssetOptions,
  ListAssetsOptions,
  MediaCollection,
  MediaCollectionPage,
  MediaCollectionAssets,
  CollectionAssetsOptions,
  CollectionShare,
  Backlink,
  BacklinksResult,
  SharedTag,
  RelatedEntry,
  RelatedResult,
  RelatedOptions,
  TagRegistryEntry,
  ListTagsResult,
  ListTagsOptions,
  TagDoc,
  TagDocsResult,
  TagDocsOptions,
  WeightedTag,
  GraphNode,
  GraphEdge,
  GraphResult,
  GraphOptions,
  BacklinksOptions,
  DocumentRevision,
  RestoreResult,
  HistoryOptions,
  RevisionOptions,
  AuthUser,
  AuthSession,
  AuthRegisterResult,
  LoginOptions,
  BarkparkAuth,
  MfaEnrollResult,
  MfaVerifyResult,
  PasswordResetReceipt,
  BarkparkSchema,
  BarkparkFieldType,
  DocFieldName,
  DatasetAnalytics,
  DocumentTypeStats,
  AnalyticsActivityEntry,
  UpsertSchemaInput,
  Webhook,
  CreateWebhookInput,
  UpdateWebhookInput,
  FilterOp,
  FilterValue,
  ListenEvent,
  ListenHandle,
  MetaResponse,
  MutateEnvelope,
  MutateResult,
  // The advisory's own type. It had never been exported — a consumer could
  // receive `warnings` on the envelope but could not name what it held.
  MutateWarning,
  OrderDirection,
  OrderField,
  OrderSpec,
  PatchBuilder,
  Perspective,
  ExportOptions,
  ListenFilter,
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
