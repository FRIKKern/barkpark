// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Media upload: POST /v1/media/:dataset/upload as multipart/form-data with a
// `file` field. Returns the created asset (server wraps it in `{ result }`).
// FormData is web-standard (Node 18+, browsers, edge, workers) — keeps the
// zero-dependency, runtime-agnostic contract.

import { scopePrefix } from './scope'
import { request } from './transport'
import { assertPaging } from './filter-builder'
import { BarkparkNotFoundError, BarkparkEdgeRuntimeError } from './errors'
import type {
  BarkparkClientConfig,
  MediaAsset,
  MediaAssetPage,
  ListAssetsOptions,
  AssetOptions,
  UpdateAssetInput,
  AssetRelations,
  SearchAssetsOptions,
  MediaSearchResult,
  AssetSearchSuggestions,
  AssetSearchSuggestionsOptions,
  UploadOptions,
  MediaCollection,
  MediaCollectionPage,
  MediaCollectionAssets,
  CollectionAssetsOptions,
  CollectionShare,
} from './types'

export async function uploadAsset(
  config: BarkparkClientConfig,
  file: Blob,
  opts?: UploadOptions,
): Promise<MediaAsset> {
  if (typeof FormData === 'undefined') {
    throw new BarkparkEdgeRuntimeError(
      'uploadAsset requires a runtime with global FormData (Node 18+, browsers, edge)',
    )
  }
  const form = new FormData()
  const filename = opts?.filename ?? (file as { name?: string }).name ?? 'upload'
  form.append('file', file, filename)

  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/upload`
  const reqOpts: {
    method: 'POST'
    kind: 'write'
    body: FormData
    signal?: AbortSignal
    timeoutMs: number
  } = {
    method: 'POST',
    kind: 'write',
    body: form,
    // Uploads are inherently slower than mutations, so default to 120s (vs the
    // 60s write default) and let large transfers extend it. `timeoutMs: 0` disables.
    timeoutMs: opts?.timeoutMs ?? 120_000,
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal

  const { data } = await request<MediaAsset & { result?: MediaAsset }>(config, path, reqOpts)
  return (data.result ?? data) as MediaAsset
}

/**
 * List media assets in the dataset (`GET /v1/media/:dataset`). Paginate with
 * `limit`/`offset`; the result's `count` is the total. Prefer `client.listAssets()`.
 */
export async function listAssets(
  config: BarkparkClientConfig,
  opts?: ListAssetsOptions,
): Promise<MediaAssetPage> {
  assertPaging(opts?.limit, opts?.offset)
  const qp = new URLSearchParams()
  if (opts?.limit !== undefined) qp.set('limit', String(opts.limit))
  if (opts?.offset !== undefined) qp.set('offset', String(opts.offset))
  const query = qp.toString() ? `?${qp.toString()}` : ''
  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}${query}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<MediaAssetPage & { result?: MediaAssetPage }>(
    config,
    path,
    reqOpts,
  )
  return (data.result ?? data) as MediaAssetPage
}

/**
 * Fetch one media asset by id (`GET /v1/media/:dataset/:id`). Returns `null` on
 * 404. Prefer `client.getAsset()`.
 */
export async function getAsset(
  config: BarkparkClientConfig,
  id: string,
  opts?: AssetOptions,
): Promise<MediaAsset | null> {
  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/${encodeURIComponent(id)}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  try {
    const { data } = await request<MediaAsset & { result?: MediaAsset }>(config, path, reqOpts)
    return (data.result ?? data) as MediaAsset
  } catch (err) {
    if (err instanceof BarkparkNotFoundError) return null
    throw err
  }
}

/**
 * Delete a media asset by id (`DELETE /v1/media/:dataset/:id`). Returns
 * `{ deleted: id }`. Prefer `client.deleteAsset()`.
 */
export async function deleteAsset(
  config: BarkparkClientConfig,
  id: string,
  opts?: AssetOptions,
): Promise<{ deleted: string }> {
  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/${encodeURIComponent(id)}`
  const reqOpts: { method: 'DELETE'; kind: 'write'; signal?: AbortSignal } = {
    method: 'DELETE',
    kind: 'write',
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<{ deleted: string } & { result?: { deleted: string } }>(
    config,
    path,
    reqOpts,
  )
  return (data.result ?? data) as { deleted: string }
}

/**
 * Patch a media asset's metadata (`PATCH /v1/media/:dataset/:id`) — alt text,
 * caption, tags, focal point, etc. A partial update: only the passed keys change.
 * Returns the updated asset (server wraps it in `{ result }`). Prefer
 * `client.updateAsset()`.
 */
export async function updateAsset(
  config: BarkparkClientConfig,
  id: string,
  metadata: UpdateAssetInput,
  opts?: AssetOptions,
): Promise<MediaAsset> {
  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/${encodeURIComponent(id)}`
  const reqOpts: { method: 'PATCH'; kind: 'write'; body: unknown; signal?: AbortSignal } = {
    method: 'PATCH',
    kind: 'write',
    body: metadata,
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<MediaAsset & { result?: MediaAsset }>(config, path, reqOpts)
  return (data.result ?? data) as MediaAsset
}

/**
 * Check out a media asset for editing (`POST /v1/media/:dataset/:id/checkout`) —
 * an advisory editorial lock. Member-only. Throws `BarkparkConflictError` (409)
 * if another editor already holds it. Returns the asset with its lock state.
 * Prefer `client.checkoutAsset()`.
 */
export async function checkoutAsset(
  config: BarkparkClientConfig,
  id: string,
  opts?: AssetOptions,
): Promise<MediaAsset> {
  return assetLockOp(config, id, 'checkout', opts)
}

/**
 * Release a media asset's editorial lock (`POST /v1/media/:dataset/:id/undo-checkout`).
 * Member-only (an admin can release another editor's lock). Returns the asset.
 * Prefer `client.undoCheckoutAsset()`.
 */
export async function undoCheckoutAsset(
  config: BarkparkClientConfig,
  id: string,
  opts?: AssetOptions,
): Promise<MediaAsset> {
  return assetLockOp(config, id, 'undo-checkout', opts)
}

// Shared POST for the two lock ops — same shape, only the trailing segment differs.
async function assetLockOp(
  config: BarkparkClientConfig,
  id: string,
  op: 'checkout' | 'undo-checkout',
  opts?: AssetOptions,
): Promise<MediaAsset> {
  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/${encodeURIComponent(id)}/${op}`
  const reqOpts: { method: 'POST'; kind: 'write'; signal?: AbortSignal } = {
    method: 'POST',
    kind: 'write',
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<MediaAsset & { result?: MediaAsset }>(config, path, reqOpts)
  return (data.result ?? data) as MediaAsset
}

/**
 * Fetch an asset's relation graph (`GET /v1/media/:dataset/:id/relations`):
 * `outbound` (assets this one references) + `inbound` (assets that reference it —
 * where-used / impact analysis before a delete). Scoped to the caller. Prefer
 * `client.getAssetRelations()`.
 */
export async function getAssetRelations(
  config: BarkparkClientConfig,
  id: string,
  opts?: AssetOptions,
): Promise<AssetRelations> {
  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/${encodeURIComponent(id)}/relations`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<AssetRelations & { result?: AssetRelations }>(config, path, reqOpts)
  const graph = (data.result ?? data) as Partial<AssetRelations>
  return { outbound: graph.outbound ?? [], inbound: graph.inbound ?? [] }
}

/**
 * Search the media library (`GET /v1/media/:dataset/search`) — full-text over
 * asset metadata plus filters (mimeType/kind/status/collection/tags) and facets.
 * `q` may be empty for a filter-only browse. The hits + total + facets live under
 * the response's `result` key; `highlights`/`parsedQuery`/`ms` sit at the top
 * level. Prefer `client.searchAssets()`.
 */
export async function searchAssets(
  config: BarkparkClientConfig,
  q: string,
  opts?: SearchAssetsOptions,
): Promise<MediaSearchResult> {
  assertPaging(opts?.limit, opts?.offset)
  const params = new URLSearchParams()
  if (q) params.set('q', q)
  if (opts?.limit !== undefined) params.set('limit', String(opts.limit))
  if (opts?.offset !== undefined) params.set('offset', String(opts.offset))
  if (opts?.cursor !== undefined) params.set('cursor', opts.cursor)
  if (opts?.mimeType !== undefined) params.set('type', opts.mimeType) // server reads `type`
  if (opts?.kind !== undefined) params.set('kind', opts.kind)
  if (opts?.status !== undefined) params.set('status', opts.status)
  if (opts?.collection !== undefined) params.set('collection', opts.collection)
  if (opts?.tags !== undefined) params.set('tags', opts.tags)
  if (opts?.sort !== undefined) params.set('sort', opts.sort)
  if (opts?.facets !== undefined) params.set('facets', opts.facets)

  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/search?${params.toString()}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal

  const { data } = await request<Record<string, unknown>>(config, path, reqOpts)
  // hits/total/facets/pagination live under `result`; highlights/parsedQuery/ms
  // sit at the top level (asymmetric, unlike the flat document-search envelope).
  const inner = (data.result ?? data) as Record<string, unknown>
  // Build the required fields, then only attach the optional ones when present
  // (exactOptionalPropertyTypes forbids assigning an explicit `undefined`).
  const result: MediaSearchResult = {
    hits: (inner.hits as MediaAsset[]) ?? [],
    total: (inner.total as number) ?? 0,
    limit: (inner.limit as number) ?? 0,
    offset: (inner.offset as number) ?? 0,
    nextCursor: (inner.nextCursor as string | null | undefined) ?? null,
    hasMore: (inner.hasMore as boolean) ?? false,
  }
  if (inner.facets !== undefined) result.facets = inner.facets as Record<string, unknown>
  if (data.highlights !== undefined) result.highlights = data.highlights as Record<string, unknown>
  if (data.parsedQuery !== undefined) result.parsedQuery = data.parsedQuery
  if (data.ms !== undefined) result.ms = data.ms as number
  return result
}

/**
 * Typeahead suggestions for a media search box
 * (`GET /v1/media/:dataset/search/suggestions`): the caller's `recent` queries,
 * the dataset's `popular` ones, and recent `nohits`. `prefix` filters each bucket
 * as the user types (omit for the unfiltered top lists). Prefer
 * `client.getAssetSearchSuggestions()`.
 */
export async function getAssetSearchSuggestions(
  config: BarkparkClientConfig,
  prefix?: string,
  opts?: AssetSearchSuggestionsOptions,
): Promise<AssetSearchSuggestions> {
  assertPaging(opts?.limit)
  const params = new URLSearchParams()
  if (prefix) params.set('q', prefix)
  if (opts?.limit !== undefined) params.set('limit', String(opts.limit))
  const qs = params.toString()
  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/search/suggestions${qs ? `?${qs}` : ''}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal

  const { data } = await request<{ result?: Partial<AssetSearchSuggestions> } & Partial<AssetSearchSuggestions>>(
    config,
    path,
    reqOpts,
  )
  const inner = (data.result ?? data) as Partial<AssetSearchSuggestions>
  return {
    recent: inner.recent ?? [],
    popular: inner.popular ?? [],
    nohits: inner.nohits ?? [],
  }
}

/**
 * List media collections (`GET /v1/media/:dataset/collections`). Paginate with
 * `limit`/`offset` (`count` is the total). Prefer `client.listCollections()`.
 */
export async function listCollections(
  config: BarkparkClientConfig,
  opts?: ListAssetsOptions,
): Promise<MediaCollectionPage> {
  assertPaging(opts?.limit, opts?.offset)
  const qp = new URLSearchParams()
  if (opts?.limit !== undefined) qp.set('limit', String(opts.limit))
  if (opts?.offset !== undefined) qp.set('offset', String(opts.offset))
  const query = qp.toString() ? `?${qp.toString()}` : ''
  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/collections${query}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<MediaCollectionPage & { result?: MediaCollectionPage }>(
    config,
    path,
    reqOpts,
  )
  return (data.result ?? data) as MediaCollectionPage
}

/**
 * Fetch one media collection by id (`GET /v1/media/:dataset/collections/:id`).
 * Returns `null` on 404. Prefer `client.getCollection()`.
 */
export async function getCollection(
  config: BarkparkClientConfig,
  id: string,
  opts?: AssetOptions,
): Promise<MediaCollection | null> {
  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/collections/${encodeURIComponent(id)}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  try {
    const { data } = await request<MediaCollection & { result?: MediaCollection }>(
      config,
      path,
      reqOpts,
    )
    return (data.result ?? data) as MediaCollection
  } catch (err) {
    if (err instanceof BarkparkNotFoundError) return null
    throw err
  }
}

/**
 * List the assets in a media collection
 * (`GET /v1/media/:dataset/collections/:id/assets`). Returns the hits plus
 * `total` and `facets`. Prefer `client.getCollectionAssets()`.
 */
export async function getCollectionAssets(
  config: BarkparkClientConfig,
  id: string,
  opts?: CollectionAssetsOptions,
): Promise<MediaCollectionAssets> {
  assertPaging(opts?.limit, opts?.offset)
  const qp = new URLSearchParams()
  if (opts?.limit !== undefined) qp.set('limit', String(opts.limit))
  if (opts?.offset !== undefined) qp.set('offset', String(opts.offset))
  const query = qp.toString() ? `?${qp.toString()}` : ''
  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/collections/${encodeURIComponent(id)}/assets${query}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<MediaCollectionAssets & { result?: MediaCollectionAssets }>(
    config,
    path,
    reqOpts,
  )
  return (data.result ?? data) as MediaCollectionAssets
}

/**
 * Add an asset to a media collection
 * (`POST /v1/media/:dataset/collections/:id/members`). Returns the added asset.
 * Prefer `client.addCollectionMember()`.
 */
export async function addCollectionMember(
  config: BarkparkClientConfig,
  id: string,
  assetId: string,
  opts?: { signal?: AbortSignal },
): Promise<MediaAsset> {
  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/collections/${encodeURIComponent(id)}/members`
  // The server's add_member reads `assetId` (camelCase) from the BODY, not the path.
  const reqOpts: {
    method: 'POST'
    body: { assetId: string }
    kind: 'write'
    signal?: AbortSignal
  } = { method: 'POST', body: { assetId }, kind: 'write' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<MediaAsset & { result?: MediaAsset }>(config, path, reqOpts)
  return (data.result ?? data) as MediaAsset
}

/**
 * Remove an asset from a media collection
 * (`DELETE /v1/media/:dataset/collections/:id/members/:assetId`). Returns the
 * removed asset. Prefer `client.removeCollectionMember()`.
 */
export async function removeCollectionMember(
  config: BarkparkClientConfig,
  id: string,
  assetId: string,
  opts?: { signal?: AbortSignal },
): Promise<MediaAsset> {
  // assetId rides the PATH here (the server's remove_member reads :asset_id).
  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/collections/${encodeURIComponent(id)}/members/${encodeURIComponent(assetId)}`
  const reqOpts: { method: 'DELETE'; kind: 'write'; signal?: AbortSignal } = {
    method: 'DELETE',
    kind: 'write',
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<MediaAsset & { result?: MediaAsset }>(config, path, reqOpts)
  return (data.result ?? data) as MediaAsset
}

/**
 * Enable (or rotate) a public share link for a media collection
 * (`POST /v1/media/:dataset/collections/:id/share`). Returns the `token`, the
 * relative `shareUrl`, and the `expiresAt` (default 7-day TTL; override with
 * `ttl` seconds). Prefer `client.shareCollection()`.
 */
export async function shareCollection(
  config: BarkparkClientConfig,
  id: string,
  opts?: { ttl?: number; signal?: AbortSignal },
): Promise<CollectionShare> {
  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/collections/${encodeURIComponent(id)}/share`
  const body: { ttl?: number } = {}
  if (opts?.ttl !== undefined) body.ttl = opts.ttl
  const reqOpts: { method: 'POST'; body: { ttl?: number }; kind: 'write'; signal?: AbortSignal } = {
    method: 'POST',
    body,
    kind: 'write',
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<CollectionShare & { result?: CollectionShare }>(
    config,
    path,
    reqOpts,
  )
  return (data.result ?? data) as CollectionShare
}

/**
 * Revoke a media collection's public share link
 * (`DELETE /v1/media/:dataset/collections/:id/share`). Prefer
 * `client.revokeCollectionShare()`.
 */
export async function revokeCollectionShare(
  config: BarkparkClientConfig,
  id: string,
  opts?: { signal?: AbortSignal },
): Promise<void> {
  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/collections/${encodeURIComponent(id)}/share`
  const reqOpts: { method: 'DELETE'; kind: 'write'; signal?: AbortSignal } = {
    method: 'DELETE',
    kind: 'write',
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  await request<{ result?: { revoked: string } }>(config, path, reqOpts)
}
