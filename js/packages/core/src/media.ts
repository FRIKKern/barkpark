// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Media upload: POST /v1/media/:dataset/upload as multipart/form-data with a
// `file` field. Returns the created asset (server wraps it in `{ result }`).
// FormData is web-standard (Node 18+, browsers, edge, workers) — keeps the
// zero-dependency, runtime-agnostic contract.

import { scopePrefix } from './scope'
import { assertSegment } from './util/guards'
import { request } from './transport'
import { assertPaging, assertNoCommaEntries } from './filter-builder'
import { BarkparkNotFoundError, BarkparkEdgeRuntimeError, BarkparkValidationError } from './errors'
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

// Guard the id/assetId every write (and non-null-returning read) op feeds into
// encodeURIComponent. An empty string collapses the path (e.g. `//checkout`) and
// `undefined` yields the literal `undefined` segment; `'..'` is worse — it survives
// encodeURIComponent and fetch's URL parser resolves it before the request leaves,
// retargeting the call at a DIFFERENT media route (`revokeCollectionShare('..')`
// emitted `DELETE /v1/media/:dataset/:id` — MediaController.delete, an asset
// deletion). One shared rule covers both: a path segment may not be a
// relative-path operator. See util/guards.ts.
function assertAssetId(id: string, field = 'id'): void {
  assertSegment(id, field)
}

// Normalize a tags/facets filter (single value or array) into the comma-joined
// param the server expects: trims each entry and drops empties so a stray '' can't
// ship a phantom `tags=a,,b`. Returns `undefined` when nothing remains so the
// caller OMITS the param (an empty value list is a no-op filter, not an error).
// ARRAY entries are additionally comma-guarded (`field` names the param): a comma
// inside an array entry would silently split into extra values — the same
// corruption the filter-builder guards fail closed on. A single pre-joined string
// (e.g. `'a,b'`) is passed through unchanged: the caller may intend that CSV.
function cleanValueList(input: string | string[] | undefined, field: string): string | undefined {
  if (input === undefined) return undefined
  const cleaned = (Array.isArray(input) ? input : [input])
    .map((v) => String(v).trim())
    .filter((v) => v.length > 0)
  if (Array.isArray(input)) assertNoCommaEntries(cleaned, field)
  return cleaned.length > 0 ? cleaned.join(',') : undefined
}

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
  // Duck-type the Blob/File contract (no `instanceof` — cross-realm safe). The
  // classic mistake is passing a path string; without this it throws an opaque
  // DOMException from FormData.append with no Barkpark context.
  if (file == null || typeof (file as { arrayBuffer?: unknown }).arrayBuffer !== 'function') {
    throw new BarkparkValidationError(
      'uploadAsset requires a Blob or File (got ' +
        (file === null ? 'null' : typeof file) +
        ') — pass file contents, not a path string',
      { field: 'file' },
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
  assertAssetId(id)
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
  assertAssetId(id)
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
  assertAssetId(id)
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
  assertAssetId(id)
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
  assertAssetId(id)
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
  // tags/facets accept a comma-string OR an array (joined) — the server reads
  // the same comma-separated param either way. These are values (not a
  // projection), so — unlike expand/fields — a cleaned-empty list just OMITS the
  // param (a filter-less browse) rather than throwing.
  const tags = cleanValueList(opts?.tags, 'tags')
  if (tags !== undefined) params.set('tags', tags)
  if (opts?.sort !== undefined) params.set('sort', opts.sort)
  const facets = cleanValueList(opts?.facets, 'facets')
  if (facets !== undefined) params.set('facets', facets)

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
  if (data.parsedQuery !== undefined) result.parsedQuery = data.parsedQuery as Record<string, unknown>
  if (data.ms !== undefined) result.ms = data.ms as number
  // Top-level on the response (asymmetric envelope, like highlights/ms) —
  // required by the paired /search/interaction routes.
  result.searchEventId = (data.searchEventId as string | null | undefined) ?? null
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
  assertAssetId(id)
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
  assertAssetId(id)
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
  assertAssetId(id, 'collectionId')
  assertAssetId(assetId, 'assetId')
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
  assertAssetId(id, 'collectionId')
  assertAssetId(assetId, 'assetId')
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
  assertAssetId(id, 'collectionId')
  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/collections/${encodeURIComponent(id)}/share`
  if (opts?.ttl !== undefined && (!Number.isInteger(opts.ttl) || opts.ttl < 1)) {
    throw new BarkparkValidationError('ttl must be a positive integer (seconds)', { field: 'ttl' })
  }
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
  assertAssetId(id, 'collectionId')
  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/collections/${encodeURIComponent(id)}/share`
  const reqOpts: { method: 'DELETE'; kind: 'write'; signal?: AbortSignal } = {
    method: 'DELETE',
    kind: 'write',
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  await request<{ result?: { revoked: string } }>(config, path, reqOpts)
}
