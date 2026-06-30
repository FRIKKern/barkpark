// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Media upload: POST /v1/media/:dataset/upload as multipart/form-data with a
// `file` field. Returns the created asset (server wraps it in `{ result }`).
// FormData is web-standard (Node 18+, browsers, edge, workers) — keeps the
// zero-dependency, runtime-agnostic contract.

import { scopePrefix } from './scope'
import { request } from './transport'
import { BarkparkNotFoundError } from './errors'
import type {
  BarkparkClientConfig,
  MediaAsset,
  MediaAssetPage,
  ListAssetsOptions,
  AssetOptions,
  UploadOptions,
  MediaCollection,
  MediaCollectionPage,
  MediaCollectionAssets,
  CollectionAssetsOptions,
} from './types'

export async function uploadAsset(
  config: BarkparkClientConfig,
  file: Blob,
  opts?: UploadOptions,
): Promise<MediaAsset> {
  if (typeof FormData === 'undefined') {
    throw new Error(
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
 * List media collections (`GET /v1/media/:dataset/collections`). Paginate with
 * `limit`/`offset` (`count` is the total). Prefer `client.listCollections()`.
 */
export async function listCollections(
  config: BarkparkClientConfig,
  opts?: ListAssetsOptions,
): Promise<MediaCollectionPage> {
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
